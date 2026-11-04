// §7.5 summary generation: input lines, chunking, JSON extraction, validation.
import { SYSTEM_PROMPT, JSON_RETRY_SUFFIX, userPrompt, mergePrompt } from './prompts.js';
import { errors } from './llm.js';
import { timestamp, usesHours, durationCN, parseTimestamp } from './time.js';
import { paragraphText, speakerName } from './paragraphs.js';
import { fold, containsFolded } from './text.js';

export function stripThinking(s) {
  const close = s.lastIndexOf('</think>');
  if (close !== -1) return s.slice(close + '</think>'.length);
  const open = s.indexOf('<think>');
  if (open !== -1) return s.slice(0, open);
  return s;
}

export function extractJSONObject(s) {
  const t = stripThinking(s).replace(/```json/gi, '').replace(/```/g, '');
  const first = t.indexOf('{');
  const last = t.lastIndexOf('}');
  if (first === -1 || last <= first) return null;
  return t.slice(first, last + 1);
}

const str = (x) => (typeof x === 'string' ? x.trim() : typeof x === 'number' ? String(x) : '');
const time = (x) => (x == null ? null : parseTimestamp(typeof x === 'number' ? x : String(x)));

/** Lenient parse; returns `{ summary, json }` or null. */
export function parseSummary(text) {
  const json = extractJSONObject(text);
  if (!json) return null;
  let obj;
  try {
    obj = JSON.parse(json);
  } catch {
    return null;
  }
  if (!obj || typeof obj !== 'object') return null;
  const r = { overview: str(obj.overview ?? obj.summary), keyPoints: [], todos: [], chapters: [], keywords: [] };
  for (const item of obj.key_points ?? obj.keyPoints ?? []) {
    if (item && typeof item === 'object') {
      const title = str(item.title);
      const content = str(item.content ?? item.description);
      if (title || content) r.keyPoints.push({ title, content });
    } else if (typeof item === 'string' && item.trim()) {
      const i = item.indexOf('：');
      r.keyPoints.push(i > 0 ? { title: item.slice(0, i).trim(), content: item.slice(i + 1).trim() } : { title: '', content: item.trim() });
    }
  }
  for (const item of obj.todos ?? []) {
    if (item && typeof item === 'object') {
      const content = str(item.content ?? item.task);
      if (content) r.todos.push({ content, owner: str(item.owner), time: time(item.time) });
    } else if (typeof item === 'string' && item.trim()) {
      r.todos.push({ content: item.trim(), owner: '', time: null });
    }
  }
  for (const item of obj.chapters ?? []) {
    if (!item || typeof item !== 'object') continue;
    const title = str(item.title);
    if (title) r.chapters.push({ time: time(item.time ?? item.start), title, summary: str(item.summary ?? item.content) });
  }
  if (Array.isArray(obj.keywords)) r.keywords = obj.keywords.map(str).filter(Boolean);
  else if (typeof obj.keywords === 'string') r.keywords = obj.keywords.split(/[，,、;；]/).map((s) => s.trim()).filter(Boolean);
  if (!r.overview && !r.keyPoints.length && !r.chapters.length) return null;
  return { summary: r, json };
}

/** Paragraph-level lines `[mm:ss] 名字：文本` (§7.5). */
export function buildSummaryInput({ title, duration, transcript, paragraphs, insertComma, language }) {
  const total = duration > 0 ? duration : Math.max(0, ...transcript.cues.map((c) => c.end));
  const hours = usesHours(total);
  const lines = [];
  const lineStarts = [];
  let full = '';
  for (const p of paragraphs) {
    const body = paragraphText(p, transcript.cues, insertComma);
    if (!body.trim()) continue;
    lines.push(`[${timestamp(p.start, hours)}] ${speakerName(transcript, p.speakerID)}：${body}`);
    lineStarts.push(p.start);
    full += body + '\n';
  }
  const used = new Set(paragraphs.map((p) => p.speakerID));
  const speakerNames = transcript.speakers.filter((s) => used.has(s.id)).map((s) => s.name);
  return { title, duration: total, speakerNames, lines, lineStarts, foldedFullText: fold(full), language };
}

/** Splits at paragraph boundaries so each chunk stays within `maxChars`. */
export function chunkLines(lines, maxChars) {
  if (!lines.length) return [];
  const limit = Math.max(1000, maxChars);
  const ranges = [];
  let start = 0;
  let count = 0;
  lines.forEach((line, i) => {
    const len = Array.from(line).length + 1;
    if (count > 0 && count + len > limit) {
      ranges.push([start, i]);
      start = i;
      count = 0;
    }
    count += len;
  });
  ranges.push([start, lines.length]);
  return ranges;
}

/** Largest paragraph start whose displayed (floored) second ≤ t; the first start if earlier. */
export function snap(t, starts) {
  if (!starts.length) return Math.max(0, t ?? 0);
  if (t == null) return starts[0];
  let lo = 0;
  let hi = starts.length;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (Math.floor(starts[mid]) <= t + 0.001) lo = mid + 1;
    else hi = mid;
  }
  return lo === 0 ? starts[0] : starts[lo - 1];
}

function dedupeByTime(chapters) {
  const out = [];
  for (const c of chapters) {
    const last = out[out.length - 1];
    if (last && Math.abs(last.time - c.time) < 0.001) continue;
    out.push(c);
  }
  return out;
}

/** §7.5 validation. */
export function validateSummary(raw, input) {
  const starts = input.lineStarts;
  let chapters = raw.chapters
    .map((c, i) => ({ c: { time: snap(c.time, starts), title: c.title, summary: c.summary }, i }))
    .sort((a, b) => a.c.time - b.c.time || a.i - b.i)
    .map((x) => x.c);
  chapters = dedupeByTime(chapters);
  if (starts.length && chapters.length) {
    chapters[0].time = starts[0];
    chapters = dedupeByTime(chapters);
  }
  const todos = raw.todos.map((t) => ({ content: t.content, owner: t.owner || '未指定', time: snap(t.time, starts) }));
  const seen = new Set();
  const keywords = [];
  for (const k of raw.keywords) {
    const key = k.toLowerCase();
    if (seen.has(key) || !containsFolded(input.foldedFullText, k)) continue;
    seen.add(key);
    keywords.push(k);
  }
  return {
    overview: raw.overview,
    keyPoints: raw.keyPoints.filter((k) => k.title || k.content),
    todos,
    chapters,
    keywords: keywords.slice(0, 12),
  };
}

/**
 * Runs the whole generation. `progress({type:'single'|'part'|'merging', i, n})`.
 * Returns the validated draft.
 */
export async function generateSummary({ client, input, config, apiKey, signal, progress = () => {} }) {
  if (!input.lines.length) throw errors.notConfigured('文字记录为空，无法生成纪要');
  const durationText = durationCN(input.duration);
  const chunks = chunkLines(input.lines, config.maxInputChars);

  const callJSON = async (user) => {
    let prompt = user;
    for (let attempt = 0; ; attempt++) {
      const res = await client.complete({ system: SYSTEM_PROMPT, user: prompt, maxTokens: config.maxOutputTokens, jsonMode: true }, config, apiKey, signal);
      const parsed = parseSummary(res.text);
      if (parsed) return parsed;
      if (res.truncated) throw errors.truncated();
      if (attempt >= 1) {
        if (!res.text.trim()) throw errors.empty();
        throw errors.invalidJSON(res.text.trim().slice(0, 300));
      }
      prompt = user + JSON_RETRY_SUFFIX;
    }
  };

  const base = { language: input.language, title: input.title, durationText, speakers: input.speakerNames };
  if (chunks.length <= 1) {
    progress({ type: 'single' });
    const r = await callJSON(userPrompt({ ...base, lines: input.lines }));
    return validateSummary(r.summary, input);
  }
  const partials = [];
  for (let i = 0; i < chunks.length; i++) {
    if (signal?.aborted) throw errors.cancelled();
    progress({ type: 'part', i: i + 1, n: chunks.length });
    const [a, b] = chunks[i];
    const r = await callJSON(userPrompt({ ...base, lines: input.lines.slice(a, b), part: [i + 1, chunks.length] }));
    partials.push(r.json);
  }
  if (signal?.aborted) throw errors.cancelled();
  progress({ type: 'merging' });
  const merged = await callJSON(mergePrompt(input.language, partials));
  return validateSummary(merged.summary, input);
}
