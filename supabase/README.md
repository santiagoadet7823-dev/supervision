# Backend (Supabase / PostgreSQL)

Esquema, políticas de aislamiento y funciones de KPI de la plataforma.

> **Estado: sin ejecutar.** La sintaxis de todo el SQL está validada con el parser real
> de PostgreSQL (incluidos los cuerpos de las funciones), pero **todavía no corrió contra
> una base**: en la máquina de desarrollo no hay Docker ni Postgres, y el proyecto de
> Supabase en la nube está limitado. Antes de darlo por bueno hay que hacer
> `supabase db reset` y correr el test de aislamiento.

## Estructura

```
migrations/
  20260905000100_core_multitenant.sql   tenants, profiles, agent_keys
  20260905000200_facts.sql              tablas de hechos que sincroniza el agente
  20260905000300_rls.sql                policies de aislamiento  <-- lo crítico
  20260905000400_kpi_functions.sql      funciones de KPI
seed.sql                                dos comercios con datos verificables a mano
tests/
  isolation.test.sql                    el test que no se puede saltear
functions/
  ingest/                               (pendiente) recibe los lotes del agente
  kpis/                                 (pendiente) compone el dashboard
```

## Puesta en marcha local

```bash
supabase start          # levanta Postgres, Auth y Studio en Docker
supabase db reset       # aplica migraciones + seed
supabase status         # muestra DB URL, anon key y URL de Studio
```

Correr después el test de aislamiento:

```bash
psql "$(supabase status --output json | jq -r .DB_URL)" -v ON_ERROR_STOP=1 -f supabase/tests/isolation.test.sql
```

Usuarios del seed (contraseña `password123` en todos):

| Email | Rol | Ve |
|---|---|---|
| `admin@supervision.test` | super_admin | Los dos comercios |
| `norte@supervision.test` | owner | Almacén Norte, todo |
| `encargado.norte@supervision.test` | manager | Almacén Norte, **sin** finanzas |
| `sur@supervision.test` | owner | Kiosco Sur, todo |

## El modelo de seguridad en tres reglas

**1. El `tenant_id` nunca viene del cliente.**
Se deriva de `auth.uid()` a través de `auth_tenant_id()`. Ninguna función de KPI recibe un
`tenant_id` como parámetro — ese es justamente el punto. Aunque alguien llame la API a mano
con el id de otro comercio, la RLS no le devuelve esas filas.

**2. El cliente sólo lee.**
`revoke all ... from authenticated` y después `grant select` en las tablas de datos. La
única excepción es `sales_targets`, que el dueño edita desde la app. Toda escritura de datos
sincronizados entra por la Edge Function de ingesta con `service_role`.

**3. Las funciones de KPI son `SECURITY INVOKER`.**
Corren con los permisos de quien las llama, así que la RLS sigue aplicando adentro. Una
función `SECURITY DEFINER` acá sería una puerta trasera: saltearía el aislamiento sin que se
note.

Las dos únicas funciones `SECURITY DEFINER` del esquema son `auth_tenant_id()`,
`is_super_admin()` y `can_see_financials()`. Lo son a propósito: leen `profiles` salteando la
RLS de esa tabla, porque si no la policy de `profiles` se llamaría a sí misma en recursión
infinita. Sólo leen el perfil del usuario actual y no aceptan parámetros.

`agent_keys` tiene RLS activa y **cero policies**: es invisible desde el cliente, incluso
para el dueño del comercio.

## El test de aislamiento

`tests/isolation.test.sql` no enumera las tablas a mano: las descubre del catálogo. Toda
tabla con una columna `tenant_id` entra al chequeo automáticamente, así que **una tabla nueva
sin RLS hace fallar el test el día que se crea**, no meses después.

Cubre:

- Ninguna tabla con `tenant_id` puede quedar sin RLS (chequeo estructural)
- El dueño de Norte no ve ni una fila de Sur, en ninguna tabla — y viceversa
- Contraprueba: sí ve lo suyo (una policy que no devuelve nada pasaría el test anterior)
- `agent_keys` invisible
- El cliente no puede insertar ventas ni modificar productos
- El dueño no puede editar ni crear metas de otro comercio
- El encargado ve ventas y productos pero **no** cuentas corrientes ni cheques
- Las funciones de KPI tampoco filtran, y devuelven los números exactos del seed
- El super_admin sí ve los dos comercios
- Un anónimo no ve nada

**Correrlo en cada cambio de policy, sin excepción.**

## Por qué el seed tiene los números que tiene

Todos los días venden 100, salvo hoy que Almacén Norte vende 150. Con eso la comparativa
diaria tiene que dar exactamente +50 (+50%).

Lo importante es que la diferencia de **semana, mes y año también tiene que dar +50**. Si
alguien rompiera el recorte al mismo día relativo y comparara contra el mes anterior
completo, el número sería un derrumbe enorme y falso — y el test lo detecta.

Los márgenes son igual de verificables: CAF001 factura 1000 y cuesta 600 por día durante 30
días, o sea 30000 de facturación, 12000 de margen y 40% exacto.

## Convenciones

- Una migración por tema, con timestamp. **Nunca** editar una migración ya aplicada: se
  agrega una nueva.
- Toda tabla nueva con `tenant_id` necesita `enable row level security` + policy en la misma
  migración. No es un pendiente, es parte de crear la tabla.
- Los importes son `numeric`, nunca `float`. Los costos unitarios llevan 4 decimales porque
  redondear ahí desvía los márgenes al multiplicar por cantidades grandes.
- Las fechas de negocio son `date` en la zona del comercio (`tenants.timezone`), no
  `timestamptz` en UTC.
