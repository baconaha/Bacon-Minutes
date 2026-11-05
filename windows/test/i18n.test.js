import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import TABLES from '../src/i18n/generated.json' with { type: 'json' };
import { PRESETS, PROTOCOLS, textModels } from '../src/core/llm.js';
import { L, Lin, setLanguage, bestLanguage } from '../src/core/i18n.js';
import { duration, roughDuration, createdDate } from '../src/core/time.js';

const LANGS = ['en', 'ja', 'ko', 'es', 'vi', 'fr', 'pt', 'ru'];
const SRC = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'src');

function files(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((d) => {
    const p = path.join(dir, d.name);
    if (d.isDirectory()) return files(p);
    return /\.(js|jsx)$/.test(d.name) ? [p] : [];
  });
}

function usedKeys() {
  const call = /\bL\((['"])((?:\\.|(?!\1)[^\\\n])*)\1/g;
  const keys = new Set([...PRESETS.map((p) => p.name), ...PROTOCOLS.map((p) => p.name)]);
  for (const f of files(SRC)) {
    const text = fs.readFileSync(f, 'utf8');
    for (const m of text.matchAll(call)) keys.add(m[2].replace(/\\n/g, '\n').replace(/\\(['"\\])/g, '$1'));
  }
  return keys;
}

const needsTranslation = (k) => /[\u3000-\u303f\u3400-\u9fff\uff00-\uffef]/.test(k);

test('every L() key has all eight translations', () => {
  const missing = [];
  for (const k of usedKeys()) {
    if (!needsTranslation(k)) continue;
    for (const lang of LANGS) if (TABLES[lang]?.[k] == null) missing.push(`${lang}: ${k}`);
  }
  assert.deepEqual(missing, []);
});

test('translations keep their placeholders', () => {
  const ph = (s) => (s.match(/\{\d+\}/g) || []).sort().join();
  const bad = [];
  for (const lang of LANGS) {
    for (const [k, v] of Object.entries(TABLES[lang])) if (ph(k) !== ph(v)) bad.push(`${lang}: ${k}`);
  }
  assert.deepEqual(bad, []);
});

test('language matching, lookups and formats', () => {
  assert.equal(bestLanguage(['zh-TW']), 'zh-Hans');
  assert.equal(bestLanguage(['de-DE', 'ja-JP']), 'ja');
  assert.equal(bestLanguage(['pt-BR']), 'pt');
  assert.equal(bestLanguage(['de']), 'en');
  assert.equal(Lin('en', '已选 {0} 项', 3), '3 selected');
  assert.equal(Lin('zh-Hans', '播放@@settings'), '播放');
  assert.equal(L('{0} 个', 5), '5 个');
  assert.equal(duration(5683, 'en'), '1h 34m 43s');
  assert.equal(duration(5683, 'ja'), '1時間34分43秒');
  assert.equal(duration(207, 'ko'), '3분 27초');
  assert.equal(roughDuration(43500, 'zh-Hans'), '12 小时 5 分');
  setLanguage('en');
  assert.match(createdDate(new Date(2026, 9, 13, 16, 0)), /Oct 13, 2026/);
  setLanguage('zh-Hans');
  assert.equal(createdDate(new Date(2026, 9, 13, 16, 0)), '2026年10月13日 下午4:00');
});

test('model list drops non-text models', () => {
  const ids = ['gpt-4.1', 'o3-mini', 'text-embedding-3-large', 'tts-1-hd', 'whisper-1', 'gpt-realtime', 'omni-moderation-latest', 'sora-2', 'gpt-image-1', 'o4-mini-deep-research', 'claude-opus-5-5'];
  assert.deepEqual(textModels(ids), ['gpt-4.1', 'o3-mini', 'claude-opus-5-5']);
  assert.deepEqual(textModels(['text-embedding-3-small']), ['text-embedding-3-small']);
});

test('Chinese providers: presets, DashScope thinking switch, error bodies', async () => {
  const { buildRequest, nextFlags, errorMessage, applyPreset, defaultLLMConfig } = await import('../src/core/llm.js');
  const ids = PRESETS.map((p) => p.id);
  for (const id of ['deepseek', 'dashscope', 'zhipu', 'moonshot', 'qianfan', 'hunyuan', 'volcengine']) assert.ok(ids.includes(id), id);
  const req = { system: 's', user: 'u', maxTokens: 10, jsonMode: true };
  const qwen = applyPreset(defaultLLMConfig(), 'dashscope');
  const body = (c, f = {}) => JSON.parse(buildRequest(req, c, 'k', f).init.body);
  assert.equal(body(qwen).enable_thinking, false);
  const named = nextFlags({}, 'parameter.enable_thinking must be set to true', req, qwen);
  assert.equal(named.dropEnableThinking, true);
  assert.equal(nextFlags({}, 'Bad request', req, qwen).dropEnableThinking, undefined);
  assert.equal(body(qwen, named).enable_thinking, undefined);
  assert.equal(body(applyPreset(defaultLLMConfig(), 'deepseek')).enable_thinking, undefined);
  assert.equal(errorMessage('{"error_code":17,"error_msg":"Open api daily request limit reached"}'), 'Open api daily request limit reached');
  assert.equal(errorMessage('{"error":{"code":"invalid_model","message":"model not found"}}'), 'model not found');
});
