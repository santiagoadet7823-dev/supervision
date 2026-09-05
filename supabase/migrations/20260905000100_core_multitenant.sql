-- ============================================================================
-- 001 — Núcleo multi-tenant: comercios, usuarios y credenciales de agente
--
-- Todo el resto del esquema cuelga de acá. `tenants` es el comercio (cada uno
-- con su instalación local del ERP FoxPro) y `profiles` ata un usuario de
-- Supabase Auth a exactamente un comercio.
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Comercios (subclientes)
-- ---------------------------------------------------------------------------
create table tenants (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  slug         text not null unique,
  -- El ERP guarda fechas locales sin zona. Esta timezone es la que define
  -- cuándo empieza y termina el día comercial: sin ella, un corte a medianoche
  -- UTC partiría las ventas de la tarde en dos días distintos.
  timezone     text not null default 'America/Argentina/Buenos_Aires',
  currency     char(3) not null default 'ARS',
  erp_version  text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);

comment on table tenants is
  'Comercio subcliente. Unidad de aislamiento: toda fila de datos pertenece a un tenant.';

-- ---------------------------------------------------------------------------
-- Roles y perfiles
-- ---------------------------------------------------------------------------
create type app_role as enum ('super_admin', 'owner', 'manager');

comment on type app_role is
  'super_admin: nosotros, ve todos los tenants. owner: dueño del comercio, ve todo lo suyo. '
  'manager: encargado, sin acceso a los módulos financieros.';

create table profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  -- NULL sólo para super_admin: no pertenece a ningún comercio.
  tenant_id  uuid references tenants (id) on delete cascade,
  role       app_role not null default 'manager',
  full_name  text,
  created_at timestamptz not null default now(),

  -- Un usuario de comercio sin tenant no podría ver nada y sería un bug silencioso.
  constraint profiles_tenant_required_unless_admin
    check (role = 'super_admin' or tenant_id is not null)
);

create index profiles_tenant_id_idx on profiles (tenant_id);

-- Crea el perfil apenas se registra el usuario. Sin esto, un usuario recién
-- creado queda sin tenant y las policies lo dejan viendo cero filas sin explicación.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into profiles (id, tenant_id, role, full_name)
  values (
    new.id,
    (new.raw_user_meta_data ->> 'tenant_id')::uuid,
    coalesce((new.raw_user_meta_data ->> 'role')::app_role, 'manager'),
    new.raw_user_meta_data ->> 'full_name'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ---------------------------------------------------------------------------
-- Credenciales del agente local
-- ---------------------------------------------------------------------------
-- Se guarda SÓLO el hash. La clave completa se muestra una única vez al generarla:
-- si se pierde, se emite otra y se revoca la anterior. Nunca se puede volver a leer.
create table agent_keys (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants (id) on delete cascade,
  key_hash     text not null,
  -- Primeros caracteres de la clave, para identificarla en un listado sin revelarla.
  key_prefix   text not null,
  label        text,
  last_seen_at timestamptz,
  revoked_at   timestamptz,
  created_at   timestamptz not null default now()
);

-- Varias claves activas por tenant: permite rotar sin cortar el sync
-- (se emite la nueva, se actualiza el agente, recién ahí se revoca la vieja).
create index agent_keys_tenant_active_idx
  on agent_keys (tenant_id)
  where revoked_at is null;

create index agent_keys_prefix_idx on agent_keys (key_prefix);

comment on table agent_keys is
  'Credencial del agente local. El tenant_id de toda ingesta se deriva de acá, '
  'NUNCA del body del request.';
