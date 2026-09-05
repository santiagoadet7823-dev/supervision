'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { openDbf } = require('../src/dbf/reader');
const { decode } = require('../src/dbf/codepages');
const { writeDbf } = require('./helpers/make-dbf');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'supervision-dbf-'));

// Un maestro de artículos como el que devolvería un ERP argentino: descripciones
// con acentos y eñes, precios con decimales, fechas y una baja lógica.
const FIELDS = [
  { name: 'CODIGO', type: 'C', length: 10 },
  { name: 'DESCRIP', type: 'C', length: 30 },
  { name: 'PRECIO', type: 'N', length: 12, decimals: 2 },
  { name: 'STOCK', type: 'N', length: 10, decimals: 3 },
  { name: 'FECHA', type: 'D', length: 8 },
  { name: 'ACTIVO', type: 'L', length: 1 },
];

const ROWS = [
  { CODIGO: 'ART001', DESCRIP: 'Café molido 500g', PRECIO: 1234.5, STOCK: 10.5, FECHA: '2026-01-15', ACTIVO: true },
  { CODIGO: 'ART002', DESCRIP: 'Ñoquis de papa', PRECIO: 890.25, STOCK: 0, FECHA: '2026-02-28', ACTIVO: false },
  { CODIGO: 'ART003', DESCRIP: 'Azúcar impalpable', PRECIO: 0, STOCK: 3, FECHA: null, ACTIVO: true },
  { CODIGO: 'ART004', DESCRIP: 'Producto dado de baja', PRECIO: 100, STOCK: 1, FECHA: '2025-12-31', ACTIVO: false },
];

function fixture(name, rows, options) {
  const file = path.join(tmp, name);
  writeDbf(file, FIELDS, rows || ROWS, options);
  return file;
}

function readAll(file, options) {
  const table = openDbf(file, options);
  try {
    return { table: table, rows: Array.from(table.records()) };
  } finally {
    table.close();
  }
}

test('lee el header: version, cantidad de registros y definicion de campos', function () {
  const table = openDbf(fixture('maestro.dbf'));
  try {
    assert.strictEqual(table.recordCount, 4);
    assert.strictEqual(table.header.fields.length, 6);
    assert.strictEqual(table.header.lastUpdate, '2026-09-05');

    const precio = table.header.fields.find(function (f) { return f.name === 'PRECIO'; });
    assert.strictEqual(precio.type, 'N');
    assert.strictEqual(precio.length, 12);
    assert.strictEqual(precio.decimals, 2);
  } finally {
    table.close();
  }
});

test('detecta la pagina de codigo desde el header y decodifica acentos y enies', function () {
  const result = readAll(fixture('acentos.dbf'));
  assert.strictEqual(result.table.header.encodingDetected, 'cp850');
  assert.strictEqual(result.rows[0].DESCRIP, 'Café molido 500g');
  assert.strictEqual(result.rows[1].DESCRIP, 'Ñoquis de papa');
  assert.strictEqual(result.rows[2].DESCRIP, 'Azúcar impalpable');
});

test('leer con la codificacion equivocada rompe el texto (por eso la detectamos)', function () {
  // Mismo archivo cp850 forzado a cp1252: es el bug que arruina los datos en silencio.
  const result = readAll(fixture('acentos2.dbf'), { encoding: 'cp1252' });
  assert.notStrictEqual(result.rows[1].DESCRIP, 'Ñoquis de papa');
});

test('convierte los tipos: numericos, logicos y fechas como string sin zona horaria', function () {
  const rows = readAll(fixture('tipos.dbf')).rows;

  assert.strictEqual(rows[0].PRECIO, 1234.5);
  assert.strictEqual(rows[0].STOCK, 10.5);
  assert.strictEqual(rows[0].ACTIVO, true);
  assert.strictEqual(rows[1].ACTIVO, false);

  // La fecha es string 'AAAA-MM-DD': un Date de JS le aplicaria zona horaria y
  // podria correr el dia comercial, que es justo lo que agrupamos.
  assert.strictEqual(rows[0].FECHA, '2026-01-15');
  assert.strictEqual(typeof rows[0].FECHA, 'string');
  assert.strictEqual(rows[1].FECHA, '2026-02-28');
});

test('un cero es cero, no null (no confundir "sin dato" con "vale 0")', function () {
  const rows = readAll(fixture('ceros.dbf')).rows;
  assert.strictEqual(rows[2].PRECIO, 0);
  assert.strictEqual(rows[1].STOCK, 0);
});

test('una fecha vacia es null, no una fecha invalida', function () {
  const rows = readAll(fixture('fecha-vacia.dbf')).rows;
  assert.strictEqual(rows[2].FECHA, null);
});

test('un campo de texto vacio es null', function () {
  const file = fixture('vacios.dbf', [
    { CODIGO: 'X', DESCRIP: '', PRECIO: 1, STOCK: 1, FECHA: '2026-01-01', ACTIVO: true },
  ]);
  assert.strictEqual(readAll(file).rows[0].DESCRIP, null);
});

test('omite los registros borrados salvo que se pidan explicitamente', function () {
  const file = fixture('borrados.dbf', ROWS, { deleted: [3] });

  const visible = readAll(file).rows;
  assert.strictEqual(visible.length, 3);
  assert.ok(!visible.some(function (r) { return r.CODIGO === 'ART004'; }));

  const all = readAll(file, { includeDeleted: true }).rows;
  assert.strictEqual(all.length, 4);
  assert.strictEqual(all[3].__deleted, true);
  assert.strictEqual(all[0].__deleted, false);
});

test('si el contador del header quedo desactualizado, manda el tamanio real del archivo', function () {
  // Un corte de luz en el comercio deja el header diciendo mas registros de los
  // que hay. Leer de mas devolveria basura como si fueran ventas.
  const file = fixture('header-roto.dbf', ROWS, { recordCountOverride: 9999 });
  const result = readAll(file);
  assert.strictEqual(result.table.headerRecordCount, 9999);
  assert.strictEqual(result.table.recordCount, 4);
  assert.strictEqual(result.rows.length, 4);
});

test('respeta limit y skip para poder leer por lotes sin cargar la tabla entera', function () {
  const file = fixture('lotes.dbf');
  const table = openDbf(file);
  try {
    assert.deepStrictEqual(
      Array.from(table.records({ limit: 2 })).map(function (r) { return r.CODIGO; }),
      ['ART001', 'ART002']
    );
    assert.deepStrictEqual(
      Array.from(table.records({ skip: 2, limit: 2 })).map(function (r) { return r.CODIGO; }),
      ['ART003', 'ART004']
    );
  } finally {
    table.close();
  }
});

test('expone __recno para poder rastrear una fila hasta el ERP', function () {
  const rows = readAll(fixture('recno.dbf')).rows;
  assert.deepStrictEqual(rows.map(function (r) { return r.__recno; }), [1, 2, 3, 4]);
});

test('NO modifica el archivo: mismo mtime y mismo tamanio despues de leer', function () {
  // Es la garantia central del proyecto: el ERP tiene que poder seguir operando.
  const file = fixture('intacto.dbf');
  const before = fs.statSync(file);

  readAll(file);

  const after = fs.statSync(file);
  assert.strictEqual(after.size, before.size);
  assert.strictEqual(after.mtimeMs, before.mtimeMs);
});

test('un archivo que no es DBF falla con un error claro, no con basura', function () {
  const file = path.join(tmp, 'no-es-dbf.dbf');
  fs.writeFileSync(file, 'esto no es una tabla');
  assert.throws(function () { openDbf(file); }, /Lectura incompleta/);
});

test('decode cae a latin1 si la pagina de codigo es desconocida, sin perder bytes', function () {
  const buf = Buffer.from([0x41, 0xe9]);
  assert.strictEqual(decode(buf, 'cp-inexistente'), 'A' + String.fromCharCode(0xe9));
});

test.after(function () {
  fs.rmSync(tmp, { recursive: true, force: true });
});
