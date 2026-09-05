-- ============================================================================
-- Seed de desarrollo: DOS comercios con datos distintos.
--
-- Que sean dos no es decorativo. Es la única forma de probar lo que más importa
-- del sistema: que el comercio A jamás vea una fila del comercio B.
--
-- Los números están armados para poder verificarlos a mano:
--   - Todos los días venden 100, salvo HOY que vende 150 en Norte.
--     => la comparativa día vs día anterior tiene que dar exactamente +50 (+50%).
--     => y como el período anterior se recorta al mismo día relativo, la
--        diferencia de semana, mes y año también tiene que ser +50, no un
--        derrumbe porcentual por comparar 5 días contra 30.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Comercios
-- ---------------------------------------------------------------------------
insert into tenants (id, name, slug, timezone, erp_version) values
  ('11111111-1111-1111-1111-111111111111', 'Almacén Norte', 'norte',
   'America/Argentina/Buenos_Aires', 'FoxPro 2.6'),
  ('22222222-2222-2222-2222-222222222222', 'Kiosco Sur', 'sur',
   'America/Argentina/Buenos_Aires', 'Visual FoxPro 9');

-- ---------------------------------------------------------------------------
-- Usuarios
-- ---------------------------------------------------------------------------
-- El trigger `on_auth_user_created` arma el perfil a partir de raw_user_meta_data.
-- Contraseña de todos: "password123"
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data
)
values
  ('00000000-0000-0000-0000-000000000000',
   'aaaaaaaa-0000-0000-0000-000000000001', 'authenticated', 'authenticated',
   'admin@supervision.test', crypt('password123', gen_salt('bf')),
   now(), now(), now(),
   '{"provider":"email","providers":["email"]}',
   '{"full_name":"Administrador General","role":"super_admin"}'),

  ('00000000-0000-0000-0000-000000000000',
   'aaaaaaaa-0000-0000-0000-000000000002', 'authenticated', 'authenticated',
   'norte@supervision.test', crypt('password123', gen_salt('bf')),
   now(), now(), now(),
   '{"provider":"email","providers":["email"]}',
   '{"full_name":"Dueño de Almacén Norte","role":"owner","tenant_id":"11111111-1111-1111-1111-111111111111"}'),

  ('00000000-0000-0000-0000-000000000000',
   'aaaaaaaa-0000-0000-0000-000000000003', 'authenticated', 'authenticated',
   'sur@supervision.test', crypt('password123', gen_salt('bf')),
   now(), now(), now(),
   '{"provider":"email","providers":["email"]}',
   '{"full_name":"Dueño de Kiosco Sur","role":"owner","tenant_id":"22222222-2222-2222-2222-222222222222"}'),

  -- Encargado de Norte: ve ventas y productos, NO ve cuentas corrientes ni cheques.
  ('00000000-0000-0000-0000-000000000000',
   'aaaaaaaa-0000-0000-0000-000000000004', 'authenticated', 'authenticated',
   'encargado.norte@supervision.test', crypt('password123', gen_salt('bf')),
   now(), now(), now(),
   '{"provider":"email","providers":["email"]}',
   '{"full_name":"Encargado de Norte","role":"manager","tenant_id":"11111111-1111-1111-1111-111111111111"}');

-- ---------------------------------------------------------------------------
-- Claves de agente (hash ficticio: el real lo genera la Edge Function)
-- ---------------------------------------------------------------------------
insert into agent_keys (tenant_id, key_hash, key_prefix, label) values
  ('11111111-1111-1111-1111-111111111111', 'seed-no-usar', 'sk_norte', 'Servidor del local (seed)'),
  ('22222222-2222-2222-2222-222222222222', 'seed-no-usar', 'sk_sur__', 'Servidor del local (seed)');

-- ---------------------------------------------------------------------------
-- Ventas diarias: 800 días hacia atrás, 100 por día en ambos comercios
-- ---------------------------------------------------------------------------
insert into sales_daily (tenant_id, business_date, net_amount, cost_amount, tickets, units)
select
  t.id,
  d::date,
  100, 60, 4, 12
from tenants t
cross join generate_series(current_date - 800, current_date, interval '1 day') d;

-- Hoy Norte vende 50 más. Es el único desvío del seed, y el que hace medibles
-- todas las comparativas.
update sales_daily
   set net_amount = 150, cost_amount = 90, tickets = 6
 where tenant_id = '11111111-1111-1111-1111-111111111111'
   and business_date = current_date;

-- ---------------------------------------------------------------------------
-- Ventas por hora: concentradas al mediodía y a la tarde, como un comercio real
-- ---------------------------------------------------------------------------
insert into sales_hourly (tenant_id, business_date, hour_of_day, net_amount, tickets)
select
  t.id,
  d::date,
  h.hour,
  h.weight,
  greatest(1, (h.weight / 10)::integer)
from tenants t
cross join generate_series(current_date - 90, current_date, interval '1 day') d
cross join (values (9, 5), (10, 10), (11, 15), (12, 25), (13, 10),
                   (17, 15), (18, 12), (19, 8)) as h(hour, weight);

-- ---------------------------------------------------------------------------
-- Productos
-- ---------------------------------------------------------------------------
insert into products (tenant_id, sku, description, category, stock_qty, cost_price, sale_price) values
  -- Almacén Norte
  ('11111111-1111-1111-1111-111111111111', 'CAF001', 'Café molido 500g',      'Almacén',   40,  60.0000, 100.0000),
  ('11111111-1111-1111-1111-111111111111', 'AZU001', 'Azúcar 1kg',            'Almacén',   80,  80.0000, 100.0000),
  ('11111111-1111-1111-1111-111111111111', 'YER001', 'Yerba Ñandú 1kg',       'Almacén',   25,   0.0000, 200.0000),
  -- Con stock y sin ventas: tiene que aparecer en baja rotación.
  ('11111111-1111-1111-1111-111111111111', 'LIC001', 'Licuadora de vidrio',   'Bazar',     12, 500.0000, 900.0000),
  -- Vendido hace mucho: también es baja rotación en una ventana de 60 días.
  ('11111111-1111-1111-1111-111111111111', 'VEL001', 'Velas aromáticas',      'Bazar',     30,  20.0000,  50.0000),
  -- Sin stock: NO debe aparecer en baja rotación, no hay plata inmovilizada.
  ('11111111-1111-1111-1111-111111111111', 'AGO001', 'Producto agotado',      'Almacén',    0,  10.0000,  30.0000),

  -- Kiosco Sur
  ('22222222-2222-2222-2222-222222222222', 'GOL001', 'Golosinas surtidas',    'Kiosco',   200,  10.0000,  25.0000),
  ('22222222-2222-2222-2222-222222222222', 'GAS001', 'Gaseosa 500ml',         'Bebidas',  150,  30.0000,  60.0000);

-- ---------------------------------------------------------------------------
-- Ventas por producto — últimos 30 días, con márgenes exactos y conocidos
-- ---------------------------------------------------------------------------
--   CAF001: 1000 de venta, 600 de costo -> margen 40%
--   AZU001:  500 de venta, 400 de costo -> margen 20%
--   YER001:  200 de venta,   0 de costo -> margen 100%
insert into product_sales_daily
  (tenant_id, business_date, sku, qty, net_amount, cost_amount, cost_is_estimated)
select
  '11111111-1111-1111-1111-111111111111',
  d::date, p.sku, p.qty, p.revenue, p.cost, p.estimated
from generate_series(current_date - 29, current_date, interval '1 day') d
cross join (values
  ('CAF001', 10.0, 1000.0, 600.0, false),
  ('AZU001',  5.0,  500.0, 400.0, false),
  -- Costo aproximado: el ERP no guardaba el costo del momento para este producto.
  ('YER001',  2.0,  200.0,   0.0, true)
) as p(sku, qty, revenue, cost, estimated);

-- Venta vieja de VEL001: fuera de la ventana de 60 días de baja rotación.
insert into product_sales_daily (tenant_id, business_date, sku, qty, net_amount, cost_amount)
values ('11111111-1111-1111-1111-111111111111', current_date - 200, 'VEL001', 3, 150, 60);

insert into product_sales_daily (tenant_id, business_date, sku, qty, net_amount, cost_amount)
select
  '22222222-2222-2222-2222-222222222222',
  d::date, 'GOL001', 20.0, 500.0, 200.0
from generate_series(current_date - 29, current_date, interval '1 day') d;

-- ---------------------------------------------------------------------------
-- Cuentas corrientes
-- ---------------------------------------------------------------------------
insert into account_balances
  (tenant_id, kind, party_code, party_name, balance, due_0_30, due_31_60, due_61_90, due_90_plus, oldest_due)
values
  ('11111111-1111-1111-1111-111111111111', 'customer', 'CLI001', 'Rotisería La Esquina', 45000, 20000, 15000,  10000,     0, current_date - 75),
  ('11111111-1111-1111-1111-111111111111', 'customer', 'CLI002', 'Panadería San José',   12000, 12000,     0,      0,     0, current_date - 10),
  -- Deuda vieja: la que hay que ir a cobrar primero.
  ('11111111-1111-1111-1111-111111111111', 'customer', 'CLI003', 'Almacén Don Pedro',    80000,     0,     0,      0, 80000, current_date - 200),
  ('11111111-1111-1111-1111-111111111111', 'supplier', 'PRV001', 'Distribuidora Central', 150000, 150000, 0,      0,     0, current_date + 15),
  ('22222222-2222-2222-2222-222222222222', 'customer', 'CLI900', 'Cliente del Sur',       5000,  5000,     0,      0,     0, current_date - 5);

-- ---------------------------------------------------------------------------
-- Cheques
-- ---------------------------------------------------------------------------
insert into checks (tenant_id, check_number, bank_name, amount, issue_date, due_date, status, is_own, party_name) values
  ('11111111-1111-1111-1111-111111111111', '00012345', 'Banco Nación',   35000, current_date - 20, current_date + 10, 'portfolio', false, 'Rotisería La Esquina'),
  ('11111111-1111-1111-1111-111111111111', '00012346', 'Banco Galicia',  18000, current_date - 40, current_date - 5,  'deposited', false, 'Panadería San José'),
  ('11111111-1111-1111-1111-111111111111', '00012347', 'Banco Provincia', 9000, current_date - 90, current_date - 60, 'rejected',  false, 'Almacén Don Pedro'),
  ('11111111-1111-1111-1111-111111111111', '00012348', 'Banco Nación',   22000, current_date - 15, current_date + 30, 'endorsed',  false, 'Distribuidora Central'),
  -- Mismo número que uno recibido, pero propio: por eso `is_own` es parte de la clave.
  ('11111111-1111-1111-1111-111111111111', '00012345', 'Banco Nación',   50000, current_date - 5,  current_date + 20, 'issued',    true,  'Distribuidora Central'),
  ('22222222-2222-2222-2222-222222222222', '00099999', 'Banco Macro',     3000, current_date - 3,  current_date + 25, 'portfolio', false, 'Cliente del Sur');

-- ---------------------------------------------------------------------------
-- Metas
-- ---------------------------------------------------------------------------
insert into sales_targets (tenant_id, period_type, period_start, target_amount) values
  ('11111111-1111-1111-1111-111111111111', 'month', date_trunc('month', current_date)::date, 5000),
  ('11111111-1111-1111-1111-111111111111', 'year',  date_trunc('year', current_date)::date, 50000),
  ('22222222-2222-2222-2222-222222222222', 'month', date_trunc('month', current_date)::date, 3000);

-- ---------------------------------------------------------------------------
-- Historial de sincronización
-- ---------------------------------------------------------------------------
insert into sync_runs (tenant_id, dataset, watermark, rows_sent, status, agent_version, started_at, finished_at) values
  ('11111111-1111-1111-1111-111111111111', 'sales_daily', current_date::text, 7, 'ok', '0.1.0', now() - interval '15 min', now() - interval '14 min'),
  ('11111111-1111-1111-1111-111111111111', 'products',    'hash-abc123',    6, 'ok', '0.1.0', now() - interval '15 min', now() - interval '14 min'),
  -- Un comercio con el agente caído hace días: el panel de super_admin lo tiene que mostrar.
  ('22222222-2222-2222-2222-222222222222', 'sales_daily', (current_date - 4)::text, 0, 'error', '0.1.0', now() - interval '4 days', now() - interval '4 days');
