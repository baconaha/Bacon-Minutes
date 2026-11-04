import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseSRT, decodeSRT, detectSpeaker, FALLBACK_SPEAKER } from '../src/core/srt.js';
import { buildParagraphs, paragraphText, separator, CueTimeline, speakerPercentages, transcriptHash } from '../src/core/paragraphs.js';
import { durationCN, compactDuration, timestamp, srtTimestamp, parseTimestamp, createdDate } from '../src/core/time.js';
import { normalizedTitle, pairFiles, dateFromFileName, DEFAULT_SUFFIXES } from '../src/core/pairing.js';
import { fold, occurrences } from '../src/core/text.js';
import { exportSRT } from '../src/core/exporter.js';

test('Feishu SRT: speakers, overlap, short cues, multi-line CJK', () => {
  const srt = `1
00:00:55,120 --> 00:00:57,300
说话人 1: 大家好，我们开始吧

2
00:00:57,000 --> 00:00:58,000
说话人 2：好

3
00:00:58,000 --> 00:00:58,040
说话人2:嗯

5
00:01:00,000 --> 00:01:03,500
说话人 1: 第一件事
是预算
`;
  const { cues, speakers } = parseSRT(srt);
  assert.equal(cues.length, 4);
  assert.deepEqual(cues.map((c) => c.speakerID), ['说话人 1', '说话人 2', '说话人 2', '说话人 1']);
  assert.deepEqual(cues.map((c) => c.text), ['大家好，我们开始吧', '好', '嗯', '第一件事是预算']);
  assert.equal(cues[0].start, 55.12);
  assert.equal(cues[1].start, 57);
  assert.ok(Math.abs(cues[2].end - cues[2].start - 0.04) < 1e-9);
  assert.deepEqual(speakers.map((s) => s.id), ['说话人 1', '说话人 2']);
});

test('CRLF, BOM, tags, dot milliseconds, missing indexes', () => {
  const srt = '\uFEFF00:00:01.500 --> 00:00:02.000 X1:10\r\n<i>Hello</i>\r\nworld {\\an8}\r\n\r\n\r\n00:00:03,000 --> 00:00:04,000\r\nSpeaker 2: <font color="red">Bye</font>\r\n';
  const { cues } = parseSRT(srt);
  assert.equal(cues.length, 2);
  assert.equal(cues[0].text, 'Hello world');
  assert.equal(cues[0].start, 1.5);
  assert.equal(cues[0].speakerID, FALLBACK_SPEAKER);
  assert.equal(cues[1].speakerID, 'Speaker 2');
  assert.equal(cues[1].text, 'Bye');
});

test('out-of-order cues are sorted', () => {
  const { cues } = parseSRT('2\n00:00:10,000 --> 00:00:11,000\nB\n\n1\n00:00:01,000 --> 00:00:02,000\nA\n');
  assert.deepEqual(cues.map((c) => c.text), ['A', 'B']);
  assert.deepEqual(cues.map((c) => c.id), [0, 1]);
});

test('generic names need two occurrences', () => {
  const srt = ['张三：你好', '李四：你好啊', '张三：今天开会', '注意：这不是名字']
    .map((t, i) => `${i + 1}\n00:00:0${i + 1},000 --> 00:00:0${i + 2},000\n${t}\n`)
    .join('\n');
  const { cues } = parseSRT(srt);
  assert.equal(cues[0].speakerID, '张三');
  assert.equal(cues[0].text, '你好');
  assert.equal(cues[1].speakerID, FALLBACK_SPEAKER);
  assert.equal(cues[1].text, '李四：你好啊');
  assert.equal(cues[3].text, '注意：这不是名字');
});

test('speaker detection edge cases', () => {
  assert.equal(detectSpeaker('10:30 开会'), null);
  assert.equal(detectSpeaker('https://example.com'), null);
  assert.equal(detectSpeaker('[主持人] 欢迎').id, '主持人');
});

test('encodings: UTF-16 LE with BOM and GB18030', () => {
  const text = '1\n00:00:01,000 --> 00:00:02,000\n说话人 1: 测试\n';
  const u16 = Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(text, 'utf16le')]);
  assert.equal(parseSRT(new Uint8Array(u16)).cues[0].text, '测试');
  // "中文" in GB18030 is D6 D0 CE C4
  const gb = new Uint8Array([...Buffer.from('1\n00:00:01,000 --> 00:00:02,000\n'), 0xd6, 0xd0, 0xce, 0xc4, 0x0a]);
  assert.ok(decodeSRT(gb).includes('中文'));
});

test('empty file throws', () => {
  assert.throws(() => parseSRT('hello\nworld'));
});

const cue = (id, start, end, text, speakerID) => ({ id, start, end, text, speakerID });

test('paragraph merging', () => {
  const cues = [cue(0, 0, 2, '我们先看', 'A'), cue(1, 2.5, 4, '第一部分', 'A'), cue(2, 4.2, 5, '好', 'B'), cue(3, 5.1, 6, 'OK，对', 'A'), cue(4, 9, 10, '接下来', 'A')];
  const ps = buildParagraphs(cues);
  assert.deepEqual(ps.map((p) => p.cueIDs), [[0, 1], [2], [3], [4]]);
  assert.equal(paragraphText(ps[0], cues, true), '我们先看，第一部分');
  assert.equal(paragraphText(ps[0], cues, false), '我们先看第一部分');
  assert.equal(buildParagraphs([cue(0, 0, 10, '长句', 'A'), cue(1, 1, 2, '插入', 'A'), cue(2, 11, 12, '继续', 'A')]).length, 1);
  assert.equal(buildParagraphs([cue(0, 0, 1, '字'.repeat(260), 'A'), cue(1, 1.1, 2, '后续', 'A')]).length, 2);
  assert.equal(separator('Hello', 'world', true), ' ');
  assert.equal(separator('你好。', '我们', true), '');
});

test('timeline: active cue and gap skipping with overlaps', () => {
  const tl = new CueTimeline([cue(0, 55, 60, 'a', 'A'), cue(1, 58, 70, 'b', 'B'), cue(2, 61, 62, 'c', 'A'), cue(3, 80, 85, 'd', 'A')]);
  assert.equal(tl.activeCue(10), -1);
  assert.equal(tl.activeCue(56), 0);
  assert.equal(tl.activeCue(59), 1);
  assert.equal(tl.activeCue(61.5), 2);
  assert.equal(tl.activeCue(65), 1);
  assert.equal(tl.activeCue(75), -1);
  assert.equal(tl.skipTarget(0, 2), 55);
  assert.equal(tl.skipTarget(65, 2), null);
  assert.equal(tl.skipTarget(71, 2), 80);
  assert.equal(tl.skipTarget(71, 20), null);
  assert.equal(tl.skipTarget(90, 2), null);
});

test('speaker percentages and transcript hash', () => {
  const cues = [cue(0, 0, 8, 'a', 'A'), cue(1, 8, 10, 'b', 'B')];
  assert.deepEqual(speakerPercentages(cues), { A: 80, B: 20 });
  const t = { cues, speakers: [{ id: 'A', name: 'A' }, { id: 'B', name: 'B' }] };
  const h1 = transcriptHash(t);
  t.speakers[0].name = '张三';
  assert.notEqual(transcriptHash(t), h1);
});

test('time formats', () => {
  assert.equal(durationCN(207), '3 分 27 秒');
  assert.equal(durationCN(5683), '1 小时 34 分 43 秒');
  assert.equal(durationCN(3605), '1 小时 5 秒');
  assert.equal(durationCN(0), '0 秒');
  assert.equal(compactDuration(5683), '1:34:43');
  assert.equal(timestamp(17.9, false), '00:17');
  assert.equal(timestamp(1025, true), '00:17:05');
  assert.equal(srtTimestamp(3723.004), '01:02:03,004');
  assert.equal(parseTimestamp('[01:02]'), 62);
  assert.equal(parseTimestamp('1:02:03'), 3723);
  assert.equal(parseTimestamp('abc'), null);
  assert.equal(createdDate(new Date(2026, 9, 13, 16, 0)), '2026年10月13日 下午4:00');
  assert.equal(createdDate(new Date(2026, 9, 13, 0, 5)), '2026年10月13日 上午12:05');
});

test('file pairing', () => {
  assert.equal(normalizedTitle('1793756624935_周会复盘_FeishuMinutes'), '周会复盘');
  assert.equal(normalizedTitle('Lecture 3_Recording'), 'Lecture 3');
  const media = ['C:\\x\\1793756624935_周会.mp4', 'C:\\x\\访谈.m4a', 'C:\\y\\lonely.mp4'];
  const subs = ['C:\\x\\周会_FeishuMinutes.srt', 'C:\\y\\other.srt', 'C:\\z\\none.srt'];
  const r = pairFiles(media, subs, DEFAULT_SUFFIXES);
  assert.deepEqual(r.pairs, [{ media: media[0], subtitle: subs[0] }, { media: media[1], subtitle: null }]);
  assert.deepEqual(r.suggestions, [{ media: media[2], subtitle: subs[1] }]);
  assert.deepEqual(r.unmatched, [subs[2]]);
  const d = dateFromFileName('会议 2026-10-13_16-00');
  assert.deepEqual([d.getFullYear(), d.getMonth() + 1, d.getDate(), d.getHours()], [2026, 10, 13, 16]);
  assert.equal(dateFromFileName('no date'), null);
});

test('width- and case-insensitive search', () => {
  assert.equal(occurrences(fold('API'), fold('使用ＡＰＩ和api，Ａpi')).length, 3);
  assert.equal(fold('ＡＢＣ').length, 3);
});

test('SRT export uses speaker names', () => {
  const t = { cues: [cue(0, 1, 2.5, '你好', 'A')], speakers: [{ id: 'A', name: '张三' }] };
  assert.equal(exportSRT(t), '1\n00:00:01,000 --> 00:00:02,500\n张三: 你好\n');
});
