# Plataforma BI multi-tenant sobre ERP FoxPro

**Estado:** aprobado · 2026-09-05

## Contexto

Existe un ERP legacy basado en FoxPro (tablas DBF) instalado localmente en los servidores de múltiples comercios ("subclientes"). Hoy cada dueño de negocio solo puede ver sus números sentándose frente a la máquina del ERP, y no hay analítica comparativa ni acceso móvil.

El objetivo es una plataforma centralizada donde cada subcliente inicie sesión y vea, desde el móvil o el escritorio, sus KPIs de ventas, rotación y márgenes de productos, cuentas corrientes y cartera de cheques — sin tocar ni arriesgar el ERP local, y con aislamiento estricto entre tenants.

`C:\Users\Gaston\Desktop\SUPERVISION` está vacío: es un proyecto greenfield, no hay código previo que reutilizar.

### Decisiones tomadas
- **Nube:** Supabase (PostgreSQL + Auth + RLS). *Actualmente con acceso limitado: el plan lo especifica en SQL versionado, pero no se ejecutará ninguna migración contra Supabase en esta fase.*
- **Agente local:** Node.js empaquetado como servicio de Windows.
- **Sincronización:** push incremental de agregados por HTTPS, saliente únicamente (sin puertos abiertos ni IP fija en el comercio).
- **Frontend:** **Flutter** (web/PWA + APK Android desde el mismo código). Capacitor queda descartado por experiencias previas de "PWA rota".
- **Repositorio y despliegue:** todo vive en **GitHub**. La PWA se publica en **GitHub Pages**; el **APK se distribuye por GitHub Releases y se autoactualiza** desde la app.
- **Documentación viva en el repo:** `CLAUDE.md`, `README.md`, `ROADMAP.md`, `HANDOFF.md`, y las carpetas `PLANES/` y `LINKS-IMPORTANTES/`.

---

## Arquitectura

```
[ERP FoxPro / DBF ]  ──lectura sólo-lectura──>  [Agente Local Node.js (servicio Windows)]
                                                        │  HTTPS POST + API key por tenant
                                                        ▼
                                          [Supabase: Postgres + RLS + Edge Functions]
                                                        │  REST/RPC + JWT
                                                        ▼
                                      [Flutter: PWA (web) + APK (Android)]
```

Principio rector: **el agente agrega, la nube almacena y compara, el cliente sólo pinta.** Los KPIs pesados se precalculan; el dashboard nunca lanza un scan sobre datos crudos.

---

## Fase 0 — Relevamiento del esquema DBF (bloqueante para el agente)

Antes de escribir el extractor hay que conocer las tablas reales del ERP. Entregable: un `mapping.yaml` por versión de ERP que traduzca nombres reales de tabla/campo a un modelo canónico.

Script de relevamiento (`agent/tools/inspect-dbf.js`): recorre la carpeta de datos, y por cada `.dbf` imprime nombre, número de registros, y la definición de campos (nombre, tipo, largo, decimales) + 3 filas de muestra. Salida a JSON para revisar sin abrir el ERP.

Modelo canónico a mapear (mínimo viable):
- Cabecera de venta: fecha, hora, nº comprobante, cliente, total, condición de pago, anulado.
- Detalle de venta: comprobante, código producto, cantidad, precio unitario, **costo unitario al momento de la venta** (si el ERP no lo guarda, se toma el costo actual del maestro y se documenta como aproximación).
- Maestro de productos: código, descripción, rubro, stock actual, costo, precio de venta.
- Cuentas corrientes: cliente/proveedor, comprobante, fecha, vencimiento, importe, saldo.
- Cheques: número, banco, importe, fecha de emisión, fecha de cobro, estado, tercero.

---

## 1. Esquema de base de datos en la nube (PostgreSQL / Supabase)

Migraciones en `supabase/migrations/`, numeradas y versionadas en git.

### Núcleo multi-tenant

```sql
create table tenants (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  slug          text unique not null,
  timezone      text not null default 'America/Argentina/Buenos_Aires',
  currency      char(3) not null default 'ARS',
  erp_version   text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);

-- Perfil de usuario ligado a auth.users de Supabase
create type app_role as enum ('super_admin','owner','manager');

create table profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  tenant_id  uuid references tenants(id) on delete cascade,  -- null sólo para super_admin
  role       app_role not null default 'manager',
  full_name  text,
  created_at timestamptz not null default now()
);

-- Credencial del agente local. Se guarda SOLO el hash.
create table agent_keys (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references tenants(id) on delete cascade,
  key_hash     text not null,           -- argon2id de la API key
  key_prefix   text not null,           -- primeros 8 chars, para identificar sin revelar
  label        text,
  last_seen_at timestamptz,
  revoked_at   timestamptz,
  created_at   timestamptz not null default now()
);
```

### Hechos sincronizados

Todas las tablas de datos llevan `tenant_id` como primera columna y una PK natural que incluye al tenant, para que el push sea **idempotente vía `UPSERT`** (reenviar un lote nunca duplica).

```sql
-- Grano: un día por tenant. Base de los KPIs y comparativas.
create table sales_daily (
  tenant_id     uuid not null references tenants(id) on delete cascade,
  business_date date not null,
  net_amount    numeric(16,2) not null default 0,
  cost_amount   numeric(16,2) not null default 0,
  tickets       integer not null default 0,
  units         numeric(16,3) not null default 0,
  synced_at     timestamptz not null default now(),
  primary key (tenant_id, business_date)
);

-- Grano: día + hora. Alimenta "días pico" y mapa de calor horario.
create table sales_hourly (
  tenant_id     uuid not null references tenants(id) on delete cascade,
  business_date date not null,
  hour_of_day   smallint not null check (hour_of_day between 0 and 23),
  net_amount    numeric(16,2) not null default 0,
  tickets       integer not null default 0,
  primary key (tenant_id, business_date, hour_of_day)
);

create table products (
  tenant_id    uuid not null references tenants(id) on delete cascade,
  sku          text not null,
  description  text,
  category     text,
  stock_qty    numeric(16,3),
  cost_price   numeric(16,4),
  sale_price   numeric(16,4),
  updated_at   timestamptz not null default now(),
  primary key (tenant_id, sku)
);

-- Grano: producto + día. De aquí salen top ventas, baja rotación y márgenes.
create table product_sales_daily (
  tenant_id     uuid not null references tenants(id) on delete cascade,
  business_date date not null,
  sku           text not null,
  qty           numeric(16,3) not null default 0,
  net_amount    numeric(16,2) not null default 0,
  cost_amount   numeric(16,2) not null default 0,
  primary key (tenant_id, business_date, sku)
);

create type party_kind as enum ('customer','supplier');

-- Saldos abiertos con antigüedad (aging). Snapshot: se reemplaza por tenant en cada sync.
create table account_balances (
  tenant_id    uuid not null references tenants(id) on delete cascade,
  kind         party_kind not null,
  party_code   text not null,
  party_name   text,
  balance      numeric(16,2) not null default 0,
  due_0_30     numeric(16,2) not null default 0,
  due_31_60    numeric(16,2) not null default 0,
  due_61_90    numeric(16,2) not null default 0,
  due_90_plus  numeric(16,2) not null default 0,
  oldest_due   date,
  synced_at    timestamptz not null default now(),
  primary key (tenant_id, kind, party_code)
);

create type check_status as enum
  ('portfolio','deposited','cleared','endorsed','rejected','issued','pending');

create table checks (
  tenant_id     uuid not null references tenants(id) on delete cascade,
  check_number  text not null,
  bank_name     text,
  amount        numeric(16,2) not null,
  issue_date    date,
  due_date      date,
  status        check_status not null,
  is_own        boolean not null default false,  -- true = emitido por el comercio
  party_name    text,
  synced_at     timestamptz not null default now(),
  primary key (tenant_id, check_number, is_own)
);

create table sales_targets (
  tenant_id   uuid not null references tenants(id) on delete cascade,
  period_type text not null check (period_type in ('month','year')),
  period_start date not null,
  target_amount numeric(16,2) not null,
  primary key (tenant_id, period_type, period_start)
);

-- Observabilidad del agente: qué corrió, hasta dónde, con qué resultado.
create table sync_runs (
  id          bigserial primary key,
  tenant_id   uuid not null references tenants(id) on delete cascade,
  dataset     text not null,
  watermark   text,               -- último valor procesado (fecha o id)
  rows_sent   integer,
  status      text not null,      -- ok | partial | error
  error_text  text,
  agent_version text,
  started_at  timestamptz,
  finished_at timestamptz default now()
);
```

Índices adicionales: `product_sales_daily (tenant_id, business_date desc)`, `checks (tenant_id, status, due_date)`, `account_balances (tenant_id, kind, balance desc)`.

### Aislamiento por tenant (RLS) — la pieza crítica

```sql
-- Helper: tenant del usuario autenticado. STABLE para que el planner lo cachee.
create or replace function auth_tenant_id() returns uuid
language sql stable security definer set search_path = public as $$
  select tenant_id from profiles where id = auth.uid()
$$;

create or replace function is_super_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'super_admin')
$$;

alter table sales_daily enable row level security;
create policy tenant_read on sales_daily for select to authenticated
  using (tenant_id = auth_tenant_id() or is_super_admin());
```

Se repite el mismo par `enable row level security` + policy de SELECT en **todas** las tablas de hechos y en `profiles`. Reglas duras:
- Ningún rol `authenticated` tiene INSERT/UPDATE/DELETE sobre tablas de hechos: la escritura entra sólo por la Edge Function de ingesta con `service_role`.
- `agent_keys` no tiene ninguna policy para `authenticated` → invisible desde el cliente.
- Test de regresión obligatorio: un usuario del tenant A consultando cada tabla debe recibir 0 filas del tenant B.

Diferencia de roles: `owner` y `manager` comparten el tenant; `manager` se restringe a nivel de UI/policy adicional para los módulos financieros (cuentas corrientes, cheques) según preferencia del dueño.

---

## 2. Estrategia de sincronización (Agente Local)

**Requisito no negociable: nunca degradar ni bloquear el ERP.**

### Lectura segura de los DBF
- **Sólo lectura, sin locks.** Se abren los `.dbf` en modo lectura y se parsean como archivo (`dbffile`/`node-dbf`), sin escribir en el `.cdx` ni tocar los memos.
- **Copia sombra antes de parsear.** Cada ciclo copia los DBF necesarios a un `staging/` local y parsea la copia. Así una escritura del ERP a mitad de lectura no produce un registro corrupto ni contención de I/O sobre el archivo vivo.
- **Ventana de ejecución y throttling.** Ciclo incremental cada 15 min con lectura en streaming por chunks y pausas entre chunks; el recálculo pesado (reconstrucción de agregados históricos) sólo en ventana nocturna configurable.
- **Prioridad de proceso baja** (`below normal`) para que el ERP siempre gane la CPU y el disco.

### Watermarks e incrementalidad
Estado local en SQLite (`agent/state.db`) con un watermark por dataset:

| Dataset | Watermark | Estrategia |
|---|---|---|
| `sales_daily` / `sales_hourly` / `product_sales_daily` | última `business_date` cerrada | Reprocesa siempre los últimos **N días** (default 7) además de lo nuevo, para capturar comprobantes retroactivos o anulaciones. El UPSERT lo hace inocuo. |
| `products` | hash del archivo + `mtime` | Si el DBF no cambió, se saltea. Si cambió, snapshot completo (los maestros son chicos). |
| `account_balances` | — | Snapshot completo por sync (recálculo del aging contra la fecha de hoy). |
| `checks` | — | Snapshot completo: el volumen es bajo y el estado cambia retroactivamente. |

El agente **agrega localmente**: recorre el detalle de ventas del rango y emite las filas ya sumarizadas por día / día+hora / día+SKU. Un comercio con 200k líneas de venta al mes envía unos pocos miles de filas por ciclo.

### Transporte
- `POST https://<proyecto>.supabase.co/functions/v1/ingest` con `Authorization: Bearer <api_key_del_tenant>`.
- Body: `{ dataset, watermark, rows: [...] }` en **NDJSON comprimido con gzip**, en lotes de ~1000 filas.
- Cada lote lleva `batch_id` (UUID determinístico) → reintento seguro, la Edge Function hace UPSERT idempotente.
- **Cola durable con backoff exponencial:** si no hay internet, los lotes quedan en SQLite y se reintentan (1m, 5m, 15m, 1h…). Nada se pierde por una caída de conexión.
- Sólo tráfico saliente HTTPS 443 → no hace falta abrir puertos, ni IP fija, ni VPN.

### Operación
- Servicio de Windows con `node-windows`, arranque automático, reinicio ante fallo.
- Autoactualización: chequeo de versión contra un endpoint, descarga firmada, reinicio del servicio.
- Heartbeat cada ciclo a `sync_runs` → el panel de super_admin muestra qué comercios dejaron de reportar.
- Instalador `.exe` (Inno Setup) que pide carpeta de datos del ERP y la API key.

---

## 3. Estructura de directorios

```
SUPERVISION/                       # = raíz del repositorio GitHub
├── CLAUDE.md                      # contexto permanente para Claude Code
├── README.md                      # qué es, cómo se instala y se corre
├── ROADMAP.md                     # fases, estado y criterios de "hecho"
├── HANDOFF.md                     # estado actual + próximo paso (se actualiza al cerrar sesión)
│
├── PLANES/                        # todo planeamiento se guarda aquí, versionado
│   ├── README.md                  # índice de planes con fecha y estado
│   └── 2026-09-05-arquitectura-inicial.md
│
├── LINKS-IMPORTANTES/
│   └── README.md                  # accesos: Supabase, Pages, Releases, Actions, docs
│
├── .github/
│   └── workflows/
│       ├── deploy-pwa.yml         # build web -> GitHub Pages
│       ├── release-apk.yml        # build APK firmado -> GitHub Release + version.json
│       └── ci.yml                 # tests de agente, SQL y Flutter en cada PR
│
├── agent/                         # Agente local Node.js (servicio Windows)
│   ├── src/
│   │   ├── index.js               # bootstrap + scheduler
│   │   ├── config/                # config.json + mapping.yaml (por versión de ERP)
│   │   ├── dbf/
│   │   │   ├── reader.js          # lectura sin lock + copia sombra
│   │   │   └── mapper.js          # DBF real -> modelo canónico según mapping.yaml
│   │   ├── extractors/            # sales.js, products.js, accounts.js, checks.js
│   │   ├── aggregators/           # daily.js, hourly.js, productDaily.js, aging.js
│   │   ├── state/                 # SQLite: watermarks + cola de lotes
│   │   ├── transport/             # httpClient.js, queue.js, retry.js
│   │   └── service/               # install/uninstall node-windows
│   ├── tools/inspect-dbf.js       # relevamiento de esquema (Fase 0)
│   └── installer/                 # script Inno Setup
│
├── supabase/
│   ├── migrations/                # 001_tenants.sql, 002_facts.sql, 003_rls.sql...
│   ├── functions/
│   │   ├── ingest/                # recibe lotes del agente (service_role)
│   │   └── kpis/                  # endpoints de comparativas y márgenes
│   └── seed.sql
│
├── app/                           # Flutter: PWA (web) + APK (Android)
│   ├── lib/
│   │   ├── main.dart
│   │   ├── core/                  # theme (dark/glass), router, env, errores
│   │   ├── data/
│   │   │   ├── supabase_client.dart
│   │   │   ├── models/            # freezed + json_serializable
│   │   │   └── repositories/      # sales_repo, products_repo, finance_repo
│   │   ├── features/
│   │   │   ├── auth/              # login, sesión, guard de rol
│   │   │   ├── dashboard/         # KPIs, comparativas, días pico, metas
│   │   │   ├── products/          # top ventas, baja rotación, márgenes
│   │   │   ├── accounts/          # cuentas corrientes + aging
│   │   │   ├── checks/            # cartera de cheques
│   │   │   └── update/            # chequeo de versión + descarga del APK (sólo Android)
│   │   └── shared/widgets/        # KpiCard, TrendBadge, GlassContainer, charts
│   ├── web/                       # manifest.json + service worker (PWA instalable)
│   └── android/                   # config del APK
│
└── docs/                          # arquitectura, runbook de instalación, mapeos por ERP
```

Frontend: Flutter con `supabase_flutter` (auth + PostgREST), `riverpod` (estado), `go_router` (navegación), `fl_chart` (gráficos), `google_fonts`. Tema dark por defecto con superficies translúcidas (`BackdropFilter`) para el look glassmorphism, respetando `MediaQuery.disableAnimations` para accesibilidad.

---

## 4. Código clave: endpoint de comparativas y márgenes

La lógica pesada vive en Postgres (funciones `SECURITY INVOKER`, para que la RLS del usuario siga aplicando) y la Edge Function sólo orquesta y da forma al JSON.

### 4.1 Función SQL de comparativa de ventas

```sql
-- SECURITY INVOKER: hereda la RLS del usuario -> imposible leer otro tenant.
create or replace function sales_comparison(p_reference date default current_date)
returns table (
  period      text,
  current_amount  numeric,
  previous_amount numeric,
  delta_amount    numeric,
  delta_pct       numeric
)
language sql stable security invoker as $$
with periods as (
  select 'day'   as period, p_reference as cur_from, p_reference as cur_to,
         p_reference - 1 as prev_from, p_reference - 1 as prev_to
  union all
  select 'week',  date_trunc('week',  p_reference)::date, p_reference,
         (date_trunc('week',  p_reference) - interval '7 day')::date,
         (p_reference - 7)
  union all
  select 'month', date_trunc('month', p_reference)::date, p_reference,
         (date_trunc('month', p_reference) - interval '1 month')::date,
         (p_reference - interval '1 month')::date
  union all
  select 'year',  date_trunc('year',  p_reference)::date, p_reference,
         (date_trunc('year',  p_reference) - interval '1 year')::date,
         (p_reference - interval '1 year')::date
)
select
  p.period,
  coalesce(c.amt, 0) as current_amount,
  coalesce(v.amt, 0) as previous_amount,
  coalesce(c.amt,0) - coalesce(v.amt,0) as delta_amount,
  case when coalesce(v.amt,0) = 0 then null      -- null = "sin base de comparación"
       else round((coalesce(c.amt,0) - v.amt) / v.amt * 100, 2)
  end as delta_pct
from periods p
left join lateral (
  select sum(net_amount) amt from sales_daily s
   where s.business_date between p.cur_from and p.cur_to) c on true
left join lateral (
  select sum(net_amount) amt from sales_daily s
   where s.business_date between p.prev_from and p.prev_to) v on true;
$$;
```

Nota de diseño: los períodos previos se cortan **al mismo día relativo** (mes actual hasta hoy vs. mes anterior hasta el mismo día), no contra el mes anterior completo — comparar 5 días contra 30 daría una caída falsa del 80%. `delta_pct` devuelve `null` cuando el período anterior fue 0, y la UI muestra "—" en vez de un ∞.

### 4.2 Función SQL de márgenes por producto

```sql
create or replace function product_margins(
  p_from date, p_to date, p_order text default 'margin_pct_desc', p_limit int default 50
)
returns table (
  sku text, description text, qty numeric, revenue numeric,
  cost numeric, margin_amount numeric, margin_pct numeric
)
language sql stable security invoker as $$
  select
    d.sku,
    max(p.description) as description,
    sum(d.qty)                          as qty,
    sum(d.net_amount)                   as revenue,
    sum(d.cost_amount)                  as cost,
    sum(d.net_amount - d.cost_amount)   as margin_amount,
    case when sum(d.net_amount) = 0 then null
         else round(sum(d.net_amount - d.cost_amount) / sum(d.net_amount) * 100, 2)
    end as margin_pct
  from product_sales_daily d
  left join products p on p.tenant_id = d.tenant_id and p.sku = d.sku
  where d.business_date between p_from and p_to
  group by d.sku
  order by
    case when p_order = 'margin_pct_desc'  then margin_pct     end desc nulls last,
    case when p_order = 'margin_pct_asc'   then margin_pct     end asc  nulls last,
    case when p_order = 'margin_amount_desc' then margin_amount end desc nulls last,
    case when p_order = 'revenue_desc'     then revenue        end desc nulls last,
    case when p_order = 'qty_desc'         then qty            end desc nulls last
  limit least(p_limit, 500);
$$;
```

Margen sobre **precio de venta** (`margen / ingreso`), no sobre costo — es la convención comercial habitual; queda documentado para evitar ambigüedad. Baja rotación = SKUs con `stock_qty > 0` en `products` sin filas en `product_sales_daily` en los últimos N días (LEFT JOIN + `IS NULL`).

### 4.3 Edge Function que compone el dashboard

```ts
// supabase/functions/kpis/index.ts
import { createClient } from 'jsr:@supabase/supabase-js@2'

Deno.serve(async (req) => {
  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return json({ error: 'unauthorized' }, 401)

  // Cliente con el JWT del usuario -> la RLS decide qué tenant se ve.
  // Nunca se acepta un tenant_id que venga del request.
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  )

  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return json({ error: 'unauthorized' }, 401)

  const url = new URL(req.url)
  const reference = url.searchParams.get('date') ?? new Date().toISOString().slice(0, 10)
  const from = url.searchParams.get('from') ?? reference.slice(0, 8) + '01'

  const [comparison, margins, peaks] = await Promise.all([
    supabase.rpc('sales_comparison', { p_reference: reference }),
    supabase.rpc('product_margins', { p_from: from, p_to: reference, p_limit: 20 }),
    supabase.rpc('peak_days', { p_from: from, p_to: reference }),
  ])

  const firstError = [comparison, margins, peaks].find(r => r.error)?.error
  if (firstError) {
    console.error('kpis rpc failed', firstError)      // detalle al log, no al cliente
    return json({ error: 'internal_error' }, 500)
  }

  return json({
    reference,
    comparison: comparison.data,
    margins: margins.data,
    peaks: peaks.data,
  })
})

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', 'Cache-Control': 'private, max-age=60' },
  })
```

### 4.4 Edge Function de ingesta (esqueleto)

Autentica la API key del agente (argon2 contra `agent_keys`, comparación en tiempo constante), resuelve el `tenant_id` **desde la key** (nunca desde el body), valida el payload con Zod, y hace UPSERT por lotes con `service_role`. Registra el resultado en `sync_runs` y actualiza `last_seen_at`. Rate limit por tenant.

---

## 5. Buenas prácticas de seguridad

**En tránsito**
- HTTPS/TLS 1.3 obligatorio en todos los saltos; HSTS en la PWA.
- Certificate pinning en el agente local contra el dominio de Supabase (evita interceptación por proxies corporativos mal configurados en el comercio).
- El agente **sólo hace conexiones salientes**: cero superficie de ataque entrante en la red del comercio.

**En reposo**
- Postgres de Supabase con cifrado de disco; backups automáticos (PITR) y prueba de restauración documentada.
- La API key del agente se guarda en el equipo del comercio con **DPAPI de Windows** (ligada a la cuenta del servicio), nunca en texto plano en un `.json`.
- En la nube se guarda **sólo el hash argon2id** de la key + un prefijo de 8 caracteres para identificarla. La key completa se muestra una única vez al generarla.
- El dispositivo móvil no persiste datos financieros crudos: caché offline sólo de los agregados ya visibles, en `flutter_secure_storage` (Keystore/Keychain), con purga al cerrar sesión.

**Sesiones y autorización**
- Supabase Auth con JWT de vida corta (1h) + refresh token rotativo; revocación inmediata al desactivar un usuario.
- **La RLS es la única fuente de verdad del aislamiento.** El `tenant_id` jamás se toma de un parámetro del cliente; se deriva de `auth.uid()`. Aunque la UI tuviera un bug, la base no devuelve datos ajenos.
- `service_role` key exclusivamente del lado servidor (Edge Functions). Nunca en el bundle de Flutter — recordar que el build web es público e inspeccionable.
- 2FA (TOTP) obligatorio para `super_admin`.
- Rate limiting en login y en `/ingest`; bloqueo temporal tras intentos fallidos.
- Auditoría: `sync_runs` para el agente, y log de accesos a módulos financieros por usuario.
- Rotación de API keys sin downtime: `agent_keys` admite varias keys activas por tenant → se emite la nueva, se actualiza el agente, se revoca la vieja.

---

---

## 6. Repositorio, documentación y despliegue en GitHub

### 6.1 Repositorio

Un único repo (monorepo) con `agent/`, `supabase/`, `app/` y la documentación. Rama `main` protegida; el trabajo entra por PR.

**Decisión pendiente — visibilidad del repo:** GitHub Pages sobre un repositorio **privado** requiere plan Pro/Team. Si el repo es privado y no hay plan pago, la PWA debe publicarse desde un segundo repo público que sólo contenga el build (`app-web-dist`), o en Cloudflare Pages / Netlify. **Recomendación:** repo privado (contiene lógica de negocio y mapeos de ERP) + repo público `supervision-pwa` con sólo el artefacto compilado.

**Nada de secretos en el repo.** `SUPABASE_URL` y la `anon key` van como variables de build (son públicas por diseño, la RLS es la que protege). `service_role`, keystore de firma y credenciales de agentes viven en **GitHub Secrets** / Supabase Vault. `.gitignore` bloquea `*.jks`, `*.keystore`, `agent/config/config.json`, `state.db`, `.env*`.

### 6.2 Documentos raíz

| Archivo | Contenido |
|---|---|
| `CLAUDE.md` | Contexto permanente para Claude Code: qué es el proyecto, stack y por qué, convenciones (SQL en migraciones numeradas, RLS obligatoria en toda tabla nueva, `tenant_id` nunca desde el cliente), comandos habituales (`supabase start`, `flutter run -d chrome`, tests del agente), y la regla de que **todo planeamiento se escribe en `PLANES/`**. |
| `README.md` | Qué resuelve el sistema, diagrama de arquitectura, requisitos, cómo levantar cada pieza en local, cómo instalar el agente en un comercio, y enlaces a los demás documentos. |
| `ROADMAP.md` | Las 6 fases con checkboxes, criterio de "hecho" por fase, y estado actual. Se actualiza al cerrar cada fase. |
| `HANDOFF.md` | Estado vivo: qué está terminado, qué está a medias y dónde, decisiones tomadas y por qué, problemas conocidos, y **el próximo paso concreto**. Se actualiza al final de cada sesión de trabajo. |

### 6.3 `PLANES/` y `LINKS-IMPORTANTES/`

- **`PLANES/`** — todo plan de trabajo se guarda aquí como Markdown versionado, nombrado `YYYY-MM-DD-tema.md`, con encabezado `Estado: propuesto | aprobado | en curso | completado | descartado`. `PLANES/README.md` es el índice. Este mismo documento se copia como `PLANES/2026-09-05-arquitectura-inicial.md` en el primer commit.
- **`LINKS-IMPORTANTES/README.md`** — tabla de accesos operativos: dashboard de Supabase, URL de la PWA, página de Releases (APK), GitHub Actions, `version.json`, docs de FoxPro/DBF y de las librerías clave. Sólo URLs y para qué sirve cada una — **ninguna credencial**.

### 6.4 Despliegue de la PWA (GitHub Pages)

Workflow `deploy-pwa.yml`, disparado por push a `main` que toque `app/`:

```yaml
- run: flutter build web --release --base-href /supervision/ \
       --dart-define=SUPABASE_URL=${{ vars.SUPABASE_URL }} \
       --dart-define=SUPABASE_ANON_KEY=${{ vars.SUPABASE_ANON_KEY }}
- uses: actions/upload-pages-artifact@v3
  with: { path: app/build/web }
- uses: actions/deploy-pages@v4
```

Detalles que hacen que la PWA **no** quede "rota":
- `--base-href` debe coincidir con el nombre del repo (`/supervision/`), o todos los assets dan 404. Con dominio propio, `/`.
- Archivo `.nojekyll` en la raíz publicada: sin él, GitHub Pages ignora los directorios que empiezan con `_`.
- `404.html` que redirige al `index.html` para que las rutas de `go_router` funcionen al recargar.
- El service worker de Flutter se versiona por build; forzar `flutter build web --pwa-strategy=offline-first` y mostrar un aviso "hay una versión nueva, recargar" cuando el SW detecte actualización — evita la app cacheada eternamente, que es la causa típica de la sensación de PWA rota.
- `manifest.json` completo: nombre, iconos 192/512 + maskable, `display: standalone`, `theme_color` acorde al tema dark.

### 6.5 APK autoactualizable (GitHub Releases)

Al no distribuirse por Play Store, la actualización es propia:

**Publicación** — `release-apk.yml`, disparado por tag `v*.*.*`:
1. `flutter build apk --release --split-per-abi` firmado con el keystore desde GitHub Secrets (`KEYSTORE_BASE64`, `KEY_ALIAS`, `KEY_PASSWORD`, `STORE_PASSWORD`).
2. Crea un GitHub Release con los APKs adjuntos.
3. Publica/actualiza `version.json` (en la rama de Pages, que es pública y cacheable):

```json
{
  "version": "1.4.0",
  "build": 140,
  "min_supported_build": 120,
  "apk_url": "https://github.com/<owner>/<repo>/releases/download/v1.4.0/app-arm64-v8a-release.apk",
  "sha256": "…",
  "notes": "Módulo de cheques y filtro por rubro",
  "mandatory": false
}
```

**Consumo en la app** (sólo en Android; en web el update lo maneja el service worker):
1. Al abrir, consulta `version.json` (con timeout corto y fallo silencioso — nunca bloquear el arranque por el chequeo).
2. Compara `build` contra el propio (`package_info_plus`). Si `min_supported_build` es mayor al instalado, la actualización es obligatoria y bloquea el uso.
3. Muestra un diálogo con las notas y descarga el APK (`dio` con barra de progreso).
4. **Verifica el `sha256` del archivo descargado antes de instalar** — si no coincide, se descarta y se avisa. Esto es lo que impide instalar un binario alterado en tránsito.
5. Lanza el instalador del sistema (`open_filex` / intent de instalación). Requiere el permiso `REQUEST_INSTALL_PACKAGES` y que el usuario acepte la instalación: la app **no** instala nada por sí sola, siempre hay confirmación explícita del usuario.

Si el repo es privado, los assets de Release requieren token → en ese caso `version.json` y los APK se publican en el repo público de distribución.

---

## Orden de implementación

0. **Scaffolding del repo** — estructura de carpetas, `CLAUDE.md`, `README.md`, `ROADMAP.md`, `HANDOFF.md`, `PLANES/` (con este plan dentro), `LINKS-IMPORTANTES/`, `.gitignore` y commit inicial a GitHub.
1. **Fase 0** — `inspect-dbf.js` sobre una instalación real; producir `mapping.yaml`.
2. **Esquema** — migraciones SQL + RLS + funciones, probadas en Postgres local (`supabase start`) mientras el proyecto en la nube esté limitado.
3. **Agente** — extractores + agregadores + cola durable; primero contra el Postgres local.
4. **Edge Functions** — `ingest` y `kpis`.
5. **Flutter** — auth y guard de rol → dashboard de KPIs → productos → finanzas → PWA/APK.
6. **Empaquetado y CI/CD** — servicio de Windows + instalador; workflows de Pages y de Release del APK; módulo de autoactualización.

## Verificación

- **Aislamiento (lo más importante):** crear tenants A y B con datos distintos; autenticado como usuario de A, consultar cada tabla y cada RPC → cero filas de B. Repetir intentando forzar un `tenant_id` de B por parámetro. Test automatizado, se corre en cada cambio de policy.
- **Idempotencia del sync:** enviar el mismo lote 3 veces → los totales de `sales_daily` no cambian.
- **Corrección de KPIs:** contra un dataset semilla con totales calculados a mano, verificar `sales_comparison` (incluidos los bordes: período previo en 0, cambio de año, mes parcial) y `product_margins`.
- **Resiliencia del agente:** cortar la red a mitad de sync → los lotes quedan encolados y se entregan al reconectar, sin duplicar ni perder.
- **No intrusión en el ERP:** correr el agente con el ERP en uso normal y medir latencia de operaciones del ERP antes/durante; verificar que ningún `.dbf` cambia de `mtime` por acción del agente.
- **PWA/APK:** Lighthouse sobre el build web (instalable, offline shell); `flutter build apk --release` instalado en un dispositivo físico, probando login, dashboard y modo avión.
- **Despliegue Pages:** abrir la URL publicada, recargar estando en una ruta interna (ej. `/products`) → debe cargar, no dar 404. Publicar una versión nueva y confirmar que el aviso de "nueva versión" aparece y que tras recargar se ve el cambio (sin caché pegada).
- **Autoactualización del APK:** instalar el build `n`, publicar el tag `n+1`, abrir la app → debe ofrecer la actualización, descargarla, validar el sha256 y llegar al instalador. Probar además el camino de fallo: `version.json` inalcanzable (la app arranca igual) y sha256 alterado a mano (debe rechazar la instalación).
- **Secretos:** `git log -p` y un escaneo de secretos sobre el repo → cero keystores, `service_role` o API keys de agente commiteadas.
