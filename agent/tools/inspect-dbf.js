#!/usr/bin/env node
'use strict';

/**
 * Relevamiento del esquema de un ERP FoxPro (Fase 1 del ROADMAP).
 *
 * Recorre una carpeta de datos y, por cada .dbf, reporta: versión, cantidad de
 * registros, página de código, definición de cada campo y unas filas de muestra.
 * Con esa salida se arma `agent/src/config/mapping.yaml`.
 *
 * Se corre en el servidor del comercio. Es SÓLO LECTURA: no modifica ningún .dbf,
 * no toca los índices .cdx y no requiere `npm install` (cero dependencias).
 *
 * Uso:
 *   node inspect-dbf.js --dir "C:/ERP/DATOS"
 *   node inspect-dbf.js --dir "C:/ERP/DATOS" --out relevamiento.json --samples 5
 *   node inspect-dbf.js --dir "C:/ERP/DATOS" --anonymize     (oculta los valores de muestra)
 *
 * Opciones:
 *   --dir <ruta>        Carpeta con los .dbf (obligatoria)
 *   --out <archivo>     JSON de salida        (default: relevamiento-dbf.json)
 *   --samples <n>       Filas de muestra      (default: 3)
 *   --encoding <cp>     Fuerza la codificación (cp850 | cp437 | cp1252)
 *   --recursive         Busca también en subcarpetas
 *   --anonymize         No incluye valores reales, sólo tipo y largo de cada dato
 *   --quiet             Sólo escribe el JSON, sin resumen por consola
 */

const fs = require('fs');
const path = require('path');
const { openDbf } = require('../src/dbf/reader');

function parseArgs(argv) {
  const args = {
    dir: null,
    out: 'relevamiento-dbf.json',
    samples: 3,
    encoding: null,
    recursive: false,
    anonymize: false,
    quiet: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case '--dir':
        args.dir = argv[++i];
        break;
      case '--out':
        args.out = argv[++i];
        break;
      case '--samples':
        args.samples = Number(argv[++i]);
        break;
      case '--encoding':
        args.encoding = argv[++i];
        break;
      case '--recursive':
        args.recursive = true;
        break;
      case '--anonymize':
        args.anonymize = true;
        break;
      case '--quiet':
        args.quiet = true;
        break;
      case '--help':
      case '-h':
        args.help = true;
        break;
      default:
        if (arg.startsWith('--')) {
          throw new Error('Opción desconocida: ' + arg + ' (usá --help)');
        }
    }
  }
  return args;
}

/** Lista los .dbf de una carpeta, opcionalmente recursiva. */
function findDbfFiles(dir, recursive) {
  const found = [];
  const entries = fs.readdirSync(dir, { withFileTypes: true });

  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (recursive) {
        try {
          found.push(...findDbfFiles(full, true));
        } catch (err) {
          // Carpeta sin permisos: se ignora en vez de abortar todo el relevamiento.
        }
      }
    } else if (/\.dbf$/i.test(entry.name)) {
      found.push(full);
    }
  }
  return found.sort();
}

/** Describe un valor sin exponerlo, para el modo --anonymize. */
function describeValue(value) {
  if (value === null || value === undefined) return null;
  if (typeof value === 'number') return '<numero>';
  if (typeof value === 'boolean') return '<booleano>';
  const text = String(value);
  return '<texto ' + text.length + ' chars>';
}

/**
 * Estadística por campo sobre las filas leídas: cuántos nulos, mínimo y máximo.
 * Es lo que permite decidir si un campo sirve como watermark o como clave.
 */
function summarizeField(field, values) {
  const nonNull = values.filter(function (v) {
    return v !== null && v !== undefined && v !== '';
  });

  const summary = {
    sampled: values.length,
    nulls: values.length - nonNull.length,
    distinct: new Set(nonNull.map(String)).size,
  };

  if (nonNull.length === 0) return summary;

  if (field.type === 'N' || field.type === 'F' || field.type === 'I' ||
      field.type === 'B' || field.type === 'Y') {
    const nums = nonNull.filter(function (v) { return typeof v === 'number'; });
    if (nums.length) {
      summary.min = Math.min.apply(null, nums);
      summary.max = Math.max.apply(null, nums);
    }
  } else if (field.type === 'D' || field.type === 'T') {
    const sorted = nonNull.map(String).sort();
    summary.min = sorted[0];
    summary.max = sorted[sorted.length - 1];
  } else if (field.type === 'C' || field.type === 'V' || field.type === 'M') {
    const lengths = nonNull.map(function (v) { return String(v).length; });
    summary.maxLength = Math.max.apply(null, lengths);
  }

  return summary;
}

/** Relevamiento de una tabla. Nunca lanza: los errores se reportan en el JSON. */
function inspectTable(filePath, args) {
  const stat = fs.statSync(filePath);
  const base = {
    file: path.basename(filePath),
    path: filePath,
    sizeBytes: stat.size,
    modifiedAt: stat.mtime.toISOString(),
  };

  let table;
  try {
    table = openDbf(filePath, { encoding: args.encoding });
  } catch (err) {
    return Object.assign(base, { error: err.message });
  }

  try {
    const header = table.header;

    // Se leen `samples` filas para la muestra y hasta 500 para la estadística:
    // suficiente para caracterizar los campos sin recorrer una tabla enorme.
    const statsLimit = Math.min(500, table.recordCount);
    const rows = [];
    for (const row of table.records({ limit: statsLimit })) rows.push(row);

    const fields = header.fields.map(function (field) {
      const values = rows.map(function (r) { return r[field.name]; });
      return {
        name: field.name,
        type: field.type,
        length: field.length,
        decimals: field.decimals,
        nullable: field.nullable,
        autoIncrement: field.autoIncrement,
        stats: summarizeField(field, values),
      };
    });

    const samples = rows.slice(0, args.samples).map(function (row) {
      const out = {};
      for (const field of header.fields) {
        out[field.name] = args.anonymize ? describeValue(row[field.name]) : row[field.name];
      }
      return out;
    });

    return Object.assign(base, {
      version: header.versionName,
      versionByte: '0x' + header.version.toString(16),
      lastUpdate: header.lastUpdate,
      recordCount: table.recordCount,
      headerRecordCount: table.headerRecordCount,
      recordLength: header.recordLength,
      encoding: header.encoding,
      encodingDetected: header.encodingDetected,
      hasMemoFile: table.hasMemoFile,
      hasIndex: header.hasIndexFlag,
      fieldCount: fields.length,
      fields: fields,
      samples: samples,
    });
  } catch (err) {
    return Object.assign(base, { error: err.message });
  } finally {
    table.close();
  }
}

/** Resumen legible por consola, para mirar sin abrir el JSON. */
function printSummary(report) {
  const ok = report.tables.filter(function (t) { return !t.error; });
  const failed = report.tables.filter(function (t) { return t.error; });

  console.log('');
  console.log('Relevamiento de ' + report.directory);
  console.log('Tablas encontradas: ' + report.tables.length +
    ' (' + ok.length + ' leídas, ' + failed.length + ' con error)');
  console.log('');

  const sorted = ok.slice().sort(function (a, b) { return b.recordCount - a.recordCount; });

  console.log('  TABLA                 REGISTROS   CAMPOS  CODIF.   ÚLT. MODIF.');
  console.log('  ' + '-'.repeat(66));
  for (const t of sorted) {
    console.log(
      '  ' + t.file.padEnd(20) +
      String(t.recordCount).padStart(11) +
      String(t.fieldCount).padStart(8) + '  ' +
      String(t.encoding).padEnd(8) +
      String(t.modifiedAt).slice(0, 10)
    );
  }

  if (failed.length) {
    console.log('');
    console.log('  Tablas que no se pudieron leer:');
    for (const t of failed) console.log('    ' + t.file + ': ' + t.error);
  }

  // Pistas para armar el mapping: las tablas grandes con fecha suelen ser el
  // movimiento (ventas), y son el punto de partida del mapeo.
  const candidates = sorted
    .filter(function (t) {
      return t.recordCount > 100 && t.fields.some(function (f) { return f.type === 'D'; });
    })
    .slice(0, 10);

  if (candidates.length) {
    console.log('');
    console.log('  Candidatas a tablas de movimiento (muchos registros + campo fecha):');
    for (const t of candidates) {
      const dates = t.fields
        .filter(function (f) { return f.type === 'D' && f.stats.max; })
        .map(function (f) { return f.name + ' [' + f.stats.min + ' .. ' + f.stats.max + ']'; });
      console.log('    ' + t.file.padEnd(20) + dates.join('  '));
    }
  }

  console.log('');
  console.log('Detalle completo en: ' + report.outputFile);
  console.log('Próximo paso: armar agent/src/config/mapping.yaml con estas tablas.');
  console.log('');
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }

  if (args.help || !args.dir) {
    console.log(fs.readFileSync(__filename, 'utf8').split('*/')[0].split('/**')[1]);
    process.exit(args.dir ? 0 : 1);
  }

  if (!fs.existsSync(args.dir)) {
    console.error('No existe la carpeta: ' + args.dir);
    process.exit(1);
  }

  const files = findDbfFiles(args.dir, args.recursive);
  if (files.length === 0) {
    console.error('No se encontró ningún .dbf en ' + args.dir +
      (args.recursive ? '' : ' (probá con --recursive)'));
    process.exit(1);
  }

  if (!args.quiet) {
    console.log('Leyendo ' + files.length + ' tablas (sólo lectura, el ERP puede seguir operando)...');
  }

  const tables = files.map(function (file) {
    if (!args.quiet) process.stdout.write('.');
    return inspectTable(file, args);
  });
  if (!args.quiet) process.stdout.write('\n');

  const report = {
    generatedAt: new Date().toISOString(),
    directory: path.resolve(args.dir),
    host: require('os').hostname(),
    anonymized: args.anonymize,
    outputFile: path.resolve(args.out),
    tables: tables,
  };

  fs.writeFileSync(args.out, JSON.stringify(report, null, 2), 'utf8');

  if (!args.quiet) printSummary(report);
}

if (require.main === module) main();

module.exports = { inspectTable, findDbfFiles, parseArgs };
