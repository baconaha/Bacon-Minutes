import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {
  LLMClient, buildRequest, nextFlags, parseResponse, errorMessage, defaultLLMConfig, applyPreset,
} from '../src/core/llm.js';
import { parseSummary, validateSummary, chunkLines, generateSummary, buildSummaryInput } from '../src/core/summary.js';
import { fold } from '../src/core/text.js';
import { buildParagraphs } from '../src/core/paragraphs.js';

const memoryCompat = () => {
  const m = new Map();
  return { get: (k) => m.get(k), set: (k, v) => m.set(k, v), map: m };
};

test('JSON extraction strips thinking and fences', () => {
  const text = '<think>reasoning {not json}</think>\n```json\n{"overview":"本次会议讨论了预算","key_points":[{"title":"预算","content":"确定了预算"}],"todos":[],"chapters":[{"time":"00:57","title":"开场","summary":"介绍"}],"keywords":["预算"]}\n```';
  const p = parseSummary(text);
  assert.equal(p.summary.overview, '本次会议讨论了预算');
  assert.equal(p.summary.chapters[0].time, 57);
  assert.equal(parseSummary('not json at all'), null);
});

test('validation snaps timestamps, sorts, dedupes and filters keywords', () => {
  const input = { lineStarts: [55.8, 90.2, 190], foldedFullText: fold('预算讨论\n下一步\n总结') };
  const raw = {
    overview: 'x',
    keyPoints: [],
    chapters: [
      { time: 190, title: 'C', summary: '' },
      { time: 60, title: 'A', summary: '' },
      { time: 95, title: 'B', summary: '' },
      { time: 91, title: 'B2', summary: '' },
    ],
    todos: [{ content: '跟进', owner: '', time: 92 }],
    keywords: ['预算', '不存在的词', '预算'],
  };
  const d = validateSummary(raw, input);
  assert.deepEqual(d.chapters.map((c) => c.title), ['A', 'B', 'C']);
  assert.deepEqual(d.chapters.map((c) => c.time), [55.8, 90.2, 190]);
  assert.equal(d.todos[0].owner, '未指定');
  assert.equal(d.todos[0].time, 90.2);
  assert.deepEqual(d.keywords, ['预算']);
});

test('chunking at paragraph boundaries', () => {
  const lines = Array(10).fill('字'.repeat(400));
  const chunks = chunkLines(lines, 1000);
  assert.equal(chunks.length, 5);
  assert.deepEqual(chunks[0], [0, 2]);
});

test('downgrade order and message hints', () => {
  const config = { ...defaultLLMConfig(), model: 'm' };
  const req = { system: 's', user: 'u', maxTokens: 10, jsonMode: true };
  let f = nextFlags({}, 'Bad request', req, config);
  assert.ok(f.dropResponseFormat);
  f = nextFlags(f, 'Bad request', req, config);
  assert.ok(f.useMaxCompletionTokens);
  f = nextFlags(f, 'Bad request', req, config);
  assert.ok(f.dropTemperature);
  assert.equal(nextFlags(f, 'Bad request', req, config), null);
  const hinted = nextFlags({}, "Unsupported parameter: 'temperature'", req, config);
  assert.ok(hinted.dropTemperature && !hinted.dropResponseFormat);
});

test('request shapes for the three protocols', () => {
  const req = { system: 'sys', user: 'hi', maxTokens: 100, jsonMode: true };
  const openai = { ...defaultLLMConfig(), baseURL: 'https://api.example.com/v1/', model: 'gpt', customHeaders: [{ key: 'X-Test', value: '1' }] };
  const r1 = buildRequest(req, openai, 'k');
  assert.equal(r1.url, 'https://api.example.com/v1/chat/completions');
  assert.equal(r1.init.headers.authorization, 'Bearer k');
  assert.equal(r1.init.headers['x-test'], '1');
  const b1 = JSON.parse(r1.init.body);
  assert.ok(b1.response_format);
  assert.equal(b1.max_tokens, 100);

  const anthropic = applyPreset(defaultLLMConfig(), 'anthropic');
  const r2 = buildRequest(req, anthropic, 'k');
  assert.equal(r2.url, 'https://api.anthropic.com/v1/messages');
  assert.equal(r2.init.headers['x-api-key'], 'k');
  assert.equal(r2.init.headers['anthropic-version'], '2023-06-01');
  assert.equal(r2.init.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
  const b2 = JSON.parse(r2.init.body);
  assert.equal(b2.system, 'sys');
  assert.equal(b2.fallbacks, 'default');
  assert.equal(b2.temperature, undefined);
  assert.equal(b2.max_tokens, 100);

  const azure = { ...defaultLLMConfig(), protocol: 'azure', baseURL: 'https://res.openai.azure.com', model: 'my-deploy' };
  const r3 = buildRequest(req, azure, 'k');
  assert.equal(r3.url, 'https://res.openai.azure.com/openai/deployments/my-deploy/chat/completions?api-version=2024-10-21');
  assert.equal(r3.init.headers['api-key'], 'k');
  assert.equal(JSON.parse(r3.init.body).model, undefined);
});

test('response parsing', () => {
  const r1 = parseResponse('{"choices":[{"message":{"content":"hi"},"finish_reason":"length"}]}', 'openAI');
  assert.deepEqual(r1, { text: 'hi', truncated: true });
  const r2 = parseResponse('{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"a"},{"type":"text","text":"b"}],"stop_reason":"end_turn"}', 'anthropic');
  assert.deepEqual(r2, { text: 'ab', truncated: false });
  assert.throws(() => parseResponse('{"content":[],"stop_reason":"refusal","stop_details":{"category":"cyber"}}', 'anthropic'), /cyber/);
  assert.equal(errorMessage('{"type":"error","error":{"type":"invalid_request_error","message":"temperature: not supported"}}'), 'temperature: not supported');
});

/** Local OpenAI-compatible server that rejects response_format, then returns a summary. */
function startMockServer() {
  const calls = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      const json = body ? JSON.parse(body) : {};
      calls.push({ url: req.url, auth: req.headers.authorization, body: json });
      res.setHeader('content-type', 'application/json');
      if (json.response_format) {
        res.statusCode = 400;
        res.end(JSON.stringify({ error: { message: "Unsupported parameter: 'response_format'" } }));
        return;
      }
      const content = JSON.stringify({
        overview: '本次会议讨论了预算与排期',
        key_points: [{ title: '预算', content: '确定了第一季度预算' }],
        todos: [{ content: '整理预算表', owner: '张三', time: '00:01' }],
        chapters: [{ time: '00:00', title: '预算讨论', summary: '讨论预算' }, { time: '00:05', title: '排期', summary: '讨论排期' }],
        keywords: ['预算', '排期', '不存在'],
      });
      res.end(JSON.stringify({ choices: [{ message: { content }, finish_reason: 'stop' }] }));
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, calls, port: server.address().port })));
}

test('end to end: downgrade on 400, remember it, validate the summary', async () => {
  const { server, calls, port } = await startMockServer();
  try {
    const compat = memoryCompat();
    const client = new LLMClient({ fetch, compat });
    const config = { ...defaultLLMConfig(), presetID: 'custom', baseURL: `http://127.0.0.1:${port}/v1`, model: 'mock' };
    const cues = [
      { id: 0, start: 0.4, end: 3, text: '我们先讨论预算', speakerID: '说话人 1' },
      { id: 1, start: 5.2, end: 8, text: '然后看排期', speakerID: '说话人 2' },
    ];
    const transcript = { cues, speakers: [{ id: '说话人 1', name: '张三' }, { id: '说话人 2', name: '说话人 2' }] };
    const input = buildSummaryInput({ title: 't', duration: 10, transcript, paragraphs: buildParagraphs(cues), insertComma: true, language: 'followSource' });
    assert.deepEqual(input.lines, ['[00:00] 张三：我们先讨论预算', '[00:05] 说话人 2：然后看排期']);
    const events = [];
    const draft = await generateSummary({ client, input, config, apiKey: 'secret', progress: (p) => events.push(p.type) });
    assert.equal(calls.length, 2);
    assert.ok(calls[0].body.response_format);
    assert.equal(calls[1].body.response_format, undefined);
    assert.equal(calls[1].auth, 'Bearer secret');
    assert.deepEqual([...compat.map.values()][0], { dropResponseFormat: true });
    assert.deepEqual(events, ['single']);
    assert.deepEqual(draft.chapters.map((c) => c.time), [0.4, 5.2]);
    assert.equal(draft.todos[0].time, 0.4);
    assert.deepEqual(draft.keywords, ['预算', '排期']);

    // Second call goes straight to the remembered downgrade.
    await client.complete({ system: 's', user: 'u', maxTokens: 10, jsonMode: true }, config, 'secret');
    assert.equal(calls.length, 3);
    assert.equal(calls[2].body.response_format, undefined);
  } finally {
    server.close();
  }
});

test('cancellation and timeout', async () => {
  const server = http.createServer(() => {}); // never answers
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  try {
    const client = new LLMClient({ fetch, compat: memoryCompat() });
    const config = { ...defaultLLMConfig(), baseURL: `http://127.0.0.1:${port}/v1`, model: 'm', timeout: 5 };
    const ac = new AbortController();
    setTimeout(() => ac.abort(), 100);
    await assert.rejects(client.complete({ system: 's', user: 'u', maxTokens: 1, jsonMode: false }, config, '', ac.signal), (e) => e.code === 'cancelled');
  } finally {
    server.closeAllConnections();
    server.close();
  }
});
