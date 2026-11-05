import { useState } from 'preact/hooks';
import {
  settingsOpen, general, llm, apiKey, updateGeneral, updateLLM, choosePreset, updateApiKey, call, setUILanguage, systemLanguage, customIcon,
  favorites, isFavorite, toggleFavorite, removeFavorite, useFavoriteAsDefault,
} from '../state.js';
import { PRESETS, PROTOCOLS, OUTPUT_LANGUAGES, isLocalPreset, presetName, outputLanguageName, favoriteKey, favoriteID, preset } from '../../core/llm.js';
import { DEFAULT_SUFFIXES } from '../../core/pairing.js';
import { L, LANGUAGES, languageName } from '../../core/i18n.js';
import { Icon, Logo, Menu, Modal, SelectField, Tab, StarButton, Tag } from './ui.jsx';

function Seg({ options, value, onChange }) {
  return (
    <div class="seg-control">
      {options.map((o) => (
        <button key={o.id} class={o.id === value ? 'on' : ''} onClick={() => onChange(o.id)}>
          {L(o.name)}
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
      setModelMsg(list.length ? L('获取到 {0} 个模型，点击 ⌄ 选择', list.length) : L('服务端没有返回模型，请手动填写'));
    } catch (e) {
      setModels([]);
      setModelMsg(L('获取失败（可手动填写）：{0}', e.message));
    } finally {
      setFetching(false);
    }
  };

  const test = async () => {
    setTesting(true);
    setResult(null);
    try {
      const s = await call('llm:test', llm.value, apiKey.value);
      setResult({ ok: true, text: L('连接成功 · {0} ms', Math.round(s * 1000)) });
    } catch (e) {
      setResult({ ok: false, text: e.message });
    } finally {
      setTesting(false);
    }
  };

  return (
    <div class={embedded ? 'form-card' : ''}>
      {!embedded && <div style={{ color: 'var(--text-3)', fontSize: 12, marginBottom: 14 }}>{L('智能纪要使用你自己的模型服务生成。API Key 经系统加密后只保存在本机。')}</div>}
      <div class="form">
        <label>{L('服务商预设')}</label>
        <Menu
          hover={false}
          minWidth={260}
          items={PRESETS.map((p) => ({
            label: presetName(p),
            selected: p.id === c.presetID,
            onClick: () => {
              setModels([]);
              setModelMsg('');
              setResult(null);
              choosePreset(p.id);
            },
          }))}
          trigger={({ open, toggle }) => <SelectField text={presetName(PRESETS.find((p) => p.id === c.presetID) || PRESETS.at(-1))} open={open} onClick={toggle} />}
        />

        <label>{L('协议')}</label>
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
              placeholder={local ? L('本地服务可留空') : 'sk-…'}
              onInput={(e) => updateApiKey(e.currentTarget.value)}
            />
            <button class="btn-icon" onClick={() => setShowKey(!showKey)} title={showKey ? L('隐藏') : L('显示')}>
              <Icon name={showKey ? 'eyeOff' : 'eye'} />
            </button>
          </div>
          <div class="hint">{key.trim() ? L('已保存 · 末 4 位 {0}', key.trim().slice(-4)) : local ? L('本地服务通常不需要 Key') : L('尚未填写')}</div>
        </div>

        <label>{c.protocol === 'azure' ? L('部署名') : L('模型')}</label>
        <div>
          <div style={{ display: 'flex', gap: 6 }}>
            <input
              class="field"
              style={{ flex: 1 }}
              value={c.model}
              placeholder={c.protocol === 'azure' ? L('Azure 部署名称') : L('模型名称')}
              onInput={(e) => set({ model: e.currentTarget.value })}
            />
            <StarButton on={isFavorite(favoriteKey(c.presetID, c.baseURL, c.model))} disabled={!c.model.trim()} onClick={() => toggleFavorite(c.model)} />
            {models.length > 0 && (
              <Menu
                hover={false}
                align="right"
                minWidth={260}
                title={L('从列表中选择')}
                items={models.map((m) => ({
                  label: m,
                  selected: m === c.model,
                  onClick: () => set({ model: m }),
                  star: { on: isFavorite(favoriteKey(c.presetID, c.baseURL, m)), onToggle: () => toggleFavorite(m) },
                }))}
                trigger={({ open, toggle }) => (
                  <button class={`btn-icon chevron-btn ${open ? 'active-bg' : ''}`} onClick={toggle}>
                    <Icon name="chevronDown" size={13} />
                  </button>
                )}
              />
            )}
            <button class="btn-secondary" disabled={fetching || c.protocol === 'azure'} onClick={fetchModels}>
              {fetching ? L('获取中…') : L('获取模型列表')}
            </button>
          </div>
          {modelMsg && <div class="hint" style={{ userSelect: 'text' }}>{modelMsg}</div>}
        </div>

        <label>{L('输出语言')}</label>
        <Menu
          hover={false}
          minWidth={220}
          items={OUTPUT_LANGUAGES.map((l) => ({ label: outputLanguageName(l.id), selected: l.id === c.outputLanguage, onClick: () => set({ outputLanguage: l.id }) }))}
          trigger={({ open, toggle }) => <SelectField width={220} text={outputLanguageName(c.outputLanguage)} open={open} onClick={toggle} />}
        />
      </div>

      {!embedded && <FavoriteModels />}

      <button class="btn-link" style={{ margin: '14px 0 0 122px', display: 'inline-flex', alignItems: 'center', gap: 4 }} onClick={() => setAdvanced(!advanced)}>
        {L('高级')}
        <Icon name={advanced ? 'chevronUp' : 'chevronDown'} size={12} />
      </button>
      {advanced && (
        <div class="form" style={{ marginTop: 12 }}>
          <label>temperature</label>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <label class="check-row" style={{ margin: 0 }}>
              <input type="checkbox" checked={c.temperatureEnabled} onChange={(e) => set({ temperatureEnabled: e.currentTarget.checked })} />
              {L('发送')}
            </label>
            <input
              class="field"
              style={{ width: 80 }}
              disabled={!c.temperatureEnabled}
              value={c.temperature}
              onChange={(e) => set({ temperature: num(e.currentTarget.value, 0.3) })}
            />
            {c.protocol === 'anthropic' && <span class="hint" style={{ margin: 0 }}>{L('当前 Claude 模型不接受 temperature，建议不发送')}</span>}
          </div>
          <label>{L('最大输出 tokens')}</label>
          <input class="field" style={{ width: 120 }} value={c.maxOutputTokens} onChange={(e) => set({ maxOutputTokens: Math.round(num(e.currentTarget.value, 4096)) })} />
          <label>{L('超时（秒）')}</label>
          <input class="field" style={{ width: 120 }} value={c.timeout} onChange={(e) => set({ timeout: num(e.currentTarget.value, 180) })} />
          <label>{L('单次最大输入字数')}</label>
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
          <label style={{ alignSelf: 'start', paddingTop: 7 }}>{L('自定义 Header')}</label>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            {c.customHeaders.map((h, i) => (
              <div key={i} style={{ display: 'flex', gap: 6 }}>
                <input
                  class="field"
                  style={{ width: 150 }}
                  placeholder={L('名称')}
                  value={h.key}
                  onInput={(e) => set({ customHeaders: c.customHeaders.map((x, j) => (j === i ? { ...x, key: e.currentTarget.value } : x)) })}
                />
                <input
                  class="field"
                  style={{ flex: 1 }}
                  placeholder={L('值')}
                  value={h.value}
                  onInput={(e) => set({ customHeaders: c.customHeaders.map((x, j) => (j === i ? { ...x, value: e.currentTarget.value } : x)) })}
                />
                <button class="btn-icon" onClick={() => set({ customHeaders: c.customHeaders.filter((_, j) => j !== i) })} title={L('删除')}>
                  <Icon name="close" size={14} />
                </button>
              </div>
            ))}
            <div style={{ display: 'flex', gap: 16 }}>
              <button class="btn-link" style={{ fontSize: 12 }} onClick={() => set({ customHeaders: [...c.customHeaders, { key: '', value: '' }] })}>
                + {L('添加 Header')}
              </button>
              <button
                class="btn-link"
                style={{ fontSize: 12 }}
                title={L('遇到 HTTP 400 时自动去掉的参数会按服务记住，这里可以清除')}
                onClick={async () => {
                  await call('settings:resetCompat');
                  setResult({ ok: true, text: L('已清除，下次请求将重新尝试全部参数') });
                }}
              >
                {L('重置参数兼容记录')}
              </button>
            </div>
          </div>
        </div>
      )}

      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 16, paddingLeft: embedded ? 0 : 122 }}>
        <button class="btn-secondary" disabled={testing || !c.baseURL || !c.model} onClick={test}>
          {testing ? L('测试中…') : L('测试连接')}
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

/** Starred models, from any provider. Each can be picked in a minute's summary tab. */
function FavoriteModels() {
  const list = favorites.value;
  const current = favoriteKey(llm.value.presetID, llm.value.baseURL, llm.value.model);
  return (
    <div class="favorites">
      <div class="fav-head">
        <Icon name="starFill" size={13} class="star-on" />
        <span>{L('收藏的模型')}</span>
        {list.length > 0 && <span class="num fav-count">{list.length}</span>}
      </div>
      {list.length === 0 ? (
        <div class="fav-empty">{L('在模型列表里点 ☆ 收藏常用模型。生成纪要时，可以在每个妙记的纪要页直接切换收藏的模型。')}</div>
      ) : (
        <div class="fav-list">
          {list.map((f) => {
            const id = favoriteID(f);
            const p = preset(f.presetID);
            return (
              <div class="fav-row" key={id}>
                <StarButton on onClick={() => removeFavorite(id)} />
                <div class="fav-text">
                  <div class="fav-model">{f.model}</div>
                  <div class="fav-provider">{p ? presetName(p) : L('自定义')}</div>
                </div>
                {id === current ? (
                  <Tag text={L('默认')} />
                ) : (
                  <button class="btn-link fav-use" onClick={() => useFavoriteAsDefault(f)}>
                    {L('设为默认')}
                  </button>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

function Section({ title, footer, children }) {
  return (
    <div class="set-section">
      <div class="section-title">{title}</div>
      <div class="set-card">{children}</div>
      {footer && <div class="set-footer">{footer}</div>}
    </div>
  );
}

function GeneralForm() {
  const g = general.value;
  const [suffixes, setSuffixes] = useState(g.filenameSuffixes.join(', '));
  const [iconError, setIconError] = useState('');
  const saveSuffixes = (text) =>
    updateGeneral({
      filenameSuffixes: text
        .split(/[,，]/)
        .map((x) => x.trim())
        .filter(Boolean),
    });
  const systemLabel = L('跟随系统（{0}）', languageName(systemLanguage.value));
  const chooseIcon = async () => {
    try {
      const url = await call('icon:choose');
      if (url) {
        customIcon.value = url;
        setIconError('');
      }
    } catch (e) {
      setIconError(e.message);
    }
  };
  return (
    <div>
      <Section title={L('语言')}>
        <div class="set-row">
          <span>{L('界面语言')}</span>
          <Menu
            hover={false}
            align="right"
            minWidth={220}
            items={[
              { label: systemLabel, selected: !g.language, onClick: () => setUILanguage(null) },
              'sep',
              ...LANGUAGES.map((l) => ({ label: l.name, selected: g.language === l.id, onClick: () => setUILanguage(l.id) })),
            ]}
            trigger={({ open, toggle }) => <SelectField width={220} text={g.language ? languageName(g.language) : systemLabel} open={open} onClick={toggle} />}
          />
        </div>
      </Section>

      <Section title={L('文字记录')}>
        <label class="check-row">
          <input type="checkbox" checked={g.perCharHighlight} onChange={(e) => updateGeneral({ perCharHighlight: e.currentTarget.checked })} />
          {L('逐字高亮（按 cue 时长估算当前字）')}
        </label>
        <label class="check-row">
          <input type="checkbox" checked={g.insertComma} onChange={(e) => updateGeneral({ insertComma: e.currentTarget.checked })} />
          {L('拼接中文字幕时在无标点处补「，」')}
        </label>
      </Section>

      <Section title={L('播放@@settings')}>
        <label class="check-row">
          <input type="checkbox" checked={g.skipBlankEnabled} onChange={(e) => updateGeneral({ skipBlankEnabled: e.currentTarget.checked })} />
          {L('跳过空白片段')}
        </label>
        <div class="check-row" style={{ cursor: 'default' }}>
          {L('空白片段阈值')}
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
          {L('秒')}
        </div>
      </Section>

      <Section title={L('自动配对')} footer={L('导入时从文件名中去掉开头的 13 位时间戳和这些后缀（逗号分隔），用于默认标题和音视频与 SRT 的自动配对。')}>
        <div style={{ display: 'flex', gap: 8 }}>
          <input class="field" style={{ flex: 1 }} value={suffixes} placeholder="_FeishuMinutes, _Recording" onInput={(e) => setSuffixes(e.currentTarget.value)} onBlur={() => saveSuffixes(suffixes)} />
          <button
            class="btn-secondary"
            onClick={() => {
              setSuffixes(DEFAULT_SUFFIXES.join(', '));
              updateGeneral({ filenameSuffixes: DEFAULT_SUFFIXES });
            }}
          >
            {L('恢复默认')}
          </button>
          <button class="btn-secondary" onClick={() => saveSuffixes(suffixes)}>
            {L('保存')}
          </button>
        </div>
      </Section>

      <Section title={L('应用图标')} footer={L('同时用于任务栏、窗口和应用内各处的图标。建议上传 1024×1024 的正方形图片，四周透明的部分会被自动裁掉。')}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
          <Logo size={56} />
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            <div style={{ display: 'flex', gap: 8 }}>
              <button class="btn-secondary" onClick={chooseIcon}>
                {L('上传图片…')}
              </button>
              <button
                class="btn-secondary"
                disabled={!customIcon.value}
                onClick={async () => {
                  customIcon.value = await call('icon:reset');
                }}
              >
                {L('恢复默认')}
              </button>
            </div>
            {iconError && <div style={{ fontSize: 11, color: 'var(--error)' }}>{iconError}</div>}
          </div>
        </div>
      </Section>

      <Section title={L('存储')}>
        <div style={{ fontSize: 12, color: 'var(--text-3)' }}>{L('回收站中的妙记会一直保留，直到你手动彻底删除。导入时不会复制媒体文件。')}</div>
        <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--text)', marginTop: 6 }}>{L('删除妙记不会删除原始媒体文件。')}</div>
      </Section>
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
        <h2>{L('设置')}</h2>
        <button class="btn-icon" onClick={close}>
          <Icon name="close" />
        </button>
      </div>
      <div class="tabs" style={{ padding: '14px 24px 0' }}>
        <Tab title={L('智能纪要')} small selected={tab === 'api'} onClick={() => (settingsOpen.value = 'api')} />
        <Tab title={L('通用')} small selected={tab === 'general'} onClick={() => (settingsOpen.value = 'general')} />
      </div>
      <div class="settings-body">{tab === 'api' ? <APIForm /> : <GeneralForm />}</div>
    </Modal>
  );
}
