// §9.6 time and date formats.

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

/** `1 小时 34 分 43 秒`; zero units are left out. */
export function durationCN(seconds) {
  const total = Number.isFinite(seconds) && seconds > 0 ? Math.round(seconds) : 0;
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const parts = [];
  if (h > 0) parts.push(`${h} 小时`);
  if (m > 0) parts.push(`${m} 分`);
  if (s > 0 || parts.length === 0) parts.push(`${s} 秒`);
  return parts.join(' ');
}

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

/** `2026年10月13日 下午4:00` */
export function createdDate(date) {
  const d = date instanceof Date ? date : new Date(date);
  const h = d.getHours();
  const ampm = h < 12 ? '上午' : '下午';
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日 ${ampm}${h12}:${pad2(d.getMinutes())}`;
}

/** `2026年10月13日` */
export function dateOnly(date) {
  const d = date instanceof Date ? date : new Date(date);
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
