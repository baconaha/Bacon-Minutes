// `.baconsummary`: one summary plus what it was made from (recording, subtitles, model and
// request parameters). Plain JSON, identical to the Mac app's SummaryFile, so files move between
// both apps.
import { L } from './i18n.js';
import { duration } from './time.js';
import { cuesHash } from './paragraphs.js';

export const SUMMARY_FORMAT = 'bacon-minutes-summary';
export const SUMMARY_FILE_EXT = 'baconsummary';
export const SUMMARY_FILE_VERSION = 1;

/** ISO 8601 without milliseconds, as the Mac app writes it (it reads both forms). */
const iso = (d) => {
  if (!d) return null;
  const date = d instanceof Date ? d : new Date(d);
  return Number.isNaN(date.getTime()) ? null : date.toISOString().replace(/\.\d{3}Z$/, 'Z');
};

const content = (s) => ({
  overview: s.overview || '',
  keyPoints: (s.keyPoints || []).map((k) => ({ title: k.title || '', content: k.content || '' })),
  todos: (s.todos || []).map((t) => ({ content: t.content || '', owner: t.owner || '', time: Number(t.time) || 0 })),
  chapters: (s.chapters || []).map((c) => ({ time: Number(c.time) || 0, title: c.title || '', summary: c.summary || '' })),
  keywords: (s.keywords || []).map(String),
});

export function makeSummaryFile({ summary, minute, transcript, app, exportedAt = new Date() }) {
  const source = {
    title: minute.title || '',
    createdAt: iso(minute.createdAt),
    duration: minute.duration || 0,
    mediaFileName: minute.mediaFileName || '',
    mediaSize: minute.mediaSize ?? null,
    srtFileName: transcript?.srtFileName ?? minute.srtFileName ?? null,
    cueCount: transcript ? transcript.cues.length : minute.cueCount || 0,
    speakerCount: transcript ? transcript.speakers.length : minute.speakerCount || 0,
    cuesHash: summary.cuesHash || (transcript ? cuesHash(transcript) : null),
    transcriptHash: summary.transcriptHash || null,
  };
  for (const k of Object.keys(source)) if (source[k] === null) delete source[k];
  const generation = { model: summary.model || '', generatedAt: iso(summary.generatedAt) || iso(new Date()) };
  if (summary.parameters) generation.parameters = summary.parameters;
  return { format: SUMMARY_FORMAT, version: SUMMARY_FILE_VERSION, exportedAt: iso(exportedAt), app, source, generation, summary: content(summary) };
}

export function encodeSummaryFile(file) {
  return JSON.stringify(file, null, 2);
}

export class SummaryFileError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

/** Parses and validates; throws SummaryFileError (`invalid` / `newer`). */
export function decodeSummaryFile(text) {
  let file;
  try {
    file = JSON.parse(String(text).replace(/^﻿/, ''));
  } catch {
    throw new SummaryFileError('invalid', L('不是有效的纪要文件'));
  }
  if (!file || file.format !== SUMMARY_FORMAT || typeof file.version !== 'number' || !file.source || !file.generation || !file.summary) {
    throw new SummaryFileError('invalid', L('不是有效的纪要文件'));
  }
  if (file.version > SUMMARY_FILE_VERSION) throw new SummaryFileError('newer', L('纪要文件版本较新（{0}），请先更新应用', file.version));
  return file;
}

/** A new summary version for the minute the file is imported into. */
export function summaryFromFile(file, id) {
  return {
    id,
    ...content(file.summary),
    model: file.generation.model || '',
    generatedAt: file.generation.generatedAt || new Date().toISOString(),
    transcriptHash: file.source.transcriptHash || '',
    cuesHash: file.source.cuesHash || null,
    parameters: file.generation.parameters || null,
  };
}

/** Ways the file's source differs from the minute it is being imported into. */
export function summaryFileMismatches(file, minute, transcript) {
  const out = [];
  const src = file.source;
  if (src.cuesHash) {
    if (!transcript) out.push({ kind: 'noTranscript' });
    else if (cuesHash(transcript) !== src.cuesHash) out.push({ kind: 'transcript' });
  }
  const name = (src.mediaFileName || '').trim();
  if (name && name.toLowerCase() !== (minute.mediaFileName || '').trim().toLowerCase()) {
    out.push({ kind: 'media', file: name, current: minute.mediaFileName || '' });
  }
  if (src.duration > 0 && minute.duration > 0 && Math.abs(src.duration - minute.duration) > 2) {
    out.push({ kind: 'duration', file: src.duration, current: minute.duration });
  }
  return out;
}

export function mismatchText(m) {
  switch (m.kind) {
    case 'noTranscript':
      return L('当前妙记还没有字幕，无法核对内容');
    case 'transcript':
      return L('字幕内容不同');
    case 'media':
      return L('媒体文件不同：纪要来自「{0}」，当前是「{1}」', m.file, m.current);
    default:
      return L('时长不同：纪要来自 {0} 的录制，当前为 {1}', duration(m.file), duration(m.current));
  }
}
