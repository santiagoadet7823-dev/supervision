-- ============================================================================
-- 002 — Tablas de hechos: lo que el agente local sincroniza desde el ERP
--
-- Dos reglas transversales:
--
--  1. Toda tabla lleva `tenant_id` y una PK natural que lo incluye. Eso hace que
--     el push del agente sea IDEMPOTENTE vía UPSERT: si se corta la red y el
--     lote se reenvía, los totales no se duplican.
--
--  2. Acá entran agregados, no transacciones crudas. El agente ya sumarizó por
--     día / hora / producto. El dashboard nunca escanea líneas de venta.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Ventas agregadas por día — base de todos los KPIs y comparativas
-- ---------------------------------------------------------------------------
create table sales_daily (
  tenant_id     uuid not null references tenants (id) on delete cascade,
  -- Día comercial según la timezone del tenant, no UTC.
  business_date date not null,
  net_amount    numeric(16, 2) not null default 0,
  cost_amount   numeric(16, 2) not null default 0,
  tickets       integer not null default 0,
  units         numeric(16, 3) not null default 0,
  synced_at     timestamptz not null default now(),

  primary key (tenant_id, business_date)
);

-- Casi toda consulta es "este tenant, últimos N días, más reciente primero".
create index sales_daily_recent_idx
  on sales_daily (tenant_id, business_date desc);

-- ---------------------------------------------------------------------------
-- Ventas por día y hora — alimenta días pico y mapa de calor horario
-- ---------------------------------------------------------------------------
create table sales_hourly (
  tenant_id     uuid not null references tenants (id) on delete cascade,
  business_date date not null,
  hour_of_day   smallint not null check (hour_of_day between 0 and 23),
  net_amount    numeric(16, 2) not null default 0,
  tickets       integer not null default 0,
  synced_at     timestamptz not null default now(),

  primary key (tenant_id, business_date, hour_of_day)
);

create index sales_hourly_recent_idx
  on sales_hourly (tenant_id, business_date desc);

-- ---------------------------------------------------------------------------
-- Maestro de productos — snapshot, se reemplaza cuando cambia el DBF
-- ---------------------------------------------------------------------------
create table products (
  tenant_id   uuid not null references tenants (id) on delete cascade,
  sku         text not null,
  description text,
  category    text,
  stock_qty   numeric(16, 3),
  -- 4 decimales: los costos unitarios del ERP suelen tenerlos, y redondear acá
  -- desviaría los márgenes al multiplicar por cantidades grandes.
  cost_price  numeric(16, 4),
  sale_price  numeric(16, 4),
  updated_at  timestamptz not null default now(),

  primary key (tenant_id, sku)
);

create index products_category_idx on products (tenant_id, category);

-- Para detectar baja rotación: productos con stock que no se venden.
create index products_with_stock_idx
  on products (tenant_id)
  where stock_qty > 0;

-- ---------------------------------------------------------------------------
-- Ventas por producto y día — top ventas, baja rotación y márgenes
-- ---------------------------------------------------------------------------
create table product_sales_daily (
  tenant_id     uuid not null references tenants (id) on delete cascade,
  business_date date not null,
  sku           text not null,
  qty           numeric(16, 3) not null default 0,
  net_amount    numeric(16, 2) not null default 0,
  -- Costo al momento de la venta si el ERP lo guarda; si no, aproximado con el
  -- costo actual del maestro. Ver `cost_is_estimated`.
  cost_amount   numeric(16, 2) not null default 0,
  -- true = el margen histórico de esta fila es aproximado. La UI lo debe avisar
  -- en vez de mostrar un número que parece exacto y no lo es.
  cost_is_estimated boolean not null default false,
  synced_at     timestamptz not null default now(),

  primary key (tenant_id, business_date, sku)
);

create index product_sales_daily_recent_idx
  on product_sales_daily (tenant_id, business_date desc);

create index product_sales_daily_sku_idx
  on product_sales_daily (tenant_id, sku, business_date desc);

-- ---------------------------------------------------------------------------
-- Cuentas corrientes — snapshot con antigüedad de deuda calculada por el agente
-- ---------------------------------------------------------------------------
create type party_kind as enum ('customer', 'supplier');

create table account_balances (
  tenant_id   uuid not null references tenants (id) on delete cascade,
  kind        party_kind not null,
  party_code  text not null,
  party_name  text,
  balance     numeric(16, 2) not null default 0,
  due_0_30    numeric(16, 2) not null default 0,
  due_31_60   numeric(16, 2) not null default 0,
  due_61_90   numeric(16, 2) not null default 0,
  due_90_plus numeric(16, 2) not null default 0,
  oldest_due  date,
  synced_at   timestamptz not null default now(),

  primary key (tenant_id, kind, party_code)
);

-- "Quién me debe más" y "a quién le debo más" son las dos consultas del módulo.
create index account_balances_ranking_idx
  on account_balances (tenant_id, kind, balance desc);

-- ---------------------------------------------------------------------------
-- Cheques
-- ---------------------------------------------------------------------------
create type check_status as enum (
  'portfolio',  -- en cartera, recibido y sin depositar
  'deposited',  -- depositado, pendiente de acreditación
  'cleared',    -- cobrado / acreditado
  'endorsed',   -- endosado a un tercero
  'rejected',   -- rechazado
  'issued',     -- emitido por el comercio, aún no debitado
  'pending'     -- a fecha, todavía no vencido
);

create table checks (
  tenant_id    uuid not null references tenants (id) on delete cascade,
  check_number text not null,
  bank_name    text,
  amount       numeric(16, 2) not null,
  issue_date   date,
  due_date     date,
  status       check_status not null,
  -- Un cheque propio y uno de tercero pueden compartir número: por eso `is_own`
  -- forma parte de la clave primaria.
  is_own       boolean not null default false,
  party_name   text,
  synced_at    timestamptz not null default now(),

  primary key (tenant_id, check_number, is_own)
);

-- "Qué se me vence esta semana" es la consulta principal de la cartera.
create index checks_due_idx on checks (tenant_id, status, due_date);

-- ---------------------------------------------------------------------------
-- Metas de venta — las carga el dueño desde la app, no vienen del ERP
-- ---------------------------------------------------------------------------
create table sales_targets (
  tenant_id     uuid not null references tenants (id) on delete cascade,
  period_type   text not null check (period_type in ('month', 'year')),
  period_start  date not null,
  target_amount numeric(16, 2) not null check (target_amount > 0),
  updated_at    timestamptz not null default now(),

  primary key (tenant_id, period_type, period_start)
);

-- ---------------------------------------------------------------------------
-- Observabilidad del agente
-- ---------------------------------------------------------------------------
-- Sin esto no hay forma de saber que el servidor de un comercio dejó de
-- reportar hace cuatro días y el dueño está mirando datos viejos.
create table sync_runs (
  id            bigserial primary key,
  tenant_id     uuid not null references tenants (id) on delete cascade,
  dataset       text not null,
  watermark     text,
  rows_sent     integer,
  status        text not null check (status in ('ok', 'partial', 'error')),
  error_text    text,
  agent_version text,
  started_at    timestamptz,
  finished_at   timestamptz not null default now()
);

create index sync_runs_tenant_recent_idx
  on sync_runs (tenant_id, finished_at desc);
