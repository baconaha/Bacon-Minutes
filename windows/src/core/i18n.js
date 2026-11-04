// UI languages. The Chinese text in the code is the lookup key; the other languages come from
// the Mac app's Localizable.strings plus src/i18n/windows.json, merged by scripts/i18n.mjs.
import TABLES from '../i18n/generated.json' with { type: 'json' };

export const LANGUAGES = [
  { id: 'zh-Hans', name: '简体中文' },
  { id: 'en', name: 'English' },
  { id: 'ja', name: '日本語' },
  { id: 'ko', name: '한국어' },
  { id: 'es', name: 'Español' },
  { id: 'vi', name: 'Tiếng Việt' },
  { id: 'fr', name: 'Français' },
  { id: 'pt', name: 'Português' },
  { id: 'ru', name: 'Русский' },
];

let current = 'zh-Hans';
// The renderer swaps this for a signal read, so components re-render when the language changes.
let reader = () => current;

export function setLanguage(id) {
  current = LANGUAGES.some((l) => l.id === id) ? id : 'en';
}

export function setLanguageReader(fn) {
  reader = fn;
}

export function language() {
  return reader();
}

export const languageName = (id) => LANGUAGES.find((l) => l.id === id)?.name || id;

/** First supported language in a preference list (e.g. navigator.languages), else English. */
export function bestLanguage(ids) {
  for (const raw of ids || []) {
    const id = String(raw).toLowerCase().replace(/_/g, '-');
    if (id === 'zh' || id.startsWith('zh-')) return 'zh-Hans';
    for (const l of LANGUAGES) {
      if (l.id !== 'zh-Hans' && (id === l.id || id.startsWith(l.id + '-'))) return l.id;
    }
  }
  return 'en';
}

function lookup(key, lang) {
  if (lang !== 'zh-Hans') {
    const v = TABLES[lang]?.[key];
    if (v != null) return v;
  }
  // A key may end in "@@context" to tell apart identical Chinese text; the suffix is never shown.
  const i = key.indexOf('@@');
  return i >= 0 ? key.slice(0, i) : key;
}

function fill(template, args) {
  if (!args.length) return template;
  return template.replace(/\{(\d+)\}/g, (m, i) => (args[i] !== undefined ? String(args[i]) : m));
}

/** UI text in the current language; `{0}`, `{1}` … take `args`. */
export function L(key, ...args) {
  return fill(lookup(key, reader()), args);
}

/** UI text in a given language. */
export function Lin(lang, key, ...args) {
  return fill(lookup(key, lang), args);
}

export const listSeparator = (lang = reader()) => (lang === 'zh-Hans' || lang === 'ja' ? '、' : ', ');

/** BCP 47 tag for Intl formatters. */
export const localeTag = (lang = reader()) => (lang === 'zh-Hans' ? 'zh-CN' : lang === 'pt' ? 'pt-BR' : lang);
