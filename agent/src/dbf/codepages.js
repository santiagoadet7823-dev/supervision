'use strict';

/**
 * Decodificación de las páginas de código que usan los DBF de FoxPro.
 *
 * Node no trae cp850 ni cp437, y los ERP de FoxPro en Argentina suelen estar en
 * una de esas dos (DOS) o en cp1252 (Windows). Si decodificamos mal, "Ñandú" o
 * "Café" llegan rotos a la nube y ya no hay forma de recuperarlos.
 */

// Mitad alta (0x80-0xFF) de cada página. La mitad baja es ASCII en todas.
const HIGH_HALF = {
  cp850:
    'ÇüéâäàåçêëèïîìÄÅ' +
    'ÉæÆôöòûùÿÖÜø£Ø×ƒ' +
    'áíóúñÑªº¿®¬½¼¡«»' +
    '░▒▓│┤ÁÂÀ©╣║╗╝¢¥┐' +
    '└┴┬├─┼ãÃ╚╔╩╦╠═╬¤' +
    'ðÐÊËÈıÍÎÏ┘┌█▄¦Ì▀' +
    'ÓßÔÒõÕµþÞÚÛÙýÝ¯´' +
    '­±‗¾¶§÷¸°¨·¹³²■ ',
  cp437:
    'ÇüéâäàåçêëèïîìÄÅ' +
    'ÉæÆôöòûùÿÖÜ¢£¥₧ƒ' +
    'áíóúñÑªº¿⌐¬½¼¡«»' +
    '░▒▓│┤╡╢╖╕╣║╗╝╜╛┐' +
    '└┴┬├─┼╞╟╚╔╩╦╠═╬╧' +
    '╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀' +
    'αßΓπΣσµτΦΘΩδ∞φε∩' +
    '≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ ',
};

// Byte 29 del header del DBF: identificador de página de código.
const LANGUAGE_DRIVER = {
  0x01: 'cp437',
  0x02: 'cp850',
  0x03: 'cp1252',
  0x64: 'cp852',
  0x65: 'cp866',
  0x6a: 'cp737',
  0x6b: 'cp857',
  0xc8: 'cp1250',
  0xc9: 'cp1251',
  0xca: 'cp1254',
  0xcb: 'cp1253',
};

const tables = new Map();

function tableFor(encoding) {
  if (tables.has(encoding)) return tables.get(encoding);
  const high = HIGH_HALF[encoding];
  if (!high) return null;
  const map = new Array(256);
  for (let i = 0; i < 128; i++) map[i] = String.fromCharCode(i);
  for (let i = 0; i < 128; i++) map[128 + i] = high[i];
  tables.set(encoding, map);
  return map;
}

/** Nombre de la página de código a partir del byte 29 del header. */
function encodingFromLanguageDriver(byte) {
  return LANGUAGE_DRIVER[byte] || null;
}

/**
 * Decodifica un buffer con la página de código indicada.
 * cp1252 y latin1 caen en el decoder nativo de Node; el resto usa tabla propia.
 */
function decode(buffer, encoding = 'cp1252') {
  if (encoding === 'cp1252' || encoding === 'latin1') {
    return buffer.toString('latin1');
  }
  if (encoding === 'utf8') return buffer.toString('utf8');

  const map = tableFor(encoding);
  if (!map) return buffer.toString('latin1'); // desconocida: latin1 no pierde bytes

  let out = '';
  for (let i = 0; i < buffer.length; i++) out += map[buffer[i]];
  return out;
}

module.exports = { decode, encodingFromLanguageDriver, LANGUAGE_DRIVER, HIGH_HALF };
