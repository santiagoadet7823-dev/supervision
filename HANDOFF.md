# HANDOFF

> Estado vivo del proyecto. **Se actualiza al final de cada sesión de trabajo.**
> Si retomás el proyecto después de un tiempo, leé este archivo primero.

**Última actualización:** 2026-09-05

---

## Dónde estamos

Repositorio recién inicializado. Existe la estructura completa de carpetas y la
documentación base. **No hay código funcional todavía.**

El plan de arquitectura está aprobado y guardado en
[`PLANES/2026-09-05-arquitectura-inicial.md`](PLANES/2026-09-05-arquitectura-inicial.md).

## Qué está terminado

- Estructura del monorepo (`agent/`, `supabase/`, `app/`, docs)
- `CLAUDE.md` con las convenciones no negociables del proyecto
- `README.md`, `ROADMAP.md`, este `HANDOFF.md`
- `PLANES/` y `LINKS-IMPORTANTES/` con sus índices
- `.gitignore`

## Qué está a medias

Nada. La Fase 0 (scaffolding) cerró completa.

## Próximo paso concreto

**Escribir `agent/tools/inspect-dbf.js`** y correrlo contra una instalación real del ERP.

Sin conocer los nombres reales de tablas y campos no se puede escribir ni el extractor ni
las migraciones definitivas. El script debe emitir, por cada `.dbf` de la carpeta de datos:
nombre de tabla, cantidad de registros, definición de campos (nombre, tipo, largo,
decimales) y 3 filas de muestra, todo a un JSON revisable sin abrir el ERP.

Con esa salida se construye `agent/src/config/mapping.yaml`.

## Decisiones tomadas y por qué

| Decisión | Razón |
|---|---|
| **Flutter**, no Capacitor | Intentos previos con Capacitor daban una experiencia de "PWA rota". Flutter genera PWA y APK del mismo código. |
| Agente en **Node.js** | Mismo lenguaje que el resto del stack; lee DBF parseando el archivo, sin depender del driver VFPOLEDB de 32 bits. |
| **Push incremental de agregados**, no replicación cruda | Menos tráfico y menos costo; el comercio no necesita IP fija ni puertos abiertos. |
| KPIs en **funciones SQL `SECURITY INVOKER`** | La RLS del usuario sigue aplicando dentro de la función: es imposible que una función filtre datos de otro tenant. |
| Agregados con **PK natural + UPSERT** | Reenviar un lote tras una caída de red nunca duplica datos. |
| Margen sobre **precio de venta** | Convención comercial habitual (`margen / ingreso`), documentado para evitar ambigüedad. |

## Problemas conocidos y riesgos

1. **Acceso a Supabase limitado.** No ejecutar migraciones contra el proyecto en la nube
   por ahora. Todo el desarrollo del esquema va contra Postgres local (`supabase start`).
2. **Esquema del ERP desconocido.** Es el bloqueante principal. Todo el diseño del agente
   asume un mapeo que todavía no está validado contra datos reales.
3. **Costo histórico incierto.** Si el detalle de venta del ERP no guarda el costo unitario
   del momento, los márgenes históricos serán aproximados con el costo actual. Hay que
   verificarlo en la Fase 1 y documentarlo en la UI si aplica.
4. **Visibilidad del repo sin resolver.** Afecta cómo se despliega la PWA y cómo se
   descargan los APK. Ver "Decisiones pendientes" en `ROADMAP.md`.
5. **Zona horaria.** El ERP guarda fechas locales sin zona. `tenants.timezone` existe para
   que los cortes diarios coincidan con el día comercial del comercio, no con UTC.
