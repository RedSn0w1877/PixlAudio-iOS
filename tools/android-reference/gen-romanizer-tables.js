// Converts the romanisation tables of the Android LyricsUtils.kt into Swift (exact code units, \u{...} escapes).
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8').split(/\r?\n/);

function unescapeKotlin(s) {
  return s.replace(/\\u([0-9a-fA-F]{4})/g, (_, h) => String.fromCharCode(parseInt(h, 16)))
    .replace(/\\(["\\$])/g, '$1');
}
function swiftLit(s) {
  let out = '"';
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c >= 0x20 && c < 0x7f && s[i] !== '"' && s[i] !== '\\') out += s[i];
    else out += '\\u{' + c.toString(16).toUpperCase().padStart(4, '0') + '}';
  }
  return out + '"';
}
const strRe = '"((?:[^"\\\\]|\\\\.)*)"';
function pairs(line) {
  const re = new RegExp(strRe + '\\s+to\\s+' + strRe, 'g');
  const out = []; let m;
  while ((m = re.exec(line))) out.push([unescapeKotlin(m[1]), unescapeKotlin(m[2])]);
  return out;
}
function strings(line) {
  const re = new RegExp(strRe, 'g');
  const out = []; let m;
  while ((m = re.exec(line))) out.push(unescapeKotlin(m[1]));
  return out;
}
function findLine(name) {
  const i = src.findIndex(l => l.includes('private val ' + name + ' ='));
  if (i < 0) throw new Error(name);
  // a map may span several lines until the closing ")" at depth 0
  let text = '', depth = 0, j = i, started = false;
  for (; j < src.length; j++) {
    text += src[j] + '\n';
    for (const ch of src[j].replace(/"((?:[^"\\]|\\.)*)"/g, '""')) {
      if (ch === '(') { depth++; started = true; }
      if (ch === ')') depth--;
    }
    if (started && depth === 0) break;
  }
  return text;
}
function emitPairs(swiftName, list, doc) {
  let s = `    /// ${doc}\n    static let ${swiftName}: [(String, String)] = [\n`;
  for (const [k, v] of list) s += `        (${swiftLit(k)}, ${swiftLit(v)}),\n`;
  return s + '    ]\n';
}
function emitSet(swiftName, list, doc) {
  let s = `    /// ${doc}\n    static let ${swiftName}: [String] = [\n        `;
  s += list.map(swiftLit).join(', ');
  return s + ',\n    ]\n';
}

let out = `// Generated from the Android app's utils/LyricsUtils.kt (MultiLangRomanizer tables) by
// tools/android-reference/gen-romanizer-tables.js — do not edit by hand. Literals use \\u{...} escapes so every
// code unit is exactly the Android one (precomposed and decomposed forms are different keys there).

enum RomanizerTables {
`;
// Hangul nested map
const hangul = findLine('HANGUL_ROMAJA_MAP');
const parts = hangul.split(/"(cho|jung|jong)" to mapOf\(/).slice(1);
for (let i = 0; i < parts.length; i += 2) {
  out += emitPairs('hangul' + parts[i][0].toUpperCase() + parts[i].slice(1), pairs(parts[i + 1]), `HANGUL_ROMAJA_MAP["${parts[i]}"]`);
}
const maps = [
  ['DEVANAGARI_ROMAJI_MAP', 'devanagari'], ['GURMUKHI_ROMAJI_MAP', 'gurmukhi'],
  ['GENERAL_CYRILLIC_ROMAJI_MAP', 'generalCyrillic'], ['RUSSIAN_ROMAJI_MAP', 'russian'],
  ['UKRAINIAN_ROMAJI_MAP', 'ukrainian'], ['SERBIAN_ROMAJI_MAP', 'serbian'], ['BULGARIAN_ROMAJI_MAP', 'bulgarian'],
  ['BELARUSIAN_ROMAJI_MAP', 'belarusian'], ['KYRGYZ_ROMAJI_MAP', 'kyrgyz'], ['MACEDONIAN_ROMAJI_MAP', 'macedonian'],
];
for (const [k, n] of maps) out += emitPairs(n, pairs(findLine(k)), k);
const sets = [
  ['RUSSIAN_CYRILLIC_LETTERS', 'russianLetters'], ['UKRAINIAN_CYRILLIC_LETTERS', 'ukrainianLetters'],
  ['SERBIAN_CYRILLIC_LETTERS', 'serbianLetters'], ['BULGARIAN_CYRILLIC_LETTERS', 'bulgarianLetters'],
  ['BELARUSIAN_CYRILLIC_LETTERS', 'belarusianLetters'], ['KYRGYZ_CYRILLIC_LETTERS', 'kyrgyzLetters'],
  ['MACEDONIAN_CYRILLIC_LETTERS', 'macedonianLetters'],
  ['UKRAINIAN_SPECIFIC_CYRILLIC_LETTERS', 'ukrainianSpecific'], ['SERBIAN_SPECIFIC_CYRILLIC_LETTERS', 'serbianSpecific'],
  ['BELARUSIAN_SPECIFIC_CYRILLIC_LETTERS', 'belarusianSpecific'], ['KYRGYZ_SPECIFIC_CYRILLIC_LETTERS', 'kyrgyzSpecific'],
  ['MACEDONIAN_SPECIFIC_CYRILLIC_LETTERS', 'macedonianSpecific'],
];
for (const [k, n] of sets) out += emitSet(n, strings(findLine(k)), k);
// Polyphone overrides: 'X' to "pinyin"
const poly = findLine('POLYPHONE_OVERRIDE');
const polyPairs = []; let m; const pre = /'(.)' to "([a-z]+)"/g;
while ((m = pre.exec(poly))) polyPairs.push([m[1], m[2]]);
out += emitPairs('polyphoneOverride', polyPairs, 'POLYPHONE_OVERRIDE (character → preferred lyric reading)');
// Context map: 'P' to mapOf('C' to "pinyin")
const ctx = findLine('CONTEXT_PINYIN');
const cre = /'(.)' to mapOf\('(.)' to "([a-z]+)"\)/g;
let s = `    /// CONTEXT_PINYIN (previous character, character, reading)\n    static let contextPinyin: [(String, String, String)] = [\n`;
while ((m = cre.exec(ctx))) s += `        (${swiftLit(m[1])}, ${swiftLit(m[2])}, ${swiftLit(m[3])}),\n`;
out += s + '    ]\n';
out += '}\n';
fs.writeFileSync(process.argv[3], out);
console.log('ok', polyPairs.length);
