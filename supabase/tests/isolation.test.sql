-- ============================================================================
-- TEST DE AISLAMIENTO ENTRE COMERCIOS
--
-- Este es el test más importante del proyecto. Si falla, un comercio puede ver
-- las ventas de otro y el producto no se puede vender.
--
-- Se corre después de `supabase db reset` (que aplica migraciones + seed):
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/isolation.test.sql
--
-- Todo corre dentro de una transacción que termina en ROLLBACK: no ensucia la
-- base. Cualquier `assert` que falle aborta con ON_ERROR_STOP.
--
-- Correrlo en CADA cambio de policy, sin excepción.
-- ============================================================================

begin;

\set NORTE   '11111111-1111-1111-1111-111111111111'
\set SUR     '22222222-2222-2222-2222-222222222222'
\set U_ADMIN 'aaaaaaaa-0000-0000-0000-000000000001'
\set U_NORTE 'aaaaaaaa-0000-0000-0000-000000000002'
\set U_SUR   'aaaaaaaa-0000-0000-0000-000000000003'
\set U_ENCARGADO 'aaaaaaaa-0000-0000-0000-000000000004'

-- ---------------------------------------------------------------------------
-- 0. Estructural: ninguna tabla con tenant_id puede quedar sin RLS
-- ---------------------------------------------------------------------------
-- Se verifica sobre el catálogo, no sobre una lista escrita a mano: así una
-- tabla nueva que alguien agregue mañana sin policy hace fallar el test hoy.
do $$
declare
  sin_rls text;
begin
  select string_agg(c.relname, ', ')
    into sin_rls
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and a.attnum > 0
  where n.nspname = 'public'
    and c.relkind = 'r'
    and not c.relrowsecurity;

  assert sin_rls is null,
    'Hay tablas con tenant_id y SIN row level security: ' || coalesce(sin_rls, '');
end $$;

-- ---------------------------------------------------------------------------
-- 1. El dueño de Norte no ve NADA de Sur, en ninguna tabla
-- ---------------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"aaaaaaaa-0000-0000-0000-000000000002","role":"authenticated"}';

do $$
declare
  t     record;
  fugas integer;
begin
  -- Recorre TODAS las tablas con tenant_id. No es una lista fija a propósito.
  for t in
    select c.relname as table_name
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and a.attnum > 0
    where n.nspname = 'public' and c.relkind = 'r'
    order by 1
  loop
    execute format(
      'select count(*) from public.%I where tenant_id <> %L',
      t.table_name, '11111111-1111-1111-1111-111111111111'
    ) into fugas;

    assert fugas = 0,
      format('FUGA DE DATOS en %s: el dueño de Norte ve %s filas de otro comercio',
             t.table_name, fugas);
  end loop;
end $$;

-- Contraprueba: que vea LO SUYO. Sin esto, una policy rota que no devuelve nada
-- pasaría el test de arriba con honores.
do $$
declare n integer;
begin
  select count(*) into n from sales_daily;
  assert n > 700, format('El dueño de Norte debería ver sus ~801 días de ventas, ve %s', n);

  select count(*) into n from products;
  assert n = 6, format('El dueño de Norte debería ver sus 6 productos, ve %s', n);

  select count(*) into n from tenants;
  assert n = 1, format('El dueño de Norte debería ver 1 comercio (el suyo), ve %s', n);

  select count(*) into n from checks;
  assert n = 5, format('El dueño de Norte debería ver sus 5 cheques, ve %s', n);
end $$;

-- Las claves de agente son invisibles incluso para el dueño del comercio.
do $$
declare n integer;
begin
  select count(*) into n from agent_keys;
  assert n = 0, format('agent_keys debe ser invisible desde el cliente, se ven %s filas', n);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Escritura: el cliente no puede tocar las tablas de hechos
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    insert into sales_daily (tenant_id, business_date, net_amount)
    values ('11111111-1111-1111-1111-111111111111', current_date - 900, 99999);
    assert false, 'Un usuario autenticado NO debería poder insertar ventas';
  exception
    when insufficient_privilege then null;  -- esperado
  end;
end $$;

do $$
begin
  begin
    update products set sale_price = 1 where sku = 'CAF001';
    assert false, 'Un usuario autenticado NO debería poder modificar productos';
  exception
    when insufficient_privilege then null;  -- esperado
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Metas: es la única tabla que el dueño escribe, y sólo la propia
-- ---------------------------------------------------------------------------
do $$
declare tocadas integer;
begin
  -- Intento de pisar la meta de OTRO comercio: la policy no ve esa fila,
  -- así que el UPDATE no afecta ninguna.
  update sales_targets set target_amount = 1
   where tenant_id = '22222222-2222-2222-2222-222222222222';
  get diagnostics tocadas = row_count;
  assert tocadas = 0,
    format('FUGA: el dueño de Norte modificó %s metas de Sur', tocadas);

  -- La propia sí.
  update sales_targets set target_amount = 6000
   where tenant_id = '11111111-1111-1111-1111-111111111111'
     and period_type = 'month';
  get diagnostics tocadas = row_count;
  assert tocadas = 1, format('El dueño debería poder editar su meta, tocó %s filas', tocadas);
end $$;

-- Tampoco puede crear una meta a nombre de otro comercio (eso lo frena WITH CHECK).
do $$
begin
  begin
    insert into sales_targets (tenant_id, period_type, period_start, target_amount)
    values ('22222222-2222-2222-2222-222222222222', 'year',
            date_trunc('year', current_date)::date, 1);
    assert false, 'FUGA: se pudo crear una meta a nombre de otro comercio';
  exception
    when insufficient_privilege then null;  -- esperado: lo rechaza WITH CHECK
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Funciones de KPI: tampoco filtran
-- ---------------------------------------------------------------------------
do $$
declare
  hoy_norte numeric;
  pct       numeric;
begin
  select current_amount, delta_pct into hoy_norte, pct
  from sales_comparison(current_date) where period = 'day';

  -- El seed le da 150 a Norte hoy y 100 ayer.
  assert hoy_norte = 150, format('Norte debería ver 150 de venta hoy, ve %s', hoy_norte);
  assert pct = 50, format('El crecimiento diario debería ser 50%%, es %s', pct);
end $$;

-- El recorte al mismo día relativo: el período anterior NO es el mes completo.
do $$
declare r record;
begin
  select * into r from sales_comparison(current_date) where period = 'month';

  assert r.previous_to = (current_date - interval '1 month')::date,
    format('El mes anterior debe cortarse en el mismo día relativo (%s), corta en %s',
           (current_date - interval '1 month')::date, r.previous_to);

  -- Como todos los días valen 100 salvo hoy que vale 150, la diferencia mensual
  -- tiene que ser exactamente 50. Si comparara contra el mes anterior COMPLETO,
  -- este número sería un derrumbe enorme y falso.
  assert r.delta_amount = 50,
    format('La diferencia mensual debería ser exactamente 50, es %s', r.delta_amount);
end $$;

-- Márgenes: los números del seed son exactos y verificables a mano.
do $$
declare r record;
begin
  select * into r
  from product_margins(current_date - 29, current_date, 'margin_pct_desc', 50)
  where sku = 'CAF001';

  -- 30 días × (1000 de venta − 600 de costo) = 12000 de margen sobre 30000 = 40%
  assert r.revenue = 30000,       format('CAF001 debería facturar 30000, facturó %s', r.revenue);
  assert r.margin_amount = 12000, format('CAF001 debería dejar 12000, dejó %s', r.margin_amount);
  assert r.margin_pct = 40,       format('CAF001 debería tener 40%% de margen, tiene %s', r.margin_pct);
  assert r.cost_estimated = false, 'CAF001 tiene costo real, no estimado';

  -- YER001 tiene costo aproximado: el margen se ve perfecto (100%) justamente
  -- porque el costo no es confiable. La bandera existe para que la UI lo avise.
  select * into r
  from product_margins(current_date - 29, current_date, 'margin_pct_desc', 50)
  where sku = 'YER001';
  assert r.cost_estimated = true, 'YER001 debería venir marcado como costo estimado';
end $$;

-- Baja rotación: plata inmovilizada, no simplemente "producto sin ventas".
do $$
declare
  skus text;
begin
  select string_agg(sku, ',' order by sku) into skus from low_rotation(60, 50);

  assert skus like '%LIC001%', 'LIC001 tiene stock y nunca se vendió: debería figurar';
  assert skus like '%VEL001%', 'VEL001 no se vende hace 200 días: debería figurar';
  assert skus not like '%CAF001%', 'CAF001 se vende todos los días: NO debería figurar';
  assert skus not like '%AGO001%',
    'AGO001 no tiene stock: no hay plata inmovilizada, NO debería figurar';
end $$;

-- ---------------------------------------------------------------------------
-- 5. El encargado ve las ventas pero NO los módulos financieros
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"aaaaaaaa-0000-0000-0000-000000000004","role":"authenticated"}';

do $$
declare n integer;
begin
  select count(*) into n from sales_daily;
  assert n > 700, format('El encargado debería ver las ventas del local, ve %s', n);

  select count(*) into n from products;
  assert n = 6, format('El encargado debería ver los productos, ve %s', n);

  select count(*) into n from account_balances;
  assert n = 0, format('El encargado NO debería ver cuentas corrientes, ve %s', n);

  select count(*) into n from checks;
  assert n = 0, format('El encargado NO debería ver cheques, ve %s', n);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Simétrico: el dueño de Sur tampoco ve nada de Norte
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"aaaaaaaa-0000-0000-0000-000000000003","role":"authenticated"}';

do $$
declare
  t     record;
  fugas integer;
  hoy   numeric;
begin
  for t in
    select c.relname as table_name
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attname = 'tenant_id' and a.attnum > 0
    where n.nspname = 'public' and c.relkind = 'r'
    order by 1
  loop
    execute format(
      'select count(*) from public.%I where tenant_id <> %L',
      t.table_name, '22222222-2222-2222-2222-222222222222'
    ) into fugas;

    assert fugas = 0,
      format('FUGA DE DATOS en %s: el dueño de Sur ve %s filas de otro comercio',
             t.table_name, fugas);
  end loop;

  -- Sur vende 100 hoy, no 150: confirma que la función leyó SU tenant.
  select current_amount into hoy from sales_comparison(current_date) where period = 'day';
  assert hoy = 100, format('Sur debería ver 100 de venta hoy, ve %s', hoy);
end $$;

-- ---------------------------------------------------------------------------
-- 7. El super_admin sí ve todo
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
set local "request.jwt.claims" = '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}';

do $$
declare n integer;
begin
  select count(distinct tenant_id) into n from sales_daily;
  assert n = 2, format('El super_admin debería ver los 2 comercios, ve %s', n);

  select count(*) into n from tenants;
  assert n = 2, format('El super_admin debería ver los 2 tenants, ve %s', n);

  -- Necesita ver qué agentes dejaron de reportar, en todos los comercios.
  select count(*) into n from sync_runs where status = 'error';
  assert n = 1, format('El super_admin debería ver el sync fallido de Sur, ve %s', n);
end $$;

-- ---------------------------------------------------------------------------
-- 8. Sin sesión no se ve nada
-- ---------------------------------------------------------------------------
reset role;
set local role anon;

do $$
declare n integer;
begin
  begin
    select count(*) into n from sales_daily;
    assert n = 0, format('Un anónimo NO debería ver ventas, ve %s', n);
  exception
    when insufficient_privilege then null;  -- también es válido: sin grant
  end;
end $$;

reset role;

rollback;

\echo ''
\echo '  Aislamiento entre comercios: TODOS LOS CHEQUEOS PASARON'
\echo ''
