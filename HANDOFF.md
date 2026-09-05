# HANDOFF

> Estado vivo del proyecto. **Se actualiza al final de cada sesión de trabajo.**
> Si retomás el proyecto después de un tiempo, leé este archivo primero.

**Última actualización:** 2026-09-05
**Repositorio:** https://github.com/santiagoadet7823-dev/supervision (público por ahora)

---

## Dónde estamos

Repo publicado con tres commits. Están el **lector de DBF con su herramienta de
relevamiento** (testeado, verde) y **todo el esquema de base de datos con la RLS y las
funciones de KPI** (escrito y validado sintácticamente, **nunca ejecutado**).

Plan de arquitectura aprobado en
[`PLANES/2026-09-05-arquitectura-inicial.md`](PLANES/2026-09-05-arquitectura-inicial.md).

## Qué está terminado

**Fase 0 — Scaffolding** ✅
Estructura del monorepo, `CLAUDE.md` con las convenciones, `README.md`, `ROADMAP.md`, este
archivo, `PLANES/`, `LINKS-IMPORTANTES/`, `.gitignore`, repo público en GitHub.

**Fase 1 — Relevamiento** (parcial)
- `agent/src/dbf/codepages.js` — cp850 / cp437 / cp1252, que Node no trae
- `agent/src/dbf/reader.js` — lector de DBF sin dependencias: header, tipos
  C/N/F/D/L/I/B/Y/T/M/V, memos `.fpt`, borrados, iteración perezosa
- `agent/tools/inspect-dbf.js` — relevamiento a JSON con estadística por campo y muestras,
  con `--anonymize`
- `agent/src/config/mapping.example.yaml` — plantilla documentada del mapeo
- **15 tests, todos verdes.** Incluyen "leer no modifica el archivo" y header desactualizado.
  Verificado end-to-end contra un ERP sintético de 3 tablas y 2090 registros.

**Fase 2 — Esquema y RLS** (escrito, sin ejecutar)
- 4 migraciones: núcleo multi-tenant, tablas de hechos, RLS, funciones de KPI
- `seed.sql` con dos comercios y números verificables a mano
- `tests/isolation.test.sql` — descubre las tablas del catálogo de Postgres, así que una
  tabla nueva sin RLS lo hace fallar el día que se crea
- Sintaxis validada con el parser real de PostgreSQL, cuerpos de función incluidos

## Qué está a medias

**Nada de la Fase 2 corrió todavía.** El SQL está escrito y parsea, pero eso sólo descarta
errores de sintaxis. Errores semánticos — un nombre de columna mal escrito, un tipo que no
casa, una policy que no filtra lo que creemos — **siguen siendo posibles y no están
descartados**.

**Fase 1** — falta lo que depende de datos reales: correr el relevamiento y escribir el
`mapping.yaml` definitivo.

## Próximo paso concreto

**Ejecutar el esquema.** Es lo que convierte la Fase 2 de "escrita" a "hecha":

```bash
supabase start
supabase db reset
psql "$(supabase status --output json | jq -r .DB_URL)" -v ON_ERROR_STOP=1 -f supabase/tests/isolation.test.sql
```

Hace falta Docker + Supabase CLI, que **no están instalados en esta máquina** (tampoco hay
Postgres ni `psql`). Es el bloqueo. Alternativas: instalarlos, o levantar la restricción del
proyecto Supabase en la nube y correrlo contra una rama de preview.

Después de eso, en orden: Edge Function `/ingest` → extractores del agente → app Flutter.

## Decisiones tomadas y por qué

| Decisión | Razón |
|---|---|
| **Flutter**, no Capacitor | Intentos previos con Capacitor daban una "PWA rota". Flutter genera PWA y APK del mismo código. |
| **Repo público** por ahora | Simplifica GitHub Pages y las descargas de APK sin plan pago. Se pasa a privado en unos meses. Ningún secreto entra al repo; la `anon key` de Supabase es pública por diseño y lo que protege los datos es la RLS. |
| Agente en **Node.js** | Mismo lenguaje que el resto; lee DBF parseando el archivo, sin depender del driver VFPOLEDB de 32 bits. |
| **Lector de DBF propio**, sin librería | La herramienta de relevamiento corre en el servidor del comercio, sin `npm install` ni internet garantizado. Además hacía falta control fino sobre páginas de código y fechas. |
| **Fechas como string `'AAAA-MM-DD'`** | Un `Date` de JS aplica zona horaria y puede correr el día comercial, que es el eje de toda la agregación. |
| KPIs en funciones SQL **`SECURITY INVOKER`** | La RLS del usuario sigue aplicando adentro. Una `SECURITY DEFINER` acá sería una puerta trasera silenciosa. |
| El test de aislamiento **descubre las tablas del catálogo** | Una lista escrita a mano se desactualiza. Así, agregar una tabla sin RLS rompe el test de inmediato. |
| Agregados con **PK natural + UPSERT** | Reenviar un lote tras una caída de red nunca duplica datos. |
| Margen sobre **precio de venta** | Convención comercial habitual (`margen / ingreso`). |
| Columna **`cost_is_estimated`** | Si el ERP no guarda el costo del momento, el margen es aproximado y la UI lo tiene que avisar en vez de mostrar un número que parece exacto. |

## Problemas conocidos y riesgos

1. **El esquema nunca corrió.** Sintaxis validada ≠ funciona. Sin Docker/Postgres en esta
   máquina no se pudo ir más allá. Es el riesgo abierto más grande hoy.
2. **Esquema del ERP desconocido.** El `mapping.example.yaml` usa nombres inventados a partir
   de convenciones típicas; **ninguno está verificado**. Bloquea los extractores.
3. **Costo histórico incierto.** Si el detalle de venta no guarda el costo del momento, los
   márgenes históricos serán aproximados. Ya está previsto en el esquema
   (`cost_is_estimated`), falta confirmar contra el ERP real.
4. **Memos `.dbt` (dBASE III) no soportados.** Sólo `.fpt` de FoxPro.
5. **Notas de crédito.** Si el ERP las guarda en la misma tabla de ventas, hay que restarlas,
   no ignorarlas. Está anotado en el mapping pero sin resolver.
6. **Zona horaria.** El ERP guarda fechas locales sin zona. `tenants.timezone` existe para que
   los cortes diarios coincidan con el día comercial, no con UTC.
