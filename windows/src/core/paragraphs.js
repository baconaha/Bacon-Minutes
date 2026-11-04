import { isCJK, isPunct, lastChar, firstChar, fnv1a } from './text.js';

export const MAX_GAP = 2.0;
export const MAX_CHARS = 250;

/** §9.3: same speaker, gap (next start − running max end) < 2 s and paragraph < 250 chars. */
export function buildParagraphs(cues) {
  const out = [];
  let cur = null;
  for (const cue of cues) {
    if (cur && cur.speakerID === cue.speakerID && cue.start - cur.end < MAX_GAP && cur.chars < MAX_CHARS) {
      cur.cueIDs.push(cue.id);
      cur.end = Math.max(cur.end, cue.end);
      cur.chars += Array.from(cue.text).length;
    } else {
      if (cur) out.push(cur);
      cur = { id: out.length, speakerID: cue.speakerID, cueIDs: [cue.id], start: cue.start, end: cue.end, chars: Array.from(cue.text).length };
    }
  }
  if (cur) out.push(cur);
  return out.map(({ chars, ...p }) => p);
}

/** Glue between two cues of one paragraph. */
export function separator(previous, next, insertComma) {
  const last = lastChar(previous);
  const first = firstChar(next);
  if (!last || !first) return '';
  if (isCJK(last) || isCJK(first)) {
    if (insertComma && !isPunct(last) && !isPunct(first)) return '，';
    return '';
  }
  if (last === ' ' || first === ' ') return '';
  return ' ';
}

export function paragraphText(p, cues, insertComma) {
  let out = '';
  let prev = null;
  for (const id of p.cueIDs) {
    const t = cues[id].text;
    if (!t) continue;
    if (prev != null) out += separator(prev, t, insertComma);
    out += t;
    prev = t;
  }
  return out;
}

/** Time → cue lookups over start-sorted cues (overlaps allowed). */
export class CueTimeline {
  constructor(cues) {
    this.starts = cues.map((c) => c.start);
    this.ends = cues.map((c) => c.end);
    this.prefixMaxEnd = [];
    let running = -Infinity;
    for (const c of cues) {
      running = Math.max(running, c.end);
      this.prefixMaxEnd.push(running);
    }
  }

  get isEmpty() {
    return this.starts.length === 0;
  }

  lastStartIndex(t) {
    let lo = 0;
    let hi = this.starts.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (this.starts[mid] <= t) lo = mid + 1;
      else hi = mid;
    }
    return lo === 0 ? -1 : lo - 1;
  }

  /** §5.3: last cue with start ≤ t < end; -1 inside a gap. */
  activeCue(t) {
    let i = this.lastStartIndex(t);
    while (i >= 0) {
      if (this.prefixMaxEnd[i] <= t) return -1;
      if (this.ends[i] > t) return i;
      i--;
    }
    return -1;
  }

  /** §3.4: start of the next cue when t sits in a gap of at least `threshold` seconds. */
  skipTarget(t, threshold) {
    const i = this.lastStartIndex(t);
    let gapStart = 0;
    let next = 0;
    if (i >= 0) {
      if (this.prefixMaxEnd[i] > t) return null;
      gapStart = this.prefixMaxEnd[i];
      next = i + 1;
    }
    if (next >= this.starts.length) return null;
    const target = this.starts[next];
    if (target - gapStart < threshold || target - t <= 0.05) return null;
    return target;
  }
}

export function speakerPercentages(cues) {
  const per = new Map();
  let total = 0;
  for (const c of cues) {
    const d = Math.max(0, c.end - c.start);
    per.set(c.speakerID, (per.get(c.speakerID) || 0) + d);
    total += d;
  }
  const out = {};
  for (const [k, v] of per) out[k] = total > 0 ? Math.round((v / total) * 100) : 0;
  return out;
}

/** Merged speaking intervals of one speaker, for the speaker track. */
export function speakerIntervals(cues, speakerID, mergeGap = 0.3) {
  const out = [];
  for (const c of cues) {
    if (c.speakerID !== speakerID || c.end <= c.start) continue;
    const last = out[out.length - 1];
    if (last && c.start <= last[1] + mergeGap) last[1] = Math.max(last[1], c.end);
    else out.push([c.start, c.end]);
  }
  return out;
}

/** Fingerprint of everything the summary depends on (text, timing, speaker names). */
export function transcriptHash(transcript) {
  const names = new Map(transcript.speakers.map((s) => [s.id, s.name]));
  let s = '';
  for (const c of transcript.cues) {
    s += `${names.get(c.speakerID) ?? c.speakerID}|${Math.round(c.start * 1000)}|${Math.round(c.end * 1000)}|${c.text}\n`;
  }
  return fnv1a(s);
}

export function speakerName(transcript, id) {
  return transcript?.speakers.find((s) => s.id === id)?.name ?? id;
}
