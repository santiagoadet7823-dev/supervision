# HANDOFF

> Estado vivo del proyecto. **Se actualiza al final de cada sesión de trabajo.**
> Si retomás el proyecto después de un tiempo, leé este archivo primero.

**Última actualización:** 2026-09-05

---

## Dónde estamos

Repositorio inicializado con la estructura completa y la documentación base. El **lector de
DBF y la herramienta de relevamiento del ERP están terminados y testeados** — pero todavía
no se corrieron contra una instalación real.

El plan de arquitectura aprobado está en
[`PLANES/2026-09-05-arquitectura-inicial.md`](PLANES/2026-09-05-arquitectura-inicial.md).

## Qué está terminado

**Fase 0 — Scaffolding** (completa)
- Estructura del monorepo (`agent/`, `supabase/`, `app/`, docs)
- `CLAUDE.md` con las convenciones no negociables
- `README.md`, `ROADMAP.md`, este `HANDOFF.md`, `PLANES/`, `LINKS-IMPORTANTES/`, `.gitignore`

**Fase 1 — Relevamiento** (parcial)
- `agent/src/dbf/codepages.js` — decodificación cp850 / cp437 / cp1252 (Node no las trae)
- `agent/src/dbf/reader.js` — lector de DBF sin dependencias: header, descriptores de campo,
  tipos C/N/F/D/L/I/B/Y/T/M/V, memos `.fpt`, registros borrados, iteración perezosa
- `agent/tools/inspect-dbf.js` — relevamiento a JSON: tablas, campos, estadística por campo
  (nulos, distintos, min/max) y filas de muestra, con modo `--anonymize`
- `agent/test/` — 15 tests, todos en verde. Incluyen el caso crítico "leer no modifica el
  archivo" y el de header desactualizado por corte de luz.

Verificado end-to-end contra un ERP sintético (3 tablas, 2090 registros): el reporte
identifica correctamente la tabla de movimiento y el rango de fechas.

## Qué está a medias

**Fase 1** — falta lo que depende de datos reales:
- Correr `inspect-dbf.js` en una instalación del ERP
- Escribir `agent/src/config/mapping.yaml` con la salida

## Próximo paso concreto

**Correr el relevamiento en el servidor de un comercio real:**

```bash
# copiar la carpeta agent/ al servidor del ERP (no hace falta npm install)
node tools/inspect-dbf.js --dir "C:/ruta/al/ERP/DATOS" --recursive
```

Si el relevamiento va a salir del comercio, usar `--anonymize` para no mover datos de
clientes.

Con ese JSON en mano hay que responder tres preguntas antes de seguir:

1. ¿Cómo se llaman la cabecera y el detalle de ventas, y cómo se relacionan?
2. ¿El detalle de venta guarda el **costo unitario del momento**, o hay que aproximarlo con
   el costo actual del maestro? (define si los márgenes históricos son exactos)
3. ¿La fecha de venta viene con hora, o la hora está en un campo aparte? (define si podemos
   hacer el análisis de rangos horarios pico)

Después de eso, `mapping.yaml` y arranca la Fase 2 (esquema SQL + RLS).

## Decisiones tomadas y por qué

| Decisión | Razón |
|---|---|
| **Flutter**, no Capacitor | Intentos previos con Capacitor daban una experiencia de "PWA rota". Flutter genera PWA y APK del mismo código. |
| Agente en **Node.js** | Mismo lenguaje que el resto del stack; lee DBF parseando el archivo, sin depender del driver VFPOLEDB de 32 bits. |
| **Lector de DBF propio**, sin librería | La herramienta de relevamiento tiene que correr en el servidor del comercio, donde no hay `npm install` ni internet garantizado. Además necesitábamos control fino sobre páginas de código y fechas. |
| **Fechas como string `'AAAA-MM-DD'`** | Un `Date` de JS aplica zona horaria y puede correr el día comercial, que es el eje de toda la agregación. |
| **Push incremental de agregados**, no replicación cruda | Menos tráfico y menos costo; el comercio no necesita IP fija ni puertos abiertos. |
| KPIs en **funciones SQL `SECURITY INVOKER`** | La RLS del usuario sigue aplicando dentro de la función: es imposible que filtre datos de otro tenant. |
| Agregados con **PK natural + UPSERT** | Reenviar un lote tras una caída de red nunca duplica datos. |
| Margen sobre **precio de venta** | Convención comercial habitual (`margen / ingreso`), documentado para evitar ambigüedad. |

## Problemas conocidos y riesgos

1. **Esquema del ERP desconocido.** Es el bloqueante principal. El lector funciona, pero
   nada del extractor puede escribirse hasta tener el `mapping.yaml`.
2. **Acceso a Supabase limitado.** No ejecutar migraciones contra el proyecto en la nube por
   ahora. El esquema se desarrolla contra Postgres local (`supabase start`).
3. **Costo histórico incierto.** Si el detalle de venta no guarda el costo del momento, los
   márgenes históricos serán aproximados con el costo actual. Verificar en la Fase 1 y, si
   aplica, avisarlo en la UI en vez de mostrar un número que parece exacto.
4. **Memos `.dbt` (dBASE III) no soportados.** Sólo `.fpt` de FoxPro. Si el ERP usa `.dbt`,
   hay que agregar ese formato al lector.
5. **Visibilidad del repo sin resolver.** Afecta cómo se despliega la PWA y cómo se
   descargan los APK. Ver "Decisiones pendientes" en `ROADMAP.md`.
6. **Zona horaria.** El ERP guarda fechas locales sin zona. `tenants.timezone` existe para
   que los cortes diarios coincidan con el día comercial, no con UTC.
