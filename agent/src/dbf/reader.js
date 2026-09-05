'use strict';

/**
 * Lector de tablas DBF (dBASE III/IV, FoxPro 2.x, Visual FoxPro) sin dependencias.
 *
 * Por qué propio y no una librería:
 *  - Este archivo se copia tal cual al servidor del comercio para el relevamiento
 *    inicial, donde no hay `npm install` ni internet garantizado.
 *  - Necesitamos control fino sobre las páginas de código y sobre las fechas: un
 *    `Date` de JS aplicaría zona horaria y correría el día comercial, así que las
 *    fechas se devuelven como string 'AAAA-MM-DD'.
 *
 * REGLA DEL PROYECTO: esto abre en modo lectura ('r') y nunca escribe. No toca el
 * .cdx ni marca registros. El ERP debe poder seguir operando mientras leemos.
 */

const fs = require('fs');
const path = require('path');
const { decode, encodingFromLanguageDriver } = require('./codepages');

const HEADER_SIZE = 32;
const FIELD_DESC_SIZE = 32;
const FIELD_TERMINATOR = 0x0d;
const DELETED_MARK = 0x2a; // caracter '*'
const JULIAN_UNIX_EPOCH = 2440588; // dia juliano del 1970-01-01

const VERSIONS = {
  0x02: 'FoxBASE',
  0x03: 'dBASE III+ / FoxPro 2.x (sin memo)',
  0x30: 'Visual FoxPro',
  0x31: 'Visual FoxPro (autoincremento)',
  0x32: 'Visual FoxPro (varchar/varbinary)',
  0x43: 'dBASE IV con archivo .dbv',
  0x83: 'dBASE III+ / FoxPro 2.x (con memo)',
  0x8b: 'dBASE IV con memo',
  0xf5: 'FoxPro 2.x con memo',
  0xfb: 'FoxPro sin memo',
};

/** Lee exactamente `length` bytes desde `position`. Lanza si el archivo se cortó. */
function readExact(fd, length, position) {
  const buf = Buffer.alloc(length);
  const read = fs.readSync(fd, buf, 0, length, position);
  if (read !== length) {
    throw new Error(
      'Lectura incompleta: se esperaban ' + length + ' bytes en la posicion ' + position +
        ', se leyeron ' + read + '. El archivo puede estar truncado o en uso exclusivo por el ERP.'
    );
  }
  return buf;
}

/** Parsea el header y los descriptores de campo. No lee registros. */
function readHeader(fd, options) {
  const encoding = options && options.encoding;
  const head = readExact(fd, HEADER_SIZE, 0);

  const version = head[0];
  const yy = head[1];
  // FoxPro guarda el año en 2 digitos: <80 es 20xx, >=80 es 19xx.
  const year = yy < 80 ? 2000 + yy : 1900 + yy;
  const lastUpdate =
    year + '-' + String(head[2]).padStart(2, '0') + '-' + String(head[3]).padStart(2, '0');

  const recordCount = head.readUInt32LE(4);
  const headerLength = head.readUInt16LE(8);
  const recordLength = head.readUInt16LE(10);
  const tableFlags = head[28];
  const languageDriver = head[29];

  const detected = encodingFromLanguageDriver(languageDriver);
  const resolvedEncoding = encoding || detected || 'cp1252';

  // Descriptores de campo: bloques de 32 bytes hasta el terminador 0x0D.
  const descriptorBytes = headerLength - HEADER_SIZE;
  const descriptors = readExact(fd, descriptorBytes, HEADER_SIZE);

  const fields = [];
  let offset = 1; // el byte 0 de cada registro es la marca de borrado
  for (let pos = 0; pos + FIELD_DESC_SIZE <= descriptorBytes; pos += FIELD_DESC_SIZE) {
    if (descriptors[pos] === FIELD_TERMINATOR) break;

    const rawName = descriptors.subarray(pos, pos + 11);
    const nul = rawName.indexOf(0);
    const name = rawName
      .subarray(0, nul === -1 ? 11 : nul)
      .toString('latin1')
      .trim();
    if (!name) break;

    const flags = descriptors[pos + 18];
    const field = {
      name: name,
      type: String.fromCharCode(descriptors[pos + 11]),
      length: descriptors[pos + 16],
      decimals: descriptors[pos + 17],
      flags: flags,
      offset: offset,
      nullable: Boolean(flags & 0x02),
      system: Boolean(flags & 0x01),
      autoIncrement: Boolean(flags & 0x0c),
    };

    offset += field.length;
    fields.push(field);
  }

  return {
    version: version,
    versionName: VERSIONS[version] || 'desconocida (0x' + version.toString(16) + ')',
    lastUpdate: lastUpdate,
    recordCount: recordCount,
    headerLength: headerLength,
    recordLength: recordLength,
    languageDriver: languageDriver,
    encoding: resolvedEncoding,
    encodingDetected: detected,
    hasMemoFlag: Boolean(tableFlags & 0x02) || Boolean(version & 0x80) || version === 0xf5,
    hasIndexFlag: Boolean(tableFlags & 0x01),
    fields: fields,
  };
}

/** Lector de memos .fpt (FoxPro). Los .dbt de dBASE III no están soportados. */
function openMemo(dbfPath) {
  const candidates = [
    dbfPath.replace(/\.dbf$/i, '.fpt'),
    dbfPath.replace(/\.dbf$/i, '.FPT'),
  ];
  const found = candidates.filter(function (p) {
    return fs.existsSync(p);
  })[0];
  if (!found) return null;

  const fd = fs.openSync(found, 'r');
  const head = readExact(fd, 8, 0);
  const blockSize = head.readUInt16BE(6) || 512;
  const fileSize = fs.fstatSync(fd).size;

  return {
    path: found,
    blockSize: blockSize,
    read: function (blockNumber) {
      if (!blockNumber) return null;
      const position = blockNumber * blockSize;
      if (position + 8 > fileSize) return null;

      const meta = readExact(fd, 8, position);
      const type = meta.readUInt32BE(0); // 1 = texto
      const length = meta.readUInt32BE(4);
      if (length === 0 || position + 8 + length > fileSize) return null;

      const data = readExact(fd, length, position + 8);
      return type === 1 ? data : data.toString('base64');
    },
    close: function () {
      fs.closeSync(fd);
    },
  };
}

/** Convierte los bytes crudos de un campo al tipo JS correspondiente. */
function parseField(field, buf, encoding, memo) {
  switch (field.type) {
    case 'C': // caracter
    case 'V': // varchar (VFP9)
      return decode(buf, encoding).replace(/\0/g, '').replace(/\s+$/, '') || null;

    case 'N': // numerico
    case 'F': {
      // float
      const text = buf.toString('latin1').trim();
      if (!text || text === '.') return null;
      const value = Number(text);
      return Number.isNaN(value) ? null : value;
    }

    case 'D': {
      // fecha AAAAMMDD -> 'AAAA-MM-DD' como string, sin zona horaria
      const text = buf.toString('latin1').trim();
      if (text.length !== 8 || text === '00000000' || !/^\d{8}$/.test(text)) return null;
      return text.slice(0, 4) + '-' + text.slice(4, 6) + '-' + text.slice(6, 8);
    }

    case 'L': {
      // logico
      const c = String.fromCharCode(buf[0]);
      if ('TtYy'.indexOf(c) !== -1) return true;
      if ('FfNn'.indexOf(c) !== -1) return false;
      return null;
    }

    case 'I': // entero de 32 bits
      return buf.length >= 4 ? buf.readInt32LE(0) : null;

    case 'B': // double (Visual FoxPro)
      return buf.length >= 8 ? buf.readDoubleLE(0) : null;

    case 'Y': // currency: entero de 64 bits con 4 decimales implicitos
      return buf.length >= 8 ? Number(buf.readBigInt64LE(0)) / 10000 : null;

    case 'T': {
      // datetime: dia juliano + milisegundos desde medianoche
      if (buf.length < 8) return null;
      const julian = buf.readInt32LE(0);
      const ms = buf.readInt32LE(4);
      if (julian === 0) return null;
      const days = julian - JULIAN_UNIX_EPOCH;
      // Se devuelve ISO sin 'Z': es hora local del comercio, no UTC.
      return new Date(Date.UTC(1970, 0, 1 + days, 0, 0, 0, ms)).toISOString().replace('Z', '');
    }

    case 'M': {
      // memo: el campo guarda el numero de bloque dentro del .fpt
      let block;
      if (field.length === 4) {
        block = buf.readUInt32LE(0);
      } else {
        const text = buf.toString('latin1').trim();
        block = text ? Number(text) : 0;
      }
      if (!block || Number.isNaN(block)) return null;
      if (!memo) return '<memo #' + block + ' - .fpt no disponible>';

      const raw = memo.read(block);
      if (raw === null) return null;
      return Buffer.isBuffer(raw) ? decode(raw, encoding).replace(/\s+$/, '') : raw;
    }

    case 'G': // general (OLE)
    case 'P': // picture
    case 'Q': // varbinary
      return '<binario ' + field.length + 'b>';

    default:
      return decode(buf, encoding).replace(/\s+$/, '') || null;
  }
}

/**
 * Abre un DBF en sólo lectura.
 *
 * Devuelve el header ya parseado y un iterador perezoso de registros: no carga la
 * tabla entera en memoria, así una tabla de ventas de varios GB no revienta el
 * proceso del agente en el servidor del comercio.
 */
function openDbf(dbfPath, options) {
  const opts = options || {};
  const includeDeleted = opts.includeDeleted === true;
  const withMemo = opts.withMemo !== false;

  const fd = fs.openSync(dbfPath, 'r');
  let memo = null;

  try {
    const header = readHeader(fd, { encoding: opts.encoding });

    if (withMemo && header.hasMemoFlag) {
      try {
        memo = openMemo(dbfPath);
      } catch (err) {
        memo = null; // sin memo se sigue adelante: los campos M salen como null
      }
    }

    const fileSize = fs.fstatSync(fd).size;
    // Algunos ERP dejan el contador del header desactualizado tras un corte de luz;
    // el tamaño real del archivo es la fuente confiable.
    const countBySize = Math.floor((fileSize - header.headerLength) / header.recordLength);
    const effectiveCount = Math.max(0, Math.min(header.recordCount, countBySize));

    function* records(readOptions) {
      const ro = readOptions || {};
      const limit = ro.limit === undefined ? Infinity : ro.limit;
      const skip = ro.skip || 0;

      const buf = Buffer.alloc(header.recordLength);
      let yielded = 0;
      let skipped = 0;

      for (let i = 0; i < effectiveCount; i++) {
        if (yielded >= limit) return;

        const position = header.headerLength + i * header.recordLength;
        const read = fs.readSync(fd, buf, 0, header.recordLength, position);
        if (read !== header.recordLength) return; // archivo truncado: cortamos limpio

        const deleted = buf[0] === DELETED_MARK;
        if (deleted && !includeDeleted) continue;
        if (skipped < skip) {
          skipped++;
          continue;
        }

        const row = {};
        for (const field of header.fields) {
          const slice = buf.subarray(field.offset, field.offset + field.length);
          row[field.name] = parseField(field, slice, header.encoding, memo);
        }
        row.__recno = i + 1;
        if (includeDeleted) row.__deleted = deleted;

        yielded++;
        yield row;
      }
    }

    return {
      path: dbfPath,
      name: path.basename(dbfPath),
      header: header,
      recordCount: effectiveCount,
      headerRecordCount: header.recordCount,
      hasMemoFile: Boolean(memo),
      records: records,
      close: function () {
        if (memo) memo.close();
        fs.closeSync(fd);
      },
    };
  } catch (err) {
    if (memo) memo.close();
    fs.closeSync(fd);
    throw err;
  }
}

module.exports = { openDbf, readHeader, parseField, VERSIONS };
