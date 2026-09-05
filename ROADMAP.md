# ROADMAP

Estado global: **Fase 0 en curso** — el repositorio está inicializado y falta el
relevamiento del esquema DBF real.

Leyenda: `[ ]` pendiente · `[~]` en curso · `[x]` completado

---

## Fase 0 — Scaffolding del repositorio  `[x]`

- [x] Estructura de carpetas del monorepo
- [x] `CLAUDE.md`, `README.md`, `ROADMAP.md`, `HANDOFF.md`
- [x] `PLANES/` con el plan de arquitectura inicial
- [x] `LINKS-IMPORTANTES/`
- [x] `.gitignore` y commit inicial

**Hecho cuando:** el repo está en GitHub y cualquiera puede clonarlo y entender qué es.

---

## Fase 1 — Relevamiento del esquema DBF  `[~]`  *(bloqueante para todo el agente)*

- [x] Lector de DBF sin dependencias (`agent/src/dbf/`): header, tipos, memos .fpt, cp850/cp437/cp1252
- [x] `agent/tools/inspect-dbf.js`: tablas, campos, tipos, estadística por campo y filas de muestra
- [x] Tests del lector con tablas DBF sintéticas (15 casos, incluido "no modifica el archivo")
- [ ] Correrlo sobre una instalación real del ERP
- [ ] Producir `agent/src/config/mapping.yaml` (tabla/campo real → modelo canónico)
- [ ] Documentar el mapeo en `docs/`

**Hecho cuando:** existe un `mapping.yaml` validado contra datos reales y sabemos si el
ERP guarda el costo unitario histórico en el detalle de venta o hay que aproximarlo.

---

## Fase 2 — Esquema de base de datos y RLS  `[ ]`

- [ ] Migraciones: `tenants`, `profiles`, `agent_keys`
- [ ] Migraciones: tablas de hechos (`sales_daily`, `sales_hourly`, `products`,
      `product_sales_daily`, `account_balances`, `checks`, `sales_targets`, `sync_runs`)
- [ ] `auth_tenant_id()`, `is_super_admin()` y policies RLS en **todas** las tablas
- [ ] Funciones de KPI: `sales_comparison`, `product_margins`, `peak_days`, `low_rotation`
- [ ] `seed.sql` con dos tenants de prueba y totales calculados a mano
- [ ] **Test de aislamiento**: usuario del tenant A recibe 0 filas del tenant B, en cada
      tabla y cada RPC

**Hecho cuando:** `supabase db reset` levanta todo y el test de aislamiento pasa.

---

## Fase 3 — Agente local  `[ ]`

- [ ] Lector de DBF sin locks, con copia sombra a `staging/`
- [ ] Mapper según `mapping.yaml`
- [ ] Extractores: ventas, productos, cuentas corrientes, cheques
- [ ] Agregadores: diario, horario, por producto/día, aging de cuentas
- [ ] Estado en SQLite: watermarks + cola durable de lotes
- [ ] Transporte: gzip + NDJSON, `batch_id`, backoff exponencial
- [ ] Prioridad de proceso baja y throttling entre chunks

**Hecho cuando:** con el ERP en uso normal, el agente sincroniza sin degradar su latencia
y sin modificar el `mtime` de ningún `.dbf`.

---

## Fase 4 — Edge Functions  `[ ]`

- [ ] `/ingest`: auth por API key (argon2), tenant desde la key, validación Zod, UPSERT por
      lotes con `service_role`, registro en `sync_runs`, rate limit
- [ ] `/kpis`: compone el dashboard con el JWT del usuario (RLS activa)

**Hecho cuando:** el agente sincroniza contra las funciones y reenviar un lote 3 veces no
altera los totales.

---

## Fase 5 — App Flutter  `[ ]`

- [ ] Auth + guard de rol (`super_admin` / `owner` / `manager`)
- [ ] Tema dark con superficies translúcidas (glassmorphism), responsivo
- [ ] Dashboard: KPIs, comparativas, días pico, metas
- [ ] Productos: top ventas, baja rotación, márgenes
- [ ] Finanzas: cuentas corrientes con aging, cartera de cheques
- [ ] Caché offline de agregados en `flutter_secure_storage`, con purga al cerrar sesión

**Hecho cuando:** un dueño de negocio puede ver todos sus módulos desde el móvil.

---

## Fase 6 — Empaquetado y CI/CD  `[ ]`

- [ ] `ci.yml`: tests de agente, SQL y Flutter en cada PR
- [ ] `deploy-pwa.yml`: build web → GitHub Pages (`--base-href`, `.nojekyll`, `404.html`)
- [ ] Aviso in-app de "hay una versión nueva" cuando el service worker se actualiza
- [ ] `release-apk.yml`: APK firmado → GitHub Release + `version.json`
- [ ] Módulo de autoactualización del APK con verificación de `sha256`
- [ ] Servicio de Windows + instalador Inno Setup + autoactualización del agente

**Hecho cuando:** publicar un tag genera el APK y la app instalada ofrece actualizarse.

---

## Decisiones pendientes

- **Visibilidad del repositorio.** GitHub Pages sobre repo privado requiere plan Pro/Team,
  y los assets de Release privados requieren token. Recomendación: repo privado para el
  código + repo público chico con el build web y los APK.
- **Costo histórico.** Si el ERP no guarda el costo unitario al momento de la venta, los
  márgenes se calculan con el costo actual del maestro. Hay que decidir si eso es
  aceptable o si se reconstruye el costo desde otra tabla.
