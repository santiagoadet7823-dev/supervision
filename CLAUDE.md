# CLAUDE.md — Contexto del proyecto SUPERVISION

## Qué es esto

Plataforma de Business Intelligence **multi-tenant** que lee datos de un ERP legacy
**FoxPro (tablas DBF)** instalado localmente en los servidores de múltiples comercios
("subclientes"), los sincroniza a la nube y los muestra en una app (PWA + APK Android).

Cada subcliente ve **únicamente** sus propios datos. El aislamiento entre tenants es el
requisito de seguridad número uno del proyecto.

## Arquitectura en una línea

`ERP FoxPro (DBF)` → `Agente local Node.js (servicio Windows)` → `Supabase (Postgres + RLS)` → `Flutter (PWA + APK)`

**Principio rector: el agente agrega, la nube almacena y compara, el cliente sólo pinta.**
Los KPIs se precalculan. El dashboard nunca hace un scan sobre datos crudos.

## Stack y por qué

| Pieza | Elección | Razón |
|---|---|---|
| Nube | Supabase (Postgres + Auth + RLS) | RLS nativa resuelve el multi-tenancy con mucho menos código propio |
| Agente local | Node.js + `node-windows` | Un solo lenguaje en el stack; lee DBF como archivo, sin depender de drivers ODBC |
| Sync | Push incremental de agregados por HTTPS | Sólo tráfico saliente: sin puertos abiertos, sin IP fija, sin VPN en el comercio |
| Frontend | **Flutter** (web + Android) | Un código, PWA y APK. **Capacitor está descartado**: produjo "PWA rota" en intentos previos |
| Hosting PWA | GitHub Pages | Gratis, integrado al repo |
| Distribución APK | GitHub Releases + autoactualización propia | No se publica en Play Store |

## Convenciones no negociables

1. **RLS obligatoria en toda tabla nueva.** Crear una tabla sin `enable row level security`
   + policy de tenant es un bug de seguridad, no un pendiente.
2. **`tenant_id` jamás viene del cliente.** Se deriva siempre de `auth.uid()` vía
   `auth_tenant_id()`. En la ingesta, se deriva de la API key del agente, nunca del body.
3. **SQL sólo en `supabase/migrations/`**, numerado y versionado. Nada de cambios a mano
   en el dashboard de Supabase.
4. **`service_role` nunca en el bundle de Flutter.** El build web es público e inspeccionable.
5. **El agente nunca escribe en los DBF.** Lectura sólo, sobre una copia sombra. Si una
   operación puede tocar el `.cdx` o un memo, no va.
6. **Todo push al agente es idempotente.** PK natural + UPSERT: reenviar un lote nunca duplica.
7. **Todo planeamiento se escribe en `PLANES/`** como `YYYY-MM-DD-tema.md`. No se planifica
   en el chat y se pierde.
8. **`HANDOFF.md` se actualiza al terminar cada sesión de trabajo.**

## Comandos habituales

```bash
# Base de datos local (mientras el proyecto Supabase en la nube esté limitado)
supabase start
supabase db reset            # aplica migrations + seed.sql
supabase functions serve

# Agente local
cd agent && npm install
node tools/inspect-dbf.js --dir "C:/ruta/al/ERP/datos"   # relevamiento de esquema
npm test

# App Flutter
cd app
flutter run -d chrome
flutter build web --release --base-href /supervision/
flutter build apk --release --split-per-abi
```

## Estado del proyecto

El acceso a Supabase en la nube está **limitado por ahora**: el esquema se desarrolla y
prueba contra Postgres local (`supabase start`). No ejecutar migraciones contra la nube
hasta que se levante esa restricción.

Ver `HANDOFF.md` para el estado exacto y el próximo paso, y `ROADMAP.md` para las fases.
