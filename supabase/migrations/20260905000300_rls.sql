-- ============================================================================
-- 003 — Row Level Security: el aislamiento entre comercios
--
-- Esta es la pieza más importante del proyecto. Si falla, un comercio ve las
-- ventas de otro.
--
-- El principio: el `tenant_id` NUNCA llega como parámetro del cliente. Se deriva
-- siempre de `auth.uid()`. Aunque la app tuviera un bug o alguien llamara la API
-- a mano con el id de otro comercio, la base no devuelve esas filas.
--
-- Los roles `authenticated` y `anon` sólo pueden LEER. Toda escritura de datos
-- entra por la Edge Function de ingesta, que usa `service_role` y saltea la RLS.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- SECURITY DEFINER a propósito: lee `profiles` salteando la RLS de esa tabla.
-- Si fuera INVOKER, la policy de profiles se llamaría a sí misma (recursión
-- infinita) porque la propia policy necesita saber el tenant del usuario.
-- STABLE para que el planner la evalúe una vez por consulta y no por fila.
create or replace function auth_tenant_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select tenant_id from profiles where id = auth.uid()
$$;

create or replace function is_super_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role = 'super_admin'
  )
$$;

-- Los módulos financieros (cuentas corrientes y cheques) son sólo para el dueño.
-- Un encargado ve las ventas del local, no a quién le debe plata el negocio.
create or replace function can_see_financials()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role in ('super_admin', 'owner')
  )
$$;

revoke execute on function auth_tenant_id() from public;
revoke execute on function is_super_admin() from public;
revoke execute on function can_see_financials() from public;
grant execute on function auth_tenant_id() to authenticated;
grant execute on function is_super_admin() to authenticated;
grant execute on function can_see_financials() to authenticated;

-- ---------------------------------------------------------------------------
-- Permisos base: sólo lectura para usuarios autenticados
-- ---------------------------------------------------------------------------
-- Se quita todo y se devuelve únicamente SELECT. Un INSERT/UPDATE/DELETE desde
-- el cliente no debe existir ni siquiera con la policy correcta.
revoke all on all tables in schema public from anon, authenticated;

grant select on
  tenants, profiles,
  sales_daily, sales_hourly,
  products, product_sales_daily,
  account_balances, checks,
  sales_targets, sync_runs
to authenticated;

-- Las metas las carga el dueño desde la app: es la única tabla que el cliente escribe.
grant insert, update, delete on sales_targets to authenticated;

-- `agent_keys` no recibe ningún grant: es invisible desde el cliente.

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table tenants             enable row level security;
alter table profiles            enable row level security;
alter table agent_keys          enable row level security;
alter table sales_daily         enable row level security;
alter table sales_hourly        enable row level security;
alter table products            enable row level security;
alter table product_sales_daily enable row level security;
alter table account_balances    enable row level security;
alter table checks              enable row level security;
alter table sales_targets       enable row level security;
alter table sync_runs           enable row level security;

-- `agent_keys` queda con RLS activa y SIN ninguna policy: nadie salvo
-- `service_role` (que saltea la RLS) puede tocarla. Es deliberado.

-- Cada uno ve su propio comercio; nosotros vemos todos.
create policy tenants_read on tenants
  for select to authenticated
  using (id = auth_tenant_id() or is_super_admin());

-- El usuario ve su propio perfil, y el dueño ve a los usuarios de su comercio.
create policy profiles_read on profiles
  for select to authenticated
  using (
    id = auth.uid()
    or is_super_admin()
    or (tenant_id = auth_tenant_id() and can_see_financials())
  );

create policy sales_daily_read on sales_daily
  for select to authenticated
  using (tenant_id = auth_tenant_id() or is_super_admin());

create policy sales_hourly_read on sales_hourly
  for select to authenticated
  using (tenant_id = auth_tenant_id() or is_super_admin());

create policy products_read on products
  for select to authenticated
  using (tenant_id = auth_tenant_id() or is_super_admin());

create policy product_sales_daily_read on product_sales_daily
  for select to authenticated
  using (tenant_id = auth_tenant_id() or is_super_admin());

-- Financieros: además del tenant, exigen rol owner o super_admin.
create policy account_balances_read on account_balances
  for select to authenticated
  using ((tenant_id = auth_tenant_id() and can_see_financials()) or is_super_admin());

create policy checks_read on checks
  for select to authenticated
  using ((tenant_id = auth_tenant_id() and can_see_financials()) or is_super_admin());

create policy sync_runs_read on sync_runs
  for select to authenticated
  using (tenant_id = auth_tenant_id() or is_super_admin());

-- Metas: todos las leen, sólo el dueño las edita.
create policy sales_targets_read on sales_targets
  for select to authenticated
  using (tenant_id = auth_tenant_id() or is_super_admin());

create policy sales_targets_insert on sales_targets
  for insert to authenticated
  with check (tenant_id = auth_tenant_id() and can_see_financials());

-- USING filtra qué filas puede tocar; WITH CHECK impide que el UPDATE mueva la
-- fila a otro tenant. Sin el WITH CHECK, un dueño podría reescribir la meta de
-- otro comercio.
create policy sales_targets_update on sales_targets
  for update to authenticated
  using (tenant_id = auth_tenant_id() and can_see_financials())
  with check (tenant_id = auth_tenant_id() and can_see_financials());

create policy sales_targets_delete on sales_targets
  for delete to authenticated
  using (tenant_id = auth_tenant_id() and can_see_financials());

-- Las tablas nuevas que se creen después heredan estos permisos por defecto.
alter default privileges in schema public
  revoke all on tables from anon, authenticated;
