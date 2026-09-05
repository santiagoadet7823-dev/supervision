# SUPERVISION

Plataforma de Business Intelligence multi-tenant para comercios que usan un ERP legacy
basado en **FoxPro / tablas DBF**.

Cada comercio ve, desde el móvil o el escritorio, sus ventas, márgenes, rotación de
productos, cuentas corrientes y cartera de cheques — sin tocar ni arriesgar el ERP local.

## El problema

Hoy el dueño de un comercio sólo puede ver sus números sentándose frente a la máquina
donde corre el ERP. No hay analítica comparativa, no hay acceso remoto, y no hay forma
de mirar varios locales juntos.

## La solución

```
┌─────────────────────┐
│  ERP FoxPro (.dbf)  │   servidor local del comercio
└──────────┬──────────┘
           │ lectura sólo-lectura, sobre copia sombra
┌──────────▼──────────┐
│   Agente Local      │   Node.js, servicio de Windows
│   (agrega y encola) │   agrega por día / hora / producto
└──────────┬──────────┘
           │ HTTPS saliente + API key por tenant (gzip, lotes idempotentes)
┌──────────▼──────────┐
│  Supabase           │   Postgres + RLS (aislamiento por tenant)
│  Postgres + Auth    │   Edge Functions: /ingest y /kpis
└──────────┬──────────┘
           │ REST/RPC + JWT
┌──────────▼──────────┐
│  App Flutter        │   PWA (GitHub Pages) + APK (GitHub Releases)
└─────────────────────┘
```

El agente **sólo hace conexiones salientes**: no hay que abrir puertos, contratar IP fija
ni montar una VPN en el comercio.

## Módulos

- **Dashboard** — ventas diarias/semanales/mensuales/anuales, comparativas contra el
  período anterior, días y horarios pico, avance sobre metas.
- **Productos** — top ventas por cantidad y por facturación, baja rotación, márgenes de
  ganancia ordenables.
- **Finanzas** — cuentas corrientes de clientes y proveedores con antigüedad de deuda,
  y cartera de cheques por estado.

## Estructura del repositorio

| Carpeta | Contenido |
|---|---|
| `agent/` | Agente local Node.js: lectura de DBF, agregación, cola de envío, servicio de Windows |
| `supabase/` | Migraciones SQL, políticas RLS, funciones de KPI, Edge Functions |
| `app/` | App Flutter (web/PWA + Android) |
| `PLANES/` | Todo el planeamiento del proyecto, versionado |
| `LINKS-IMPORTANTES/` | Accesos operativos (sin credenciales) |
| `docs/` | Arquitectura, runbook de instalación, mapeos por versión de ERP |

## Puesta en marcha (desarrollo)

Requisitos: Node.js 20+, Flutter 3.24+, Supabase CLI, Docker (para el Postgres local).

```bash
# 1. Base de datos local
supabase start
supabase db reset

# 2. Agente
cd agent && npm install && npm test

# 3. App
cd app && flutter pub get && flutter run -d chrome
```

## Instalación en un comercio

1. Generar una API key para el tenant desde el panel de super_admin.
2. Correr el instalador `SupervisionAgent-setup.exe` en el servidor del ERP.
3. Indicar la carpeta de datos del ERP y pegar la API key (se guarda cifrada con DPAPI).
4. El servicio arranca solo y hace el primer sync histórico en ventana nocturna.

Runbook detallado en `docs/`.

## Documentos

- **[CLAUDE.md](CLAUDE.md)** — contexto y convenciones para trabajar en el repo
- **[ROADMAP.md](ROADMAP.md)** — fases y estado
- **[HANDOFF.md](HANDOFF.md)** — dónde quedó el trabajo y cuál es el próximo paso
- **[PLANES/](PLANES/)** — planeamiento
- **[LINKS-IMPORTANTES/](LINKS-IMPORTANTES/)** — accesos
