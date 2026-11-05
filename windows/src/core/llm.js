import { L } from './i18n.js';

// §7 LLM client: OpenAI-compatible / Anthropic / Azure OpenAI, non-streaming,
// with parameter downgrades on HTTP 400 (§7.4). `fetch` is injected (Electron net.fetch in the app).

export const PROTOCOLS = [
  { id: 'openAI', name: 'OpenAI 兼容' },
  { id: 'anthropic', name: 'Anthropic' },
  { id: 'azure', name: 'Azure OpenAI' },
];

export const PRESETS = [
  { id: 'openai', name: 'OpenAI', protocol: 'openAI', baseURL: 'https://api.openai.com/v1', model: '' },
  { id: 'anthropic', name: 'Anthropic', protocol: 'anthropic', baseURL: 'https://api.anthropic.com', model: 'claude-opus-5-5' },
  { id: 'gemini', name: 'Google Gemini', protocol: 'openAI', baseURL: 'https://generativelanguage.googleapis.com/v1beta/openai', model: '' },
  // Chinese providers, all through their OpenAI-compatible endpoints.
  { id: 'deepseek', name: 'DeepSeek', protocol: 'openAI', baseURL: 'https://api.deepseek.com/v1', model: 'deepseek-chat' },
  { id: 'dashscope', name: '阿里云百炼（通义）', protocol: 'openAI', baseURL: 'https://dashscope.aliyuncs.com/compatible-mode/v1', model: 'qwen-plus' },
  { id: 'zhipu', name: '智谱 GLM', protocol: 'openAI', baseURL: 'https://open.bigmodel.cn/api/paas/v4', model: '' },
  { id: 'moonshot', name: '月之暗面 Kimi', protocol: 'openAI', baseURL: 'https://api.moonshot.cn/v1', model: '' },
  { id: 'qianfan', name: '百度千帆（文心）', protocol: 'openAI', baseURL: 'https://qianfan.baidubce.com/v2', model: 'ernie-4.0-turbo-128k' },
  { id: 'hunyuan', name: '腾讯混元', protocol: 'openAI', baseURL: 'https://tokenhub.tencentmaas.com/v1', model: 'hy3-preview' },
  { id: 'volcengine', name: '火山方舟（豆包）', protocol: 'openAI', baseURL: 'https://ark.cn-beijing.volces.com/api/v3', model: '' },
  { id: 'siliconflow', name: '硅基流动', protocol: 'openAI', baseURL: 'https://api.siliconflow.cn/v1', model: '' },
  { id: 'openrouter', name: 'OpenRouter', protocol: 'openAI', baseURL: 'https://openrouter.ai/api/v1', model: '' },
  { id: 'ollama', name: 'Ollama（本地）', protocol: 'openAI', baseURL: 'http://localhost:11434/v1', model: '' },
  { id: 'lmstudio', name: 'LM Studio（本地）', protocol: 'openAI', baseURL: 'http://localhost:1234/v1', model: '' },
  { id: 'azure', name: 'Azure OpenAI', protocol: 'azure', baseURL: 'https://{resource}.openai.azure.com', model: '' },
  { id: 'custom', name: '自定义', protocol: 'openAI', baseURL: '', model: '' },
];

/** `label` goes verbatim into the (Chinese) prompt; show `outputLanguageName(id)` in the UI. */
export const OUTPUT_LANGUAGES = [
  { id: 'followSource', label: '跟随原文' },
  { id: 'simplifiedChinese', label: '简体中文' },
  { id: 'english', label: 'English' },
  { id: 'japanese', label: '日本語' },
  { id: 'korean', label: '한국어' },
  { id: 'spanish', label: 'Español' },
  { id: 'vietnamese', label: 'Tiếng Việt' },
  { id: 'french', label: 'Français' },
  { id: 'portuguese', label: 'Português' },
  { id: 'russian', label: 'Русский' },
];

export const outputLanguageName = (id) => {
  const l = OUTPUT_LANGUAGES.find((x) => x.id === id) || OUTPUT_LANGUAGES[0];
  return l.id === 'followSource' ? L('跟随原文') : l.label;
};

/** Preset and protocol names are Chinese keys; show them through L(). */
export const presetName = (p) => L(p.name);
export const protocolName = (id) => L(PROTOCOLS.find((p) => p.id === id)?.name || id);

export const preset = (id) => PRESETS.find((p) => p.id === id);
export const isLocalPreset = (id) => id === 'ollama' || id === 'lmstudio';

export function defaultLLMConfig() {
  return {
    presetID: 'openai',
    protocol: 'openAI',
    baseURL: 'https://api.openai.com/v1',
    model: '',
    outputLanguage: 'followSource',
    temperatureEnabled: true,
    temperature: 0.3,
    maxOutputTokens: 4096,
    timeout: 180,
    maxInputChars: 60000,
    customHeaders: [],
    azureAPIVersion: '2024-10-21',
    anthropicVersion: '2023-06-01',
  };
}

/** Fills protocol, base URL, model and provider-appropriate defaults. */
export function applyPreset(config, presetID) {
  const p = preset(presetID);
  if (!p) return config;
  const c = { ...config, presetID: p.id, protocol: p.protocol };
  if (p.id !== 'custom') {
    c.baseURL = p.baseURL;
    c.model = p.model;
  }
  if (p.protocol === 'anthropic') {
    // Current Claude models reject sampling parameters and think before answering;
    // thinking tokens count toward max_tokens.
    c.temperatureEnabled = false;
    c.maxOutputTokens = Math.max(c.maxOutputTokens, 16000);
  } else {
    c.temperatureEnabled = true;
    if (c.maxOutputTokens === 16000) c.maxOutputTokens = 4096;
  }
  return c;
}

// ----- starred models -----

export const favoriteKey = (presetID, baseURL, model) => `${presetID}|${(baseURL || '').trim().toLowerCase()}|${(model || '').trim()}`;

/** A starred model: the endpoint plus the model name (same fields as the Mac app). */
export function makeFavorite(config, model = config.model) {
  return {
    presetID: config.presetID,
    protocol: config.protocol,
    baseURL: (config.baseURL || '').trim(),
    model: (model || '').trim(),
    azureAPIVersion: config.azureAPIVersion,
    anthropicVersion: config.anthropicVersion,
    customHeaders: config.customHeaders || [],
  };
}

export const favoriteID = (f) => favoriteKey(f.presetID, f.baseURL, f.model);

/** `base` pointed at the favorite's model; output language, limits and timeout stay as set. */
export function applyFavorite(base, f) {
  const c = { ...base };
  const wasAnthropic = c.protocol === 'anthropic';
  Object.assign(c, {
    presetID: f.presetID,
    protocol: f.protocol,
    baseURL: f.baseURL,
    model: f.model,
    azureAPIVersion: f.azureAPIVersion ?? c.azureAPIVersion,
    anthropicVersion: f.anthropicVersion ?? c.anthropicVersion,
    customHeaders: f.customHeaders || [],
  });
  if (f.protocol === 'anthropic' && !wasAnthropic) {
    c.temperatureEnabled = false;
    c.maxOutputTokens = Math.max(c.maxOutputTokens, 16000);
  } else if (f.protocol !== 'anthropic' && wasAnthropic) {
    c.temperatureEnabled = true;
    if (c.maxOutputTokens === 16000) c.maxOutputTokens = 4096;
  }
  return c;
}

/** What gets recorded with a summary made with `config` (same keys as the Mac app). */
export function summaryParameters(config, promptVersion) {
  return {
    presetID: config.presetID,
    providerName: preset(config.presetID)?.name || '自定义',
    protocolKind: config.protocol,
    baseURL: (config.baseURL || '').trim(),
    outputLanguage: config.outputLanguage,
    temperature: config.temperatureEnabled ? config.temperature : null,
    maxOutputTokens: config.maxOutputTokens,
    maxInputChars: config.maxInputChars,
    promptVersion,
  };
}

export const isConfigured = (c) => !!c.baseURL?.trim() && !!c.model?.trim() && !c.baseURL.includes('{');
export const compatKey = (c) => `${c.protocol}|${c.baseURL.trim().toLowerCase()}|${c.model.trim()}`;

export class LLMError extends Error {
  constructor(code, message, extra = {}) {
    super(message);
    this.code = code;
    Object.assign(this, extra);
  }
}

const err = {
  notConfigured: (m) => new LLMError('notConfigured', m),
  invalidURL: (m) => new LLMError('invalidURL', m),
  http: (status, message) => new LLMError('http', `HTTP ${status}${L('：')}${message}`, { status, serverMessage: message }),
  network: (m) => new LLMError('network', L('网络错误：{0}', m)),
  timeout: (s) => new LLMError('timeout', L('请求超时（{0} 秒）。可在 API 设置 → 高级中调大「超时」。', Math.round(s))),
  empty: () => new LLMError('empty', L('模型返回了空内容')),
  truncated: () => new LLMError('truncated', L('输出被截断：已达到「最大输出 tokens」上限。请在 API 设置 → 高级中调大该值后重试。')),
  refusal: (cat) => new LLMError('refusal', cat ? L('模型拒绝了该请求（类别：{0}）', cat) : L('模型拒绝了该请求')),
  invalidJSON: (snippet) => new LLMError('invalidJSON', L('模型输出不是合法 JSON：{0}', snippet)),
  cancelled: () => new LLMError('cancelled', L('已取消')),
  unsupported: (m) => new LLMError('unsupported', m),
};
export const errors = err;

/** Claude models that accept server-side refusal fallbacks (`fallbacks: "default"`). */
export const FALLBACK_MODELS = new Set(['claude-opus-5-5', 'claude-fable-5-1', 'claude-opus-5', 'claude-sonnet-5-5']);
export const FALLBACK_BETA = 'server-side-fallback-2026-07-01';

export function normalizedBase(raw) {
  return (raw || '').trim().replace(/\/+$/, '');
}

export function endpoint(config) {
  const base = normalizedBase(config.baseURL);
  if (!base) throw err.notConfigured(L('请先填写 Base URL'));
  if (/[{}]/.test(base)) throw err.invalidURL(L('请把 Base URL 中的 {resource} 等占位符替换为实际值'));
  let url;
  if (config.protocol === 'openAI') {
    url = base.endsWith('/chat/completions') ? base : base + '/chat/completions';
  } else if (config.protocol === 'anthropic') {
    url = base.endsWith('/v1/messages') ? base : base.endsWith('/v1') ? base + '/messages' : base + '/v1/messages';
  } else {
    const dep = config.model.trim();
    if (!dep) throw err.notConfigured(L('请在「模型」中填写 Azure 部署名称'));
    const ver = config.azureAPIVersion?.trim() || '2024-10-21';
    url = `${base}/openai/deployments/${encodeURIComponent(dep)}/chat/completions?api-version=${encodeURIComponent(ver)}`;
  }
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    throw err.invalidURL(L('Base URL 无效：{0}', base));
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') throw err.invalidURL(L('Base URL 无效：{0}', base));
  return url;
}

export function usesFallbacks(config, flags) {
  if (config.protocol !== 'anthropic' || flags.dropFallbacks) return false;
  let host = '';
  try {
    host = new URL(normalizedBase(config.baseURL)).host.toLowerCase();
  } catch {
    return false;
  }
  return host === 'api.anthropic.com' && FALLBACK_MODELS.has(config.model.trim());
}

function headers(config, apiKey, includeBeta) {
  const h = { 'content-type': 'application/json' };
  const key = (apiKey || '').trim();
  if (config.protocol === 'openAI') {
    if (key) h.authorization = `Bearer ${key}`;
  } else if (config.protocol === 'anthropic') {
    if (key) h['x-api-key'] = key;
    h['anthropic-version'] = config.anthropicVersion?.trim() || '2023-06-01';
    if (includeBeta) h['anthropic-beta'] = FALLBACK_BETA;
  } else if (key) {
    h['api-key'] = key;
  }
  for (const { key: k, value } of config.customHeaders || []) {
    if (k && k.trim()) h[k.trim().toLowerCase()] = value ?? '';
  }
  return h;
}

/** `{ url, init }` for one completion request. */
export function buildRequest(req, config, apiKey, flags = {}) {
  const url = endpoint(config);
  const model = config.model.trim();
  if (config.protocol !== 'azure' && !model) throw err.notConfigured(L('请先填写模型名称'));
  const fallbacks = usesFallbacks(config, flags);
  const body = {};
  if (config.protocol === 'anthropic') {
    body.model = model;
    body.max_tokens = req.maxTokens;
    body.system = req.system;
    body.messages = [{ role: 'user', content: req.user }];
    if (fallbacks) body.fallbacks = 'default';
  } else {
    if (config.protocol === 'openAI') body.model = model;
    body.messages = [
      { role: 'system', content: req.system },
      { role: 'user', content: req.user },
    ];
    body[flags.useMaxCompletionTokens ? 'max_completion_tokens' : 'max_tokens'] = req.maxTokens;
    if (req.jsonMode && !flags.dropResponseFormat) body.response_format = { type: 'json_object' };
    if (sendsEnableThinking(config, flags)) body.enable_thinking = false;
  }
  if (config.temperatureEnabled && !flags.dropTemperature) body.temperature = Number(config.temperature);
  return { url, init: { method: 'POST', headers: headers(config, apiKey, fallbacks), body: JSON.stringify(body) } };
}

/**
 * Alibaba DashScope: open-source Qwen3 models think by default and then refuse non-streaming
 * calls, so requests ask for no thinking (dropped again if a thinking-only model rejects it).
 */
export function sendsEnableThinking(config, flags) {
  if (config.protocol !== 'openAI' || flags.dropEnableThinking) return false;
  try {
    return new URL(normalizedBase(config.baseURL)).hostname.toLowerCase().includes('dashscope');
  } catch {
    return false;
  }
}

const STEPS = [
  { id: 'dropEnableThinking', keywords: ['enable_thinking', 'thinking'] },
  { id: 'dropResponseFormat', keywords: ['response_format', 'json_object', 'json mode'] },
  { id: 'useMaxCompletionTokens', keywords: ['max_tokens', 'max_completion_tokens'] },
  { id: 'dropTemperature', keywords: ['temperature'] },
  { id: 'dropFallbacks', keywords: ['fallback', 'anthropic-beta'] },
];

/** Next downgrade after an HTTP 400 (§7.4), preferring the parameter the message names. */
export function nextFlags(flags, message, req, config) {
  const openAIStyle = config.protocol !== 'anthropic';
  const applicable = (id) => {
    switch (id) {
      case 'dropEnableThinking':
        return sendsEnableThinking(config, flags);
      case 'dropResponseFormat':
        return openAIStyle && req.jsonMode && !flags.dropResponseFormat;
      case 'useMaxCompletionTokens':
        return openAIStyle && !flags.useMaxCompletionTokens;
      case 'dropTemperature':
        return config.temperatureEnabled && !flags.dropTemperature;
      case 'dropFallbacks':
        return usesFallbacks(config, flags);
      default:
        return false;
    }
  };
  const candidates = STEPS.filter((s) => applicable(s.id));
  if (!candidates.length) return null;
  const lower = (message || '').toLowerCase();
  // enable_thinking is only dropped when the error names it; otherwise try the others first.
  const step =
    candidates.find((s) => s.keywords.some((k) => lower.includes(k))) || candidates.find((s) => s.id !== 'dropEnableThinking') || candidates[0];
  return { ...flags, [step.id]: true };
}

function errorText(x) {
  if (typeof x === 'string') return x;
  if (x && typeof x === 'object') {
    // OpenAI style, then Baidu ("error_msg") and other Chinese providers' field names.
    for (const k of ['message', 'error_msg', 'errmsg', 'msg']) if (typeof x[k] === 'string' && x[k]) return x[k];
    if (x.error) return errorText(x.error);
  }
  return null;
}

/** Server message from an error body (OpenAI, Anthropic, Gemini array form, plain text). */
export function errorMessage(text) {
  try {
    const obj = JSON.parse(text);
    if (Array.isArray(obj)) {
      const m = errorText(obj[0]?.error);
      if (m) return m;
    } else if (obj && typeof obj === 'object') {
      const m = errorText(obj.error) || errorText({ ...obj, error: undefined }) || (typeof obj.detail === 'string' && obj.detail);
      if (m) return m;
    }
  } catch {
    // not JSON
  }
  const raw = (text || '').slice(0, 500).trim();
  return raw || L('（服务端未返回内容）');
}

/** `{ text, truncated }` from a 2xx body. */
export function parseResponse(text, protocol) {
  let obj;
  try {
    obj = JSON.parse(text);
  } catch {
    throw err.network(L('无法解析服务端响应：{0}', text.slice(0, 300)));
  }
  if (obj && obj.error && obj.choices == null && obj.content == null) throw err.http(200, errorText(obj.error) || L('未知错误'));
  if (protocol === 'anthropic') {
    if (obj.stop_reason === 'refusal') throw err.refusal(obj.stop_details?.category);
    const out = (obj.content || []).filter((b) => b.type === 'text').map((b) => b.text || '').join('');
    return { text: out, truncated: obj.stop_reason === 'max_tokens' };
  }
  const first = obj.choices?.[0];
  if (!first) throw err.empty();
  let out = '';
  const msg = first.message;
  if (msg) {
    if (typeof msg.content === 'string') out = msg.content;
    else if (Array.isArray(msg.content)) out = msg.content.map((p) => p.text || '').join('');
    if (!out && msg.refusal) throw err.refusal(msg.refusal);
  } else if (typeof first.text === 'string') {
    out = first.text;
  }
  if (first.finish_reason === 'content_filter' && !out) throw err.refusal('content_filter');
  return { text: out, truncated: first.finish_reason === 'length' };
}

export function parseModelIDs(text) {
  try {
    const obj = JSON.parse(text);
    const list = obj.data || obj.models || [];
    return { ids: list.map((m) => m.id || m.name).filter(Boolean), hasMore: !!obj.has_more, lastID: obj.last_id || null };
  } catch {
    return { ids: [], hasMore: false, lastID: null };
  }
}

export class LLMClient {
  /**
   * @param {{ fetch: typeof fetch, compat: { get(key): object, set(key, flags): void } }} deps
   */
  constructor({ fetch, compat }) {
    this.fetch = fetch;
    this.compat = compat;
  }

  async send(url, init, timeoutSec, signal) {
    const timeoutSignal = AbortSignal.timeout(Math.max(5, timeoutSec) * 1000);
    const combined = signal ? AbortSignal.any([signal, timeoutSignal]) : timeoutSignal;
    let res;
    try {
      res = await this.fetch(url, { ...init, signal: combined });
      const text = await res.text();
      return { status: res.status, text };
    } catch (e) {
      if (signal?.aborted) throw err.cancelled();
      if (timeoutSignal.aborted) throw err.timeout(timeoutSec);
      throw err.network(e?.message || String(e));
    }
  }

  async complete(req, config, apiKey, signal) {
    const key = compatKey(config);
    const original = { ...(this.compat.get(key) || {}) };
    let flags = { ...original };
    for (;;) {
      if (signal?.aborted) throw err.cancelled();
      const { url, init } = buildRequest(req, config, apiKey, flags);
      const { status, text } = await this.send(url, init, config.timeout, signal);
      if (status >= 200 && status < 300) {
        const result = parseResponse(text, config.protocol);
        if (JSON.stringify(flags) !== JSON.stringify(original)) this.compat.set(key, flags);
        return result;
      }
      const message = errorMessage(text);
      if (status === 400 || status === 422) {
        const next = nextFlags(flags, message, req, config);
        if (next) {
          flags = next;
          continue;
        }
      }
      throw err.http(status, message);
    }
  }

  async testConnection(config, apiKey) {
    const started = Date.now();
    await this.complete({ system: 'You are a connectivity check.', user: 'Reply with OK.', maxTokens: 64, jsonMode: false }, config, apiKey);
    return (Date.now() - started) / 1000;
  }

  async listModels(config, apiKey) {
    const base = normalizedBase(config.baseURL);
    if (!base) throw err.notConfigured(L('请先填写 Base URL'));
    if (config.protocol === 'azure') throw err.unsupported(L('Azure OpenAI 不支持获取模型列表，请在「模型」中填写部署名称'));
    const get = async (url) => {
      const { status, text } = await this.send(url, { method: 'GET', headers: headers(config, apiKey, false) }, Math.min(config.timeout, 30));
      if (status < 200 || status >= 300) throw err.http(status, errorMessage(text));
      return parseModelIDs(text);
    };
    let ids = [];
    if (config.protocol === 'openAI') {
      ids = (await get(base + '/models')).ids;
    } else {
      const root = base.endsWith('/v1') ? base : base + '/v1';
      let after = null;
      for (let i = 0; i < 10; i++) {
        const page = await get(`${root}/models?limit=1000${after ? '&after_id=' + encodeURIComponent(after) : ''}`);
        ids.push(...page.ids);
        if (!page.hasMore || !page.lastID) break;
        after = page.lastID;
      }
    }
    return textModels([...new Set(ids)].sort());
  }
}

/**
 * Drops models that cannot write a summary (embeddings, speech, images, moderation …), so the
 * picker only lists usable ones. Returns the input unchanged if nothing would be left.
 */
export function textModels(ids) {
  const excluded = ['embed', 'tts', 'whisper', 'transcribe', 'moderation', 'dall-e', 'sora', 'image', 'realtime', 'audio', 'deep-research', 'computer-use', 'davinci', 'babbage', 'rerank'];
  const kept = ids.filter((id) => !excluded.some((x) => id.toLowerCase().includes(x)));
  return kept.length ? kept : ids;
}
