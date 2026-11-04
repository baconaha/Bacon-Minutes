import { useState } from 'preact/hooks';
import { settingsOpen, general, llm, apiKey, updateGeneral, updateLLM, choosePreset, updateApiKey, call } from '../state.js';
import { PRESETS, PROTOCOLS, OUTPUT_LANGUAGES, isLocalPreset } from '../../core/llm.js';
import { DEFAULT_SUFFIXES } from '../../core/pairing.js';
import { Icon, Modal, Tab } from './ui.jsx';

function Seg({ options, value, onChange }) {
  return (
    <div class="seg-control">
      {options.map((o) => (
        <button key={o.id} class={o.id === value ? 'on' : ''} onClick={() => onChange(o.id)}>
          {o.name}
        </button>
      ))}
    </div>
  );
}

const num = (v, fallback) => {
  const n = parseFloat(v);
  return Number.isFinite(n) ? n : fallback;
};

/** Provider / protocol / key / model form (§7.1), shared by Settings and the summary empty state. */
export function APIForm({ embedded = false }) {
  const c = llm.value;
  const [showKey, setShowKey] = useState(false);
  const [models, setModels] = useState([]);
  const [modelMsg, setModelMsg] = useState('');
  const [fetching, setFetching] = useState(false);
  const [testing, setTesting] = useState(false);
  const [result, setResult] = useState(null);
  const [advanced, setAdvanced] = useState(false);
  const set = (patch) => updateLLM({ ...llm.value, ...patch });
  const key = apiKey.value;
  const local = isLocalPreset(c.presetID);

  const fetchModels = async () => {
    setFetching(true);
    setModelMsg('');
    try {
      const list = await call('llm:models', llm.value, apiKey.value);
      setModels(list);
      setModelMsg(list.length ? `获取到 ${list.length} 个模型` : '服务端没有返回模型，请手动填写');
    } catch (e) {
      setModels([]);
      setModelMsg(`获取失败（可手动填写）：${e.message}`);
    } finally {
      setFetching(false);
    }
  };

  const test = async () => {
    setTesting(true);
    setResult(null);
    try {
      const s = await call('llm:test', llm.value, apiKey.value);
      setResult({ ok: true, text: `连接成功 · ${Math.round(s * 1000)} ms` });
    } catch (e) {
      setResult({ ok: false, text: e.message });
    } finally {
      setTesting(false);
    }
  };

  return (
    <div class={embedded ? 'form-card' : ''}>
      {!embedded && <div style={{ color: 'var(--text-3)', fontSize: 12, marginBottom: 14 }}>智能纪要使用你自己的模型服务生成。API Key 经系统加密后保存在本机。</div>}
      <div class="form">
        <label>服务商预设</label>
        <select
          class="field"
          style={{ width: 260 }}
          value={c.presetID}
          onChange={(e) => {
            setModels([]);
            setResult(null);
            choosePreset(e.currentTarget.value);
          }}
        >
          {PRESETS.map((p) => (
            <option key={p.id} value={p.id}>
              {p.name}
            </option>
          ))}
        </select>

        <label>协议</label>
        <div>
          <Seg options={PROTOCOLS} value={c.protocol} onChange={(v) => set({ protocol: v })} />
        </div>

        <label>Base URL</label>
        <input class="field" value={c.baseURL} placeholder="https://…" onInput={(e) => set({ baseURL: e.currentTarget.value })} />

        <label>API Key</label>
        <div>
          <div style={{ display: 'flex', gap: 6 }}>
            <input
              class="field"
              style={{ flex: 1 }}
              type={showKey ? 'text' : 'password'}
              value={key}
              placeholder={local ? '本地服务可留空' : 'sk-…'}
              onInput={(e) => updateApiKey(e.currentTarget.value)}
            />
            <button class="btn-icon" onClick={() => setShowKey(!showKey)} title={showKey ? '隐藏' : '显示'}>
              <Icon name={showKey ? 'eyeOff' : 'eye'} />
            </button>
          </div>
          <div class="hint">{key.trim() ? `已加密保存 · 末 4 位 ${key.trim().slice(-4)}` : local ? '本地服务通常不需要 Key' : '尚未填写'}</div>
        </div>

        <label>{c.protocol === 'azure' ? '部署名' : '模型'}</label>
        <div>
          <div style={{ display: 'flex', gap: 6 }}>
            <input
              class="field"
              style={{ flex: 1 }}
              list="lm-models"
              value={c.model}
              placeholder={c.protocol === 'azure' ? 'Azure 部署名称' : '模型名称，或点「获取模型列表」'}
              onInput={(e) => set({ model: e.currentTarget.value })}
            />
            <datalist id="lm-models">
              {models.map((m) => (
                <option key={m} value={m} />
              ))}
            </datalist>
            <button class="btn-secondary" disabled={fetching || c.protocol === 'azure'} onClick={fetchModels}>
              {fetching ? '获取中…' : '获取模型列表'}
            </button>
          </div>
          {modelMsg && <div class="hint">{modelMsg}{models.length ? '，在输入框中选择' : ''}</div>}
        </div>

        <label>输出语言</label>
        <div>
          <Seg options={OUTPUT_LANGUAGES} value={c.outputLanguage} onChange={(v) => set({ outputLanguage: v })} />
        </div>
      </div>

      <button class="btn-link" style={{ margin: '14px 0 0 122px', display: 'inline-flex', alignItems: 'center', gap: 4 }} onClick={() => setAdvanced(!advanced)}>
        高级
        <Icon name={advanced ? 'chevronUp' : 'chevronDown'} size={12} />
      </button>
      {advanced && (
        <div class="form" style={{ marginTop: 12 }}>
          <label>temperature</label>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <label class="check-row" style={{ margin: 0 }}>
              <input type="checkbox" checked={c.temperatureEnabled} onChange={(e) => set({ temperatureEnabled: e.currentTarget.checked })} />
              发送
            </label>
            <input
              class="field"
              style={{ width: 80 }}
              disabled={!c.temperatureEnabled}
              value={c.temperature}
              onChange={(e) => set({ temperature: num(e.currentTarget.value, 0.3) })}
            />
            {c.protocol === 'anthropic' && <span class="hint" style={{ margin: 0 }}>当前 Claude 模型不接受 temperature，建议不发送</span>}
          </div>
          <label>最大输出 tokens</label>
          <input class="field" style={{ width: 120 }} value={c.maxOutputTokens} onChange={(e) => set({ maxOutputTokens: Math.round(num(e.currentTarget.value, 4096)) })} />
          <label>超时（秒）</label>
          <input class="field" style={{ width: 120 }} value={c.timeout} onChange={(e) => set({ timeout: num(e.currentTarget.value, 180) })} />
          <label>单次最大输入字数</label>
          <input class="field" style={{ width: 120 }} value={c.maxInputChars} onChange={(e) => set({ maxInputChars: Math.round(num(e.currentTarget.value, 60000)) })} />
          {c.protocol === 'azure' && (
            <>
              <label>api-version</label>
              <input class="field" style={{ width: 160 }} value={c.azureAPIVersion} onInput={(e) => set({ azureAPIVersion: e.currentTarget.value })} />
            </>
          )}
          {c.protocol === 'anthropic' && (
            <>
              <label>anthropic-version</label>
              <input class="field" style={{ width: 160 }} value={c.anthropicVersion} onInput={(e) => set({ anthropicVersion: e.currentTarget.value })} />
            </>
          )}
          <label style={{ alignSelf: 'start', paddingTop: 7 }}>自定义 Header</label>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            {c.customHeaders.map((h, i) => (
              <div key={i} style={{ display: 'flex', gap: 6 }}>
                <input
                  class="field"
                  style={{ width: 150 }}
                  placeholder="名称"
                  value={h.key}
                  onInput={(e) => set({ customHeaders: c.customHeaders.map((x, j) => (j === i ? { ...x, key: e.currentTarget.value } : x)) })}
                />
                <input
                  class="field"
                  style={{ flex: 1 }}
                  placeholder="值"
                  value={h.value}
                  onInput={(e) => set({ customHeaders: c.customHeaders.map((x, j) => (j === i ? { ...x, value: e.currentTarget.value } : x)) })}
                />
                <button class="btn-icon" onClick={() => set({ customHeaders: c.customHeaders.filter((_, j) => j !== i) })} title="删除">
                  <Icon name="close" size={14} />
                </button>
              </div>
            ))}
            <div style={{ display: 'flex', gap: 16 }}>
              <button class="btn-link" style={{ fontSize: 12 }} onClick={() => set({ customHeaders: [...c.customHeaders, { key: '', value: '' }] })}>
                + 添加 Header
              </button>
              <button
                class="btn-link"
                style={{ fontSize: 12 }}
                title="遇到 HTTP 400 时自动去掉的参数会按服务记住，这里可以清除"
                onClick={async () => {
                  await call('settings:resetCompat');
                  setResult({ ok: true, text: '已清除参数兼容记录，下次请求将重新尝试全部参数' });
                }}
              >
                重置参数兼容记录
              </button>
            </div>
          </div>
        </div>
      )}

      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 16, paddingLeft: embedded ? 0 : 122 }}>
        <button class="btn-secondary" disabled={testing || !c.baseURL || !c.model} onClick={test}>
          {testing ? '测试中…' : '测试连接'}
        </button>
        {result && (
          <span style={{ color: result.ok ? 'var(--text-2)' : 'var(--error)', fontSize: 12, userSelect: 'text', wordBreak: 'break-word' }}>
            {result.ok ? '✓ ' : '✕ '}
            {result.text}
          </span>
        )}
      </div>
    </div>
  );
}

function GeneralForm() {
  const g = general.value;
  const [suffixes, setSuffixes] = useState(g.filenameSuffixes.join(', '));
  const saveSuffixes = (text) =>
    updateGeneral({
      filenameSuffixes: text
        .split(/[,，]/)
        .map((s) => s.trim())
        .filter(Boolean),
    });
  return (
    <div>
      <div class="section-title" style={{ marginTop: 0 }}>
        文字记录
      </div>
      <label class="check-row">
        <input type="checkbox" checked={g.perCharHighlight} onChange={(e) => updateGeneral({ perCharHighlight: e.currentTarget.checked })} />
        逐字高亮（按 cue 时长估算当前字）
      </label>
      <label class="check-row">
        <input type="checkbox" checked={g.insertComma} onChange={(e) => updateGeneral({ insertComma: e.currentTarget.checked })} />
        拼接中文字幕时在无标点处补「，」
      </label>

      <div class="section-title">播放</div>
      <label class="check-row">
        <input type="checkbox" checked={g.skipBlankEnabled} onChange={(e) => updateGeneral({ skipBlankEnabled: e.currentTarget.checked })} />
        跳过空白片段
      </label>
      <div class="check-row" style={{ cursor: 'default' }}>
        空白片段阈值
        <input
          class="field"
          type="number"
          min="0.5"
          max="30"
          step="0.5"
          style={{ width: 80 }}
          value={g.skipBlankThreshold}
          onChange={(e) => updateGeneral({ skipBlankThreshold: Math.min(30, Math.max(0.5, num(e.currentTarget.value, 2))) })}
        />
        秒
      </div>

      <div class="section-title">自动配对</div>
      <div style={{ display: 'flex', gap: 8 }}>
        <input class="field" style={{ flex: 1 }} value={suffixes} placeholder="_FeishuMinutes, _Recording" onInput={(e) => setSuffixes(e.currentTarget.value)} onBlur={() => saveSuffixes(suffixes)} />
        <button
          class="btn-secondary"
          onClick={() => {
            setSuffixes(DEFAULT_SUFFIXES.join(', '));
            updateGeneral({ filenameSuffixes: DEFAULT_SUFFIXES });
          }}
        >
          恢复默认
        </button>
      </div>
      <div class="hint" style={{ fontSize: 12, color: 'var(--text-3)', marginTop: 6 }}>
        导入时从文件名中去掉开头的 13 位时间戳和这些后缀（逗号分隔），用于默认标题和音视频与 SRT 的自动配对。
      </div>

      <div class="section-title">存储</div>
      <div style={{ fontSize: 12, color: 'var(--text-3)' }}>回收站中的妙记保留 30 天后自动彻底删除。媒体文件不会被复制，删除妙记也不会删除原始音视频。</div>
    </div>
  );
}

/** Settings (Ctrl+,): API and general tabs. */
export function SettingsModal() {
  const tab = settingsOpen.value;
  const close = () => (settingsOpen.value = null);
  return (
    <Modal onClose={close} class="settings">
      <div class="settings-head">
        <h2>设置</h2>
        <button class="btn-icon" onClick={close}>
          <Icon name="close" />
        </button>
      </div>
      <div class="tabs" style={{ padding: '14px 24px 0' }}>
        <Tab title="智能纪要" small selected={tab === 'api'} onClick={() => (settingsOpen.value = 'api')} />
        <Tab title="通用" small selected={tab === 'general'} onClick={() => (settingsOpen.value = 'general')} />
      </div>
      <div class="settings-body">{tab === 'api' ? <APIForm /> : <GeneralForm />}</div>
    </Modal>
  );
}
