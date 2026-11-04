// Builds src/i18n/generated.json: the Mac app's Localizable.strings tables (shared UI text)
// plus src/i18n/windows.json (text only the Windows app has). Chinese text is the key.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const LANGS = ['en', 'ja', 'ko', 'es', 'vi', 'fr', 'pt', 'ru'];

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const macResources = join(root, '..', 'App', 'Resources');

function unescape(s) {
  return s.replace(/\\(.)/g, (_, c) => ({ n: '\n', t: '\t', '"': '"', '\\': '\\' })[c] ?? c);
}

/** Parses an old-style `"key" = "value";` .strings file. */
export function parseStrings(text) {
  const body = text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
  const entry = /"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;/g;
  const out = {};
  let m;
  while ((m = entry.exec(body))) out[unescape(m[1])] = unescape(m[2]);
  return out;
}

export function buildTables() {
  const extra = JSON.parse(readFileSync(join(root, 'src/i18n/windows.json'), 'utf8'));
  const tables = {};
  for (const lang of LANGS) {
    const file = join(macResources, `${lang}.lproj`, 'Localizable.strings');
    if (!existsSync(file)) throw new Error(`missing ${file}`);
    tables[lang] = parseStrings(readFileSync(file, 'utf8'));
  }
  for (const [key, row] of Object.entries(extra)) {
    for (const lang of LANGS) {
      if (row[lang] != null) tables[lang][key] = row[lang];
    }
  }
  return tables;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const tables = buildTables();
  writeFileSync(join(root, 'src/i18n/generated.json'), JSON.stringify(tables));
  console.log('i18n:', Object.keys(tables.en).length, 'keys');
}
