import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cuesHash, transcriptHash } from '../src/core/paragraphs.js';
import { makeSummaryFile, encodeSummaryFile, decodeSummaryFile, summaryFromFile, summaryFileMismatches, SummaryFileError } from '../src/core/summaryFile.js';
import { makeFavorite, favoriteID, applyFavorite, applyPreset, defaultLLMConfig, summaryParameters } from '../src/core/llm.js';
import { isUnsupported, isSummaryFile } from '../src/core/pairing.js';
import { volumeKey } from '../src/main/volume.js';

const transcript = (name = '说话人 1') => ({
  cues: [
    { id: 0, start: 0, end: 1.5, text: '大家好', speakerID: 's1' },
    { id: 1, start: 1.5, end: 3.25, text: 'Hello world', speakerID: 's1' },
  ],
  speakers: [{ id: 's1', name, colorHex: '#3370FF' }],
  srtFileName: 'lecture.srt',
  importedAt: '1970-01-01T00:00:00Z',
});

const minute = (mediaFileName = 'lecture.mp4', duration = 3600) => ({
  id: 'm1',
  title: 'Lecture 1',
  createdAt: '2023-11-14T22:13:20.000Z',
  duration,
  mediaFileName,
  mediaSize: 123456789,
  cueCount: 2,
  speakerCount: 1,
});

const summary = (t) => ({
  id: 'x',
  overview: '本节课讲解了 kinematics。',
  keyPoints: [{ title: 'SUVAT', content: '…' }],
  todos: [{ content: '完成习题', owner: '未指定', time: 12 }],
  chapters: [{ time: 0, title: 'Intro', summary: '…' }],
  keywords: ['velocity'],
  model: 'deepseek-chat',
  generatedAt: '2025-06-15T15:06:40.000Z',
  transcriptHash: transcriptHash(t),
  cuesHash: cuesHash(t),
  parameters: summaryParameters(defaultLLMConfig(), 2),
});

test('hashes match the Mac app', () => {
  assert.equal(cuesHash(transcript()), '98cf95ed8bca9311');
  assert.equal(transcriptHash(transcript()), 'cd1242d8775c3df1');
  // Renaming a speaker changes the content hash but not the cues hash.
  assert.equal(cuesHash(transcript('Ms Lee')), '98cf95ed8bca9311');
  assert.notEqual(transcriptHash(transcript('Ms Lee')), 'cd1242d8775c3df1');
});

test('summary file: round trip, Mac-compatible dates, matching', () => {
  const t = transcript();
  const file = makeSummaryFile({ summary: summary(t), minute: minute(), transcript: t, app: 'Bacon Minutes 1.0.0 (Windows)', exportedAt: new Date('2026-11-05T08:30:00.123Z') });
  // No milliseconds: the Mac decoder's default ISO 8601 parser rejects them.
  assert.equal(file.exportedAt, '2026-11-05T08:30:00Z');
  assert.equal(file.source.createdAt, '2023-11-14T22:13:20Z');
  assert.equal(file.generation.generatedAt, '2025-06-15T15:06:40Z');
  const back = decodeSummaryFile(encodeSummaryFile(file));
  assert.deepEqual(back, file);
  assert.deepEqual(summaryFileMismatches(back, minute(), t), []);
  const s = summaryFromFile(back, 'new-id');
  assert.equal(s.id, 'new-id');
  assert.equal(s.model, 'deepseek-chat');
  assert.equal(s.cuesHash, cuesHash(t));
  assert.equal(s.parameters.promptVersion, 2);
});

test('summary file written by the Mac app', () => {
  const mac = `{
  "app" : "Bacon Minutes 1.0 (macOS)",
  "exportedAt" : "2026-11-05T08:30:00Z",
  "format" : "bacon-minutes-summary",
  "generation" : {
    "generatedAt" : "2026-11-05T08:00:00Z",
    "model" : "claude-opus-5-5",
    "parameters" : { "baseURL" : "https://api.anthropic.com", "maxInputChars" : 60000, "maxOutputTokens" : 16000,
                     "outputLanguage" : "followSource", "presetID" : "anthropic", "promptVersion" : 2,
                     "protocolKind" : "anthropic", "providerName" : "Anthropic" }
  },
  "source" : { "createdAt" : "2023-11-14T22:13:20Z", "cueCount" : 2, "cuesHash" : "98cf95ed8bca9311", "duration" : 3600,
               "mediaFileName" : "lecture.mp4", "speakerCount" : 1, "srtFileName" : "lecture.srt", "title" : "Lecture 1",
               "transcriptHash" : "cd1242d8775c3df1" },
  "summary" : { "chapters" : [ { "summary" : "s", "time" : 0, "title" : "Intro" } ], "keyPoints" : [], "keywords" : [], "overview" : "o", "todos" : [] },
  "version" : 1
}`;
  const file = decodeSummaryFile(mac);
  assert.equal(file.generation.model, 'claude-opus-5-5');
  assert.deepEqual(summaryFileMismatches(file, minute(), transcript('Ms Lee')), []);
  assert.equal(summaryFromFile(file, 'id').parameters.temperature, undefined);
});

test('summary file mismatches and rejects', () => {
  const t = transcript();
  const file = makeSummaryFile({ summary: summary(t), minute: minute(), transcript: t, app: 'test' });
  const other = { ...t, cues: [t.cues[0], { ...t.cues[1], text: 'Goodbye' }] };
  assert.deepEqual(
    summaryFileMismatches(file, minute('other.mkv', 100), other).map((m) => m.kind),
    ['transcript', 'media', 'duration'],
  );
  assert.deepEqual(summaryFileMismatches(file, minute(), null).map((m) => m.kind), ['noTranscript']);
  // Case-insensitive names; durations within 2 s are the same recording.
  assert.deepEqual(summaryFileMismatches(file, minute('LECTURE.MP4', 3601.5), t), []);
  assert.throws(() => decodeSummaryFile('{"format":"something-else","version":1}'), (e) => e instanceof SummaryFileError && e.code === 'invalid');
  assert.throws(() => decodeSummaryFile('not json'), SummaryFileError);
  const newer = { ...file, version: 99 };
  assert.throws(() => decodeSummaryFile(JSON.stringify(newer)), (e) => e.code === 'newer');
});

test('favorite models keep their endpoint and switch protocol defaults', () => {
  const base = { ...applyPreset(defaultLLMConfig(), 'deepseek'), outputLanguage: 'english', maxInputChars: 30000 };
  const claude = applyPreset(defaultLLMConfig(), 'anthropic');
  const fav = makeFavorite(claude, 'claude-opus-5-5');
  assert.equal(favoriteID(fav), 'anthropic|https://api.anthropic.com|claude-opus-5-5');
  const c = applyFavorite(base, fav);
  assert.equal(c.presetID, 'anthropic');
  assert.equal(c.protocol, 'anthropic');
  assert.equal(c.model, 'claude-opus-5-5');
  assert.equal(c.temperatureEnabled, false);
  assert.ok(c.maxOutputTokens >= 16000);
  assert.equal(c.outputLanguage, 'english');
  assert.equal(c.maxInputChars, 30000);
  const back = applyFavorite(c, makeFavorite(base, 'deepseek-chat'));
  assert.equal(back.temperatureEnabled, true);
  assert.equal(back.maxOutputTokens, 4096);
  assert.equal(back.baseURL, 'https://api.deepseek.com/v1');
});

test('unsupported formats, summary files and volume keys', () => {
  assert.ok(isUnsupported('C:\\x\\movie.MKV'));
  assert.ok(isUnsupported('/x/subs.ass'));
  assert.ok(!isUnsupported('/x/movie.mp4'));
  assert.ok(isSummaryFile('D:\\a.baconsummary'));
  assert.equal(volumeKey('\\\\NAS\\Lectures\\IB\\a.mp4'), '\\\\nas\\lectures');
  assert.equal(volumeKey('Z:\\IB\\a.mp4'), 'z:');
  assert.equal(volumeKey('/Volumes/NAS/a.mp4'), '/volumes');
});

test('summary prompt is the same text as the Mac app', async () => {
  const { readFileSync } = await import('node:fs');
  const { SYSTEM_PROMPT, PROMPT_VERSION } = await import('../src/core/prompts.js');
  const swift = readFileSync(new URL('../../Sources/MinutesCore/LLM/Prompts.swift', import.meta.url), 'utf8');
  const body = swift.slice(swift.indexOf('static let system = """\n') + 'static let system = """\n'.length, swift.indexOf('\n    """\n'));
  const macRaw = body.split('\n').map((l) => l.replace(/^ {4}/, '')).join('\n');
  // Both sources use the same escapes (\\"…\\"), so compare them as written.
  const jsSrc = readFileSync(new URL('../src/core/prompts.js', import.meta.url), 'utf8');
  const jsRaw = jsSrc.slice(jsSrc.indexOf('SYSTEM_PROMPT = `') + 'SYSTEM_PROMPT = `'.length, jsSrc.indexOf('`;', jsSrc.indexOf('SYSTEM_PROMPT = `')));
  assert.equal(jsRaw, macRaw);
  assert.ok(SYSTEM_PROMPT.includes('chapters.title、key_points.title'));
  assert.equal(PROMPT_VERSION, Number(/static let version = (\d+)/.exec(swift)[1]));
});
