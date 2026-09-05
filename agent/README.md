# Agente Local

Microservicio Node.js que corre en el servidor del comercio, lee las tablas DBF del ERP
FoxPro y sincroniza agregados a la nube.

## Garantía de no intrusión

El ERP es el sistema del que vive el negocio. El agente está construido alrededor de una
sola regla: **nunca degradarlo ni bloquearlo.**

- Abre los `.dbf` en modo lectura (`'r'`) y **jamás escribe**.
- No toca los índices `.cdx` ni marca registros como leídos.
- Antes de parsear en producción, copia a `staging/` y lee la copia, para que una
  escritura del ERP a mitad de lectura no produzca un registro corrupto.
- Corre con prioridad de proceso baja: si hay contención, el ERP siempre gana.
- El recálculo histórico pesado va en ventana nocturna configurable.

Hay un test que verifica que leer una tabla no cambia su `mtime` ni su tamaño.

## Relevamiento del esquema (Fase 1)

Antes de escribir cualquier extractor hay que saber cómo se llaman las tablas y los campos
de esta instalación del ERP. Para eso está `tools/inspect-dbf.js`.

**Cero dependencias**: se copia la carpeta `agent/` al servidor del ERP y se corre con Node
a secas. No hace falta `npm install` ni internet.

```bash
node tools/inspect-dbf.js --dir "C:/ERP/DATOS"
```

Genera `relevamiento-dbf.json` con, por cada tabla: versión del formato, cantidad de
registros, página de código, definición de cada campo (tipo, largo, decimales), estadística
por campo (nulos, valores distintos, mínimo y máximo) y filas de muestra.

Opciones útiles:

| Opción | Para qué |
|---|---|
| `--recursive` | El ERP guarda los datos en subcarpetas |
| `--samples 5` | Más filas de muestra |
| `--anonymize` | Reemplaza los valores reales por su tipo y largo. **Usar cuando el relevamiento sale del comercio**, para no mover datos de clientes. |
| `--encoding cp850` | El header no declara bien la página de código y los acentos salen rotos |

Con esa salida se arma `src/config/mapping.yaml`, que traduce los nombres reales del ERP al
modelo canónico del proyecto.

## Páginas de código

Los ERP de FoxPro sobre DOS suelen estar en **cp850**; los más nuevos, en cp1252. Node no
trae esos decoders, así que `src/dbf/codepages.js` los implementa. El agente detecta la
página desde el byte 29 del header del DBF, con `--encoding` como escape manual.

Importa: si se decodifica mal, "Ñandú" y "Café" llegan rotos a la nube y ya no se recuperan.

## Fechas

Las fechas se devuelven como **string `'AAAA-MM-DD'`**, no como `Date`. Un `Date` de JS
aplica zona horaria y puede correr el día un lugar — y el día comercial es justo el eje por
el que agrupamos todas las ventas.

## Desarrollo

```bash
npm test          # tests del lector de DBF, con tablas sintéticas
npm run inspect -- --dir "C:/ERP/DATOS"
```

Los tests generan sus propios `.dbf` con `test/helpers/make-dbf.js`, así que no hace falta
una instalación del ERP para trabajar en el lector. Ese generador es **sólo para tests**:
en producción el agente nunca escribe un DBF.

## Estructura

```
src/
  dbf/
    codepages.js   decodificación cp850 / cp437 / cp1252
    reader.js      lector de DBF sin dependencias (header, tipos, memos .fpt)
    mapper.js      (pendiente) DBF real -> modelo canónico según mapping.yaml
  extractors/      (pendiente) ventas, productos, cuentas corrientes, cheques
  aggregators/     (pendiente) diario, horario, por producto, aging
  state/           (pendiente) SQLite: watermarks + cola de lotes
  transport/       (pendiente) gzip + NDJSON con reintentos
  service/         (pendiente) instalación como servicio de Windows
tools/
  inspect-dbf.js   relevamiento del esquema del ERP
```
