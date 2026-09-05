'use strict';

/**
 * Generador de tablas DBF sintéticas — SÓLO PARA TESTS.
 *
 * El agente nunca escribe DBF en producción. Esto existe para poder verificar el
 * lector (páginas de código, tipos, registros borrados, headers desactualizados)
 * sin depender de una instalación real del ERP, que todavía no tenemos.
 */

const fs = require('fs');
const { HIGH_HALF } = require('../../src/dbf/codepages');

const HEADER_SIZE = 32;
const FIELD_DESC_SIZE = 32;

/** Construye el mapa inverso unicode -> byte para una página de código. */
function encoderFor(encoding) {
  if (encoding === 'cp1252' || encoding === 'latin1') {
    return function (text) {
      return Buffer.from(text, 'latin1');
    };
  }

  const high = HIGH_HALF[encoding];
  if (!high) throw new Error('Página de código no soportada por el generador: ' + encoding);

  const reverse = new Map();
  for (let i = 0; i < 128; i++) reverse.set(String.fromCharCode(i), i);
  for (let i = 0; i < 128; i++) reverse.set(high[i], 128 + i);

  return function (text) {
    const buf = Buffer.alloc(text.length);
    for (let i = 0; i < text.length; i++) {
      const byte = reverse.get(text[i]);
      buf[i] = byte === undefined ? 0x3f : byte; // '?' para lo que no está en la página
    }
    return buf;
  };
}

/** Serializa el valor de un campo al ancho fijo que exige el formato. */
function encodeValue(field, value, encode) {
  const out = Buffer.alloc(field.length, 0x20); // relleno con espacios

  if (value === null || value === undefined) {
    if (field.type === 'D') out.fill(0x20);
    return out;
  }

  switch (field.type) {
    case 'C': {
      const bytes = encode(String(value));
      bytes.copy(out, 0, 0, Math.min(bytes.length, field.length));
      return out;
    }
    case 'N':
    case 'F': {
      const text = Number(value).toFixed(field.decimals || 0);
      const padded = text.padStart(field.length, ' ').slice(-field.length);
      out.write(padded, 0, 'latin1');
      return out;
    }
    case 'D': {
      // Se espera 'AAAA-MM-DD'; en el archivo va como AAAAMMDD.
      out.write(String(value).replace(/-/g, '').padEnd(8, ' ').slice(0, 8), 0, 'latin1');
      return out;
    }
    case 'L':
      out.write(value ? 'T' : 'F', 0, 'latin1');
      return out;
    case 'I':
      out.writeInt32LE(Number(value), 0);
      return out;
    case 'B':
      out.writeDoubleLE(Number(value), 0);
      return out;
    case 'Y':
      out.writeBigInt64LE(BigInt(Math.round(Number(value) * 10000)), 0);
      return out;
    default:
      throw new Error('Tipo no soportado por el generador: ' + field.type);
  }
}

/**
 * Escribe un .dbf.
 *
 * @param {string} filePath        destino
 * @param {Array}  fields          [{ name, type, length, decimals }]
 * @param {Array}  rows            objetos con las claves de `fields`
 * @param {object} options
 *   - encoding: 'cp850' | 'cp437' | 'cp1252'  (default cp850, el más común en ERP DOS)
 *   - deleted:  array de índices de fila a marcar como borradas
 *   - version:  byte de versión (default 0x03)
 *   - recordCountOverride: fuerza un contador de header distinto al real, para
 *     simular el header desactualizado que deja un corte de luz
 */
function writeDbf(filePath, fields, rows, options) {
  const opts = options || {};
  const encoding = opts.encoding || 'cp850';
  const deleted = new Set(opts.deleted || []);
  const encode = encoderFor(encoding);

  const languageDriver = { cp437: 0x01, cp850: 0x02, cp1252: 0x03 }[encoding] || 0x02;

  const headerLength = HEADER_SIZE + FIELD_DESC_SIZE * fields.length + 1;
  const recordLength = 1 + fields.reduce(function (sum, f) { return sum + f.length; }, 0);

  const header = Buffer.alloc(headerLength, 0);
  header[0] = opts.version === undefined ? 0x03 : opts.version;
  header[1] = 126; // 2026
  header[2] = 9;
  header[3] = 5;
  header.writeUInt32LE(
    opts.recordCountOverride === undefined ? rows.length : opts.recordCountOverride,
    4
  );
  header.writeUInt16LE(headerLength, 8);
  header.writeUInt16LE(recordLength, 10);
  header[29] = languageDriver;

  fields.forEach(function (field, i) {
    const at = HEADER_SIZE + i * FIELD_DESC_SIZE;
    header.write(field.name.slice(0, 10), at, 'latin1'); // 11 bytes, queda el \0 final
    header[at + 11] = field.type.charCodeAt(0);
    header[at + 16] = field.length;
    header[at + 17] = field.decimals || 0;
  });
  header[headerLength - 1] = 0x0d; // terminador de descriptores

  const body = rows.map(function (row, index) {
    const record = Buffer.alloc(recordLength, 0x20);
    record[0] = deleted.has(index) ? 0x2a : 0x20;
    let offset = 1;
    for (const field of fields) {
      encodeValue(field, row[field.name], encode).copy(record, offset);
      offset += field.length;
    }
    return record;
  });

  fs.writeFileSync(
    filePath,
    Buffer.concat([header].concat(body, [Buffer.from([0x1a])]))
  );

  return { headerLength: headerLength, recordLength: recordLength };
}

module.exports = { writeDbf };
