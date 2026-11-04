// §9.1.1 file-name normalisation and media/SRT pairing. Works on plain path strings
// (both / and \ separators) so it runs in the renderer too.

export const VIDEO_EXT = ['mp4', 'mov', 'm4v'];
export const AUDIO_EXT = ['mp3', 'm4a', 'wav', 'aac'];
export const MEDIA_EXT = [...VIDEO_EXT, ...AUDIO_EXT];
export const SUB_EXT = ['srt'];
export const DEFAULT_SUFFIXES = ['_FeishuMinutes', '_Recording', '-Recording', ' Recording', '_Minutes', '_录制', '_录音'];

export function baseName(p) {
  const name = p.split(/[\\/]/).pop() || p;
  return name;
}

export function stem(p) {
  const name = baseName(p);
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(0, dot) : name;
}

export function extOf(p) {
  const name = baseName(p);
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : '';
}

export function dirOf(p) {
  const i = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
  return i >= 0 ? p.slice(0, i).toLowerCase() : '';
}

export function kindOf(p) {
  const e = extOf(p);
  if (VIDEO_EXT.includes(e)) return 'video';
  if (AUDIO_EXT.includes(e)) return 'audio';
  if (SUB_EXT.includes(e)) return 'subtitle';
  return 'other';
}

export const isMedia = (p) => ['video', 'audio'].includes(kindOf(p));
export const isSubtitle = (p) => kindOf(p) === 'subtitle';

/** Strip a leading 13-digit timestamp and known suffixes; also the default title (§9.6). */
export function normalizedTitle(base, suffixes = DEFAULT_SUFFIXES) {
  let s = base.trim().replace(/^\d{13}_/, '');
  let changed = true;
  while (changed) {
    changed = false;
    for (const suffix of suffixes) {
      if (suffix && s.length > suffix.length && s.toLowerCase().endsWith(suffix.toLowerCase())) {
        s = s.slice(0, s.length - suffix.length).trim();
        changed = true;
      }
    }
  }
  s = s.trim();
  return s || base.trim();
}

export function pairingKey(p, suffixes) {
  return normalizedTitle(stem(p), suffixes).toLowerCase();
}

/**
 * Returns `{ pairs: [{media, subtitle|null}], suggestions: [{media, subtitle}], unmatched: [srt] }`.
 * Suggestions: media without a name match whose folder holds exactly one unclaimed SRT.
 */
export function pairFiles(media, subtitles, suffixes = DEFAULT_SUFFIXES) {
  const byKey = new Map();
  for (const s of subtitles) {
    const k = pairingKey(s, suffixes);
    if (!byKey.has(k)) byKey.set(k, []);
    byKey.get(k).push(s);
  }
  const used = new Set();
  const pairs = [];
  const unmatchedMedia = [];
  for (const m of media) {
    const cand = (byKey.get(pairingKey(m, suffixes)) || []).find((s) => !used.has(s));
    if (cand) {
      used.add(cand);
      pairs.push({ media: m, subtitle: cand });
    } else {
      unmatchedMedia.push(m);
    }
  }
  const suggestions = [];
  for (const m of unmatchedMedia) {
    const folder = dirOf(m);
    const inFolder = subtitles.filter((s) => !used.has(s) && dirOf(s) === folder);
    if (inFolder.length === 1) {
      used.add(inFolder[0]);
      suggestions.push({ media: m, subtitle: inFolder[0] });
    } else {
      pairs.push({ media: m, subtitle: null });
    }
  }
  return { pairs, suggestions, unmatched: subtitles.filter((s) => !used.has(s)) };
}

/** `YYYY-MM-DD` (optionally `_HH-mm`) in a file name; without a time the fallback's time is kept. */
export function dateFromFileName(name, fallback = new Date()) {
  const m = /((?:19|20)\d{2})-(\d{1,2})-(\d{1,2})(?:[ _T](\d{1,2})[-:.](\d{2}))?/.exec(name);
  if (!m) return null;
  const y = +m[1];
  const mo = +m[2];
  const d = +m[3];
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  let h = fallback.getHours();
  let mi = fallback.getMinutes();
  if (m[4] != null && +m[4] < 24 && +m[5] < 60) {
    h = +m[4];
    mi = +m[5];
  }
  return new Date(y, mo - 1, d, h, mi);
}
