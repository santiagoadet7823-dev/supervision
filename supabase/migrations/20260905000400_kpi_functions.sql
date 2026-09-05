-- ============================================================================
-- 004 — Funciones de KPI
--
-- Toda función es SECURITY INVOKER (el default, explicitado a propósito): corre
-- con los permisos de quien la llama, así que la RLS sigue aplicando adentro. Es
-- imposible que una de estas funciones devuelva datos de otro comercio.
--
-- Nunca reciben `tenant_id` como parámetro. Ese es el punto.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Comparativa de ventas: día / semana / mes / año contra el período anterior
-- ---------------------------------------------------------------------------
-- Decisión clave: el período anterior se corta al MISMO DÍA RELATIVO. El mes
-- actual va hasta hoy y se compara contra el mes anterior hasta el mismo día,
-- no contra el mes anterior completo. Comparar 5 días contra 30 mostraría una
-- caída del 80% que no existe.
create or replace function sales_comparison(p_reference date default current_date)
returns table (
  period          text,
  current_from    date,
  current_to      date,
  previous_from   date,
  previous_to     date,
  current_amount  numeric,
  previous_amount numeric,
  delta_amount    numeric,
  delta_pct       numeric,
  current_tickets integer,
  current_units   numeric
)
language sql
stable
security invoker
set search_path = public
as $$
  with periods as (
    select 'day'::text as period,
           p_reference as cur_from,
           p_reference as cur_to,
           (p_reference - 1) as prev_from,
           (p_reference - 1) as prev_to
    union all
    select 'week',
           date_trunc('week', p_reference)::date,
           p_reference,
           (date_trunc('week', p_reference)::date - 7),
           (p_reference - 7)
    union all
    select 'month',
           date_trunc('month', p_reference)::date,
           p_reference,
           (date_trunc('month', p_reference) - interval '1 month')::date,
           (p_reference - interval '1 month')::date
    union all
    select 'year',
           date_trunc('year', p_reference)::date,
           p_reference,
           (date_trunc('year', p_reference) - interval '1 year')::date,
           (p_reference - interval '1 year')::date
  )
  select
    p.period,
    p.cur_from,
    p.cur_to,
    p.prev_from,
    p.prev_to,
    coalesce(c.amount, 0)::numeric,
    coalesce(v.amount, 0)::numeric,
    (coalesce(c.amount, 0) - coalesce(v.amount, 0))::numeric,
    -- NULL, no infinito: si el período anterior fue 0 no hay porcentaje que
    -- calcular. La UI muestra un guión, no un "+∞%".
    case
      when coalesce(v.amount, 0) = 0 then null
      else round((coalesce(c.amount, 0) - v.amount) / v.amount * 100, 2)
    end,
    coalesce(c.tickets, 0)::integer,
    coalesce(c.units, 0)::numeric
  from periods p
  left join lateral (
    select sum(s.net_amount) as amount,
           sum(s.tickets)    as tickets,
           sum(s.units)      as units
    from sales_daily s
    where s.business_date between p.cur_from and p.cur_to
  ) c on true
  left join lateral (
    select sum(s.net_amount) as amount
    from sales_daily s
    where s.business_date between p.prev_from and p.prev_to
  ) v on true
  order by array_position(array['day', 'week', 'month', 'year'], p.period);
$$;

comment on function sales_comparison is
  'Ventas del día/semana/mes/año contra el período anterior recortado al mismo día relativo.';

-- ---------------------------------------------------------------------------
-- Márgenes por producto
-- ---------------------------------------------------------------------------
-- El margen se calcula sobre el PRECIO DE VENTA (margen / ingreso), que es la
-- convención comercial habitual. Sobre costo daría un número mayor y no
-- comparable con lo que el dueño tiene en la cabeza.
create or replace function product_margins(
  p_from  date,
  p_to    date,
  p_order text default 'margin_pct_desc',
  p_limit integer default 50
)
returns table (
  sku            text,
  description    text,
  category       text,
  qty            numeric,
  revenue        numeric,
  cost           numeric,
  margin_amount  numeric,
  margin_pct     numeric,
  cost_estimated boolean
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    d.sku,
    max(p.description) as description,
    max(p.category)    as category,
    sum(d.qty)                        as qty,
    sum(d.net_amount)                 as revenue,
    sum(d.cost_amount)                as cost,
    sum(d.net_amount - d.cost_amount) as margin_amount,
    case
      when sum(d.net_amount) = 0 then null
      else round(sum(d.net_amount - d.cost_amount) / sum(d.net_amount) * 100, 2)
    end as margin_pct,
    -- Si alguna venta del rango usó costo aproximado, el margen del producto
    -- también lo es. La UI lo marca en vez de fingir precisión.
    bool_or(d.cost_is_estimated) as cost_estimated
  from product_sales_daily d
  left join products p
    on p.tenant_id = d.tenant_id
   and p.sku = d.sku
  where d.business_date between p_from and p_to
  group by d.sku
  order by
    case when p_order = 'margin_pct_desc'
      then case when sum(d.net_amount) = 0 then null
           else sum(d.net_amount - d.cost_amount) / sum(d.net_amount) end end desc nulls last,
    case when p_order = 'margin_pct_asc'
      then case when sum(d.net_amount) = 0 then null
           else sum(d.net_amount - d.cost_amount) / sum(d.net_amount) end end asc nulls last,
    case when p_order = 'margin_amount_desc' then sum(d.net_amount - d.cost_amount) end desc nulls last,
    case when p_order = 'margin_amount_asc'  then sum(d.net_amount - d.cost_amount) end asc  nulls last,
    case when p_order = 'revenue_desc'       then sum(d.net_amount) end desc nulls last,
    case when p_order = 'qty_desc'           then sum(d.qty) end desc nulls last
  -- Tope duro: un p_limit enorme desde el cliente no puede convertirse en un
  -- volcado de toda la tabla.
  limit least(coalesce(p_limit, 50), 500);
$$;

-- ---------------------------------------------------------------------------
-- Baja rotación: productos con stock que no se vendieron en N días
-- ---------------------------------------------------------------------------
create or replace function low_rotation(
  p_days  integer default 60,
  p_limit integer default 50
)
returns table (
  sku            text,
  description    text,
  category       text,
  stock_qty      numeric,
  cost_price     numeric,
  stock_value    numeric,
  last_sold_date date,
  days_idle      integer
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    p.sku,
    p.description,
    p.category,
    p.stock_qty,
    p.cost_price,
    -- Lo que realmente le duele al dueño no es el producto parado: es la plata
    -- inmovilizada. Por eso se ordena por valor de stock, no por cantidad.
    round(coalesce(p.stock_qty, 0) * coalesce(p.cost_price, 0), 2) as stock_value,
    last_sale.sold_on,
    case
      when last_sale.sold_on is null then null
      else (current_date - last_sale.sold_on)
    end as days_idle
  from products p
  left join lateral (
    -- Última venta de TODA la historia, no sólo de la ventana: así podemos
    -- decir "no se vende hace 200 días" en vez de un `null` sin información.
    select max(d.business_date) as sold_on
    from product_sales_daily d
    where d.tenant_id = p.tenant_id
      and d.sku = p.sku
  ) last_sale on true
  where coalesce(p.stock_qty, 0) > 0   -- sin stock no hay plata inmovilizada
    and (
      last_sale.sold_on is null                       -- nunca se vendió
      or last_sale.sold_on < current_date - p_days    -- no se vende hace rato
    )
  order by stock_value desc
  limit least(coalesce(p_limit, 50), 500);
$$;

-- ---------------------------------------------------------------------------
-- Días pico: qué días de la semana venden más
-- ---------------------------------------------------------------------------
create or replace function peak_weekdays(p_from date, p_to date)
returns table (
  weekday      smallint,   -- 0 = domingo
  weekday_name text,
  total_amount numeric,
  avg_amount   numeric,
  total_tickets integer,
  days_counted integer
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    extract(dow from s.business_date)::smallint as weekday,
    -- Nombre fijo en castellano. `to_char(..., 'TMDay')` dependería del locale
    -- del servidor, que en Supabase es inglés: el dashboard mostraría "Monday".
    (array['Domingo','Lunes','Martes','Miércoles','Jueves','Viernes','Sábado']
      )[extract(dow from s.business_date)::int + 1] as weekday_name,
    sum(s.net_amount)                           as total_amount,
    -- El promedio es lo comparable: un mes puede tener 5 sábados y 4 domingos,
    -- y el total solo haría ganar siempre al día que aparece más veces.
    round(avg(s.net_amount), 2)                 as avg_amount,
    sum(s.tickets)::integer                     as total_tickets,
    count(*)::integer                           as days_counted
  from sales_daily s
  where s.business_date between p_from and p_to
  group by 1, 2
  order by avg_amount desc;
$$;

-- ---------------------------------------------------------------------------
-- Horarios pico
-- ---------------------------------------------------------------------------
create or replace function peak_hours(p_from date, p_to date)
returns table (
  hour_of_day   smallint,
  total_amount  numeric,
  avg_amount    numeric,
  total_tickets integer
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    h.hour_of_day,
    sum(h.net_amount)           as total_amount,
    round(avg(h.net_amount), 2) as avg_amount,
    sum(h.tickets)::integer     as total_tickets
  from sales_hourly h
  where h.business_date between p_from and p_to
  group by h.hour_of_day
  order by h.hour_of_day;
$$;

-- ---------------------------------------------------------------------------
-- Avance sobre la meta del mes y del año
-- ---------------------------------------------------------------------------
create or replace function target_progress(p_reference date default current_date)
returns table (
  period_type    text,
  period_start   date,
  period_end     date,
  target_amount  numeric,
  actual_amount  numeric,
  progress_pct   numeric,
  -- Proyección lineal al cierre del período según el ritmo actual. Es una
  -- estimación, no una promesa: la UI debe presentarla como tal.
  projected_amount numeric,
  days_elapsed   integer,
  days_total     integer
)
language sql
stable
security invoker
set search_path = public
as $$
  with periods as (
    select 'month'::text as period_type,
           date_trunc('month', p_reference)::date as period_start,
           (date_trunc('month', p_reference) + interval '1 month' - interval '1 day')::date as period_end
    union all
    select 'year',
           date_trunc('year', p_reference)::date,
           (date_trunc('year', p_reference) + interval '1 year' - interval '1 day')::date
  )
  select
    p.period_type,
    p.period_start,
    p.period_end,
    t.target_amount,
    coalesce(a.amount, 0)::numeric as actual_amount,
    case
      when t.target_amount is null or t.target_amount = 0 then null
      else round(coalesce(a.amount, 0) / t.target_amount * 100, 2)
    end as progress_pct,
    case
      when (p_reference - p.period_start + 1) = 0 then null
      else round(
        coalesce(a.amount, 0)
          / (p_reference - p.period_start + 1)
          * (p.period_end - p.period_start + 1),
        2)
    end as projected_amount,
    (p_reference - p.period_start + 1)::integer as days_elapsed,
    (p.period_end - p.period_start + 1)::integer as days_total
  from periods p
  left join sales_targets t
    on t.period_type = p.period_type
   and t.period_start = p.period_start
  left join lateral (
    select sum(s.net_amount) as amount
    from sales_daily s
    where s.business_date between p.period_start and least(p_reference, p.period_end)
  ) a on true;
$$;

-- ---------------------------------------------------------------------------
-- Resumen de cheques por estado
-- ---------------------------------------------------------------------------
create or replace function checks_summary()
returns table (
  status       check_status,
  is_own       boolean,
  quantity     integer,
  total_amount numeric,
  next_due     date
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    c.status,
    c.is_own,
    count(*)::integer as quantity,
    sum(c.amount)     as total_amount,
    min(c.due_date) filter (where c.due_date >= current_date) as next_due
  from checks c
  group by c.status, c.is_own
  order by c.is_own, c.status;
$$;

-- ---------------------------------------------------------------------------
-- Resumen de cuentas corrientes con antigüedad
-- ---------------------------------------------------------------------------
create or replace function accounts_summary()
returns table (
  kind          party_kind,
  parties       integer,
  total_balance numeric,
  due_0_30      numeric,
  due_31_60     numeric,
  due_61_90     numeric,
  due_90_plus   numeric
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    a.kind,
    count(*)::integer   as parties,
    sum(a.balance)      as total_balance,
    sum(a.due_0_30)     as due_0_30,
    sum(a.due_31_60)    as due_31_60,
    sum(a.due_61_90)    as due_61_90,
    sum(a.due_90_plus)  as due_90_plus
  from account_balances a
  where a.balance <> 0
  group by a.kind;
$$;

-- ---------------------------------------------------------------------------
-- Permisos
-- ---------------------------------------------------------------------------
grant execute on function sales_comparison(date)                       to authenticated;
grant execute on function product_margins(date, date, text, integer)   to authenticated;
grant execute on function low_rotation(integer, integer)               to authenticated;
grant execute on function peak_weekdays(date, date)                    to authenticated;
grant execute on function peak_hours(date, date)                       to authenticated;
grant execute on function target_progress(date)                        to authenticated;
grant execute on function checks_summary()                             to authenticated;
grant execute on function accounts_summary()                           to authenticated;
