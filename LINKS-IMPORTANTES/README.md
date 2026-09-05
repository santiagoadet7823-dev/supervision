# LINKS IMPORTANTES

Accesos operativos del proyecto. **Sólo URLs y para qué sirve cada una — ninguna
credencial, token o contraseña acá.** Los secretos van en GitHub Secrets y Supabase Vault.

## Infraestructura del proyecto

| Qué | URL | Para qué |
|---|---|---|
| Repositorio | https://github.com/santiagoadet7823-dev/supervision | Código, issues, PRs |
| GitHub Actions | https://github.com/santiagoadet7823-dev/supervision/actions | Estado de los builds y despliegues |
| PWA en producción | https://santiagoadet7823-dev.github.io/supervision/ | La app web que usan los subclientes *(pendiente de primer deploy)* |
| Releases (APK) | https://github.com/santiagoadet7823-dev/supervision/releases | Descarga manual del APK *(pendiente del primer tag)* |
| `version.json` | https://santiagoadet7823-dev.github.io/supervision/version.json | Lo consulta la app Android para autoactualizarse *(pendiente)* |
| Dashboard de Supabase | https://supabase.com/dashboard | Base de datos, Auth, logs de Edge Functions *(proyecto pendiente)* |

> El repositorio es **público** por ahora; se pasa a privado en unos meses. Mientras tanto:
> ningún secreto va al repo (ver `.gitignore`), y la `anon key` de Supabase es pública por diseño
> — lo que protege los datos es la RLS, no el secreto de esa clave.

## Documentación técnica de referencia

| Tema | Link |
|---|---|
| Supabase — Row Level Security | https://supabase.com/docs/guides/database/postgres/row-level-security |
| Supabase — Edge Functions | https://supabase.com/docs/guides/functions |
| Supabase — Flutter | https://supabase.com/docs/reference/dart/introduction |
| Flutter — build web / PWA | https://docs.flutter.dev/platform-integration/web/building |
| Flutter — build y firma del APK | https://docs.flutter.dev/deployment/android |
| GitHub Pages con Actions | https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site |
| Formato de archivo DBF (xBase) | https://en.wikipedia.org/wiki/.dbf |
| Visual FoxPro — tipos de datos | https://learn.microsoft.com/en-us/previous-versions/visualstudio/foxpro/ |
| `node-windows` (servicio de Windows) | https://github.com/coreybutler/node-windows |
| Inno Setup (instalador) | https://jrsoftware.org/isinfo.php |
| `fl_chart` (gráficos en Flutter) | https://pub.dev/packages/fl_chart |
| Riverpod (estado) | https://riverpod.dev |
| go_router (navegación) | https://pub.dev/packages/go_router |

## Documentos internos

- [Plan de arquitectura inicial](../PLANES/2026-09-05-arquitectura-inicial.md)
- [Estado actual y próximo paso](../HANDOFF.md)
- [Roadmap por fases](../ROADMAP.md)
