// §9.6 time and date formats, following the UI language.
import { language, localeTag } from './i18n.js';

const pad2 = (n) => (n < 10 ? '0' + n : '' + n);

function whole(t) {
  return Number.isFinite(t) && t > 0 ? Math.floor(t) : 0;
}

export function usesHours(totalDuration) {
  return totalDuration >= 3600;
}

/** `mm:ss`, or `hh:mm:ss` when the media is an hour or longer. */
export function timestamp(t, hours) {
  const total = whole(t);
  const s = total % 60;
  if (hours) return `${pad2(Math.floor(total / 3600))}:${pad2(Math.floor((total % 3600) / 60))}:${pad2(s)}`;
  return `${pad2(Math.floor(total / 60))}:${pad2(s)}`;
}

// Hour / minute / second words, the gap between number and unit, and the gap between parts.
const UNITS = {
  'zh-Hans': ['小时', '分', '秒', ' ', ' '],
  en: ['h', 'm', 's', '', ' '],
  ja: ['時間', '分', '秒', '', ''],
  ko: ['시간', '분', '초', '', ' '],
  es: ['h', 'min', 's', ' ', ' '],
  pt: ['h', 'min', 's', ' ', ' '],
  fr: ['h', 'min', 's', ' ', ' '],
  vi: ['giờ', 'phút', 'giây', ' ', ' '],
  ru: ['ч', 'мин', 'с', ' ', ' '],
};

/** `1 小时 34 分 43 秒` / `1h 34m 43s`; zero units are left out. */
export function duration(seconds, lang = language()) {
  const [uh, um, us, gap, joiner] = UNITS[lang] || UNITS.en;
  const total = Number.isFinite(seconds) && seconds > 0 ? Math.round(seconds) : 0;
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const parts = [];
  if (h > 0) parts.push(`${h}${gap}${uh}`);
  if (m > 0) parts.push(`${m}${gap}${um}`);
  if (s > 0 || parts.length === 0) parts.push(`${s}${gap}${us}`);
  return parts.join(joiner);
}

/** Hours and minutes only once a total reaches an hour (`12 小时 5 分`), for library totals. */
export function roughDuration(seconds, lang = language()) {
  const total = Number.isFinite(seconds) && seconds > 0 ? Math.round(seconds) : 0;
  if (total < 3600) return duration(seconds, lang);
  const [uh, um, , gap, joiner] = UNITS[lang] || UNITS.en;
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const parts = [`${h}${gap}${uh}`];
  if (m > 0) parts.push(`${m}${gap}${um}`);
  return parts.join(joiner);
}

/** Old name, kept for the tests and callers that predate localization. */
export const durationCN = duration;

/** `1:34:43` / `3:27` */
export function compactDuration(seconds) {
  const total = Number.isFinite(seconds) && seconds > 0 ? Math.round(seconds) : 0;
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h > 0 ? `${h}:${pad2(m)}:${pad2(s)}` : `${m}:${pad2(s)}`;
}

/** `HH:MM:SS,mmm` */
export function srtTimestamp(t) {
  const ms = Number.isFinite(t) && t > 0 ? Math.round(t * 1000) : 0;
  const h = Math.floor(ms / 3600000);
  const m = Math.floor((ms % 3600000) / 60000);
  const s = Math.floor((ms % 60000) / 1000);
  const milli = String(ms % 1000).padStart(3, '0');
  return `${pad2(h)}:${pad2(m)}:${pad2(s)},${milli}`;
}

const formatters = new Map();
function intl(withTime) {
  const lang = language();
  const key = lang + withTime;
  if (!formatters.has(key)) {
    const opts = { year: 'numeric', month: 'short', day: 'numeric' };
    if (withTime) Object.assign(opts, { hour: 'numeric', minute: '2-digit' });
    formatters.set(key, new Intl.DateTimeFormat(localeTag(lang), opts));
  }
  return formatters.get(key);
}

/** `2026年10月13日 下午4:00` / `Oct 13, 2026, 4:00 PM` */
export function createdDate(date) {
  const d = date instanceof Date ? date : new Date(date);
  if (language() !== 'zh-Hans') return intl(true).format(d);
  const h = d.getHours();
  const ampm = h < 12 ? '上午' : '下午';
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日 ${ampm}${h12}:${pad2(d.getMinutes())}`;
}

/** `2026年10月13日` / `Oct 13, 2026` */
export function dateOnly(date) {
  const d = date instanceof Date ? date : new Date(date);
  if (language() !== 'zh-Hans') return intl(false).format(d);
  return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`;
}

/** Parses `mm:ss`, `hh:mm:ss`, `[mm:ss]`, fractional seconds, or plain seconds. */
export function parseTimestamp(raw) {
  if (typeof raw === 'number') return Number.isFinite(raw) && raw >= 0 ? raw : null;
  if (typeof raw !== 'string') return null;
  let s = raw.trim().replace(/^[\[【(（\s]+|[\]】)）\s]+$/g, '').replace(/：/g, ':');
  if (!s) return null;
  const parts = s.split(':').map((p) => p.trim());
  const num = (p) => (/^\d+(?:[.,]\d+)?$/.test(p) ? parseFloat(p.replace(',', '.')) : NaN);
  if (parts.length === 1) {
    const v = num(parts[0]);
    return Number.isNaN(v) ? null : v;
  }
  if (parts.length === 2) {
    const [m, sec] = parts.map(num);
    return Number.isNaN(m) || Number.isNaN(sec) ? null : m * 60 + sec;
  }
  if (parts.length === 3) {
    const [h, m, sec] = parts.map(num);
    return [h, m, sec].some(Number.isNaN) ? null : h * 3600 + m * 60 + sec;
  }
  return null;
}
