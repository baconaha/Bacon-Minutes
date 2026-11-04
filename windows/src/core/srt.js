// §9.2 SRT reader: tolerant of encodings, odd sequence numbers, blank-line noise, tags,
// overlapping and very short cues.
import { joinFragment } from './text.js';

export const FALLBACK_SPEAKER = '说话人 1';
export const SPEAKER_COLORS = ['#3370FF', '#F5A623', '#2EA121', '#7B61FF', '#F54A45', '#14A9D9', '#FF8800', '#D136D1'];

export function speakerColor(i) {
  return SPEAKER_COLORS[((i % SPEAKER_COLORS.length) + SPEAKER_COLORS.length) % SPEAKER_COLORS.length];
}

// ---------- decoding ----------

function tryDecode(bytes, label, fatal) {
  try {
    return new TextDecoder(label, { fatal }).decode(bytes);
  } catch {
    return null;
  }
}

function guessBOMlessUTF16(bytes) {
  const n = Math.min(bytes.length, 2000);
  if (n < 16) return null;
  let even = 0;
  let odd = 0;
  for (let i = 0; i < n; i++) {
    if (bytes[i] === 0) {
      if (i % 2 === 0) even++;
      else odd++;
    }
  }
  const half = n / 2;
  if (odd > half * 0.3 && even < odd / 4) return 'utf-16le';
  if (even > half * 0.3 && odd < even / 4) return 'utf-16be';
  return null;
}

/** UTF-8 (with BOM), UTF-16 (with or without BOM), then GB18030. */
export function decodeSRT(input) {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) return tryDecode(bytes.subarray(3), 'utf-8', false);
  if (bytes[0] === 0xff && bytes[1] === 0xfe) return tryDecode(bytes.subarray(2), 'utf-16le', false);
  if (bytes[0] === 0xfe && bytes[1] === 0xff) return tryDecode(bytes.subarray(2), 'utf-16be', false);
  const u16 = guessBOMlessUTF16(bytes);
  if (u16) {
    const s = tryDecode(bytes, u16, false);
    if (s != null) return s;
  }
  const utf8 = tryDecode(bytes, 'utf-8', true);
  if (utf8 != null) return utf8;
  const gb = tryDecode(bytes, 'gb18030', true);
  if (gb != null) return gb;
  return tryDecode(bytes, 'utf-8', false) ?? '';
}

// ---------- parsing ----------

const TIME_LINE =
  /^\s*(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[,.](\d{1,3}))?\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{1,2})(?:[,.](\d{1,3}))?/;
const TAGS = /<[^>]*>/g;
const ASS = /\{\\[^}]*\}/g;

export function parseTimeLine(line) {
  const m = TIME_LINE.exec(line);
  if (!m) return null;
  const sec = (h, mm, s, f) =>
    (parseInt(h || '0', 10) * 3600) + parseInt(mm || '0', 10) * 60 + parseInt(s || '0', 10) + (f ? parseFloat('0.' + f) : 0);
  return [sec(m[1], m[2], m[3], m[4]), sec(m[5], m[6], m[7], m[8])];
}

const isBlank = (s) => s.trim() === '';
const isIndexLine = (s) => /^\d+$/.test(s.trim());

function trimTrailingBlank(lines) {
  const out = lines.slice();
  while (out.length && isBlank(out[out.length - 1])) out.pop();
  return out;
}

/** Lines gathered before the next time line may end with that cue's sequence number. */
function dropTrailingIndex(lines) {
  let out = trimTrailingBlank(lines);
  if (out.length >= 2 && isIndexLine(out[out.length - 1])) {
    out.pop();
    out = trimTrailingBlank(out);
  }
  return out;
}

export function cleanLine(line) {
  let s = line.replace(TAGS, '').replace(ASS, '');
  if (s.includes('&')) {
    s = s
      .replace(/&nbsp;/g, ' ')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&amp;/g, '&');
  }
  return s.trim();
}

export function joinTextLines(lines) {
  let out = '';
  for (const raw of lines) {
    const line = cleanLine(raw);
    if (line) out = joinFragment(out, line);
  }
  return out;
}

// ---------- speaker prefixes ----------

const FEISHU = /^\s*说话人\s*(\d+)\s*[:：]\s*/;
const ENGLISH = /^\s*speaker\s*(\d+)\s*[:：]\s*/i;
const COLON = /^\s*([^\s:：][^:：\n]{0,19}?)\s*[:：]\s*/;
const BRACKET = /^\s*\[([^\[\]\n]{1,20})\]\s*/;
const DASH = /^\s*([^\s-][^-\n]{0,19}?)\s+-\s+/;
const FORBIDDEN = new Set(Array.from('，。,.!！?？;；、…"“”\'‘’()（）《》<>/\\|=+*#@&%$^~`{}【】「」『』'));

function isValidName(name) {
  const t = name.trim();
  const chars = Array.from(t);
  if (chars.length === 0 || chars.length > 20) return false;
  if (chars.some((c) => FORBIDDEN.has(c))) return false;
  if (/^[\d\s]+$/.test(t)) return false;
  return true;
}

/** `{ id, remainder, generic }` or null. Generic (free-form) names need corroboration. */
export function detectSpeaker(text) {
  let m = FEISHU.exec(text);
  if (m) return { id: `说话人 ${parseInt(m[1], 10)}`, remainder: text.slice(m[0].length).trim(), generic: false };
  m = ENGLISH.exec(text);
  if (m) return { id: `Speaker ${parseInt(m[1], 10)}`, remainder: text.slice(m[0].length).trim(), generic: false };
  m = BRACKET.exec(text);
  if (m && isValidName(m[1])) return { id: m[1].trim(), remainder: text.slice(m[0].length).trim(), generic: true };
  m = COLON.exec(text);
  if (m && isValidName(m[1])) {
    const rest = text.slice(m[0].length).trim();
    if (!rest.startsWith('//')) return { id: m[1].trim(), remainder: rest, generic: true };
  }
  m = DASH.exec(text);
  if (m && isValidName(m[1])) return { id: m[1].trim(), remainder: text.slice(m[0].length).trim(), generic: true };
  return null;
}

export class SRTParseError extends Error {}

/**
 * Returns `{ cues, speakers }`. Cues are sorted by start; `cue.id` equals the index.
 * Overlapping and very short cues are kept as they are.
 */
export function parseSRT(input) {
  let text = typeof input === 'string' ? input : decodeSRT(input);
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  const lines = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');

  const raws = [];
  let current = null;
  for (const line of lines) {
    const times = line.includes('-->') ? parseTimeLine(line) : null;
    if (times) {
      if (current) {
        current.lines = dropTrailingIndex(current.lines);
        raws.push(current);
      }
      current = { start: times[0], end: times[1], lines: [] };
    } else if (current) {
      current.lines.push(line);
    }
  }
  if (current) {
    current.lines = trimTrailingBlank(current.lines);
    raws.push(current);
  }
  if (raws.length === 0) {
    throw new SRTParseError('文件中没有可识别的字幕条目（需要形如 00:00:01,000 --> 00:00:02,000 的时间行）');
  }

  const pending = raws.map((r) => {
    const content = joinTextLines(r.lines);
    return { start: r.start, end: Math.max(r.start, r.end), text: content, cand: detectSpeaker(content) };
  });

  // Free-form "name:" prefixes only count when the same name appears at least twice.
  const counts = new Map();
  for (const p of pending) if (p.cand?.generic) counts.set(p.cand.id, (counts.get(p.cand.id) || 0) + 1);
  const allowSingletons = pending.length <= 2;
  for (const p of pending) {
    if (!p.cand) continue;
    if (p.cand.generic && !allowSingletons && (counts.get(p.cand.id) || 0) < 2) p.cand = null;
    else p.text = p.cand.remainder;
  }

  const order = pending.map((_, i) => i).sort((a, b) => pending[a].start - pending[b].start || a - b);
  const cues = [];
  const speakerOrder = [];
  const seen = new Set();
  order.forEach((oldIndex, newIndex) => {
    const p = pending[oldIndex];
    const speakerID = p.cand ? p.cand.id : FALLBACK_SPEAKER;
    if (!seen.has(speakerID)) {
      seen.add(speakerID);
      speakerOrder.push(speakerID);
    }
    cues.push({ id: newIndex, start: p.start, end: p.end, text: p.text, speakerID });
  });
  const speakers = speakerOrder.map((id, i) => ({ id, name: id, colorHex: speakerColor(i) }));
  return { cues, speakers };
}
