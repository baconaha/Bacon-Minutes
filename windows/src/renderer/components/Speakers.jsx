import { useEffect, useRef, useState } from 'preact/hooks';
import { timestamp, duration, createdDate } from '../../core/time.js';
import { L } from '../../core/i18n.js';
import { Avatar, Tab, useContextMenu } from './ui.jsx';

function Track({ model, intervals }) {
  const ref = useRef(null);
  const [hover, setHover] = useState(null);
  const d = Math.max(model.totalDuration, 0.001);
  const w = ref.current?.clientWidth || 1;
  return (
    <div
      class="track"
      ref={ref}
      onMouseMove={(e) => setHover(Math.min(Math.max(e.offsetX, 0), w))}
      onMouseLeave={() => setHover(null)}
      onClick={(e) => {
        const r = ref.current.getBoundingClientRect();
        model.jumpToTime(((e.clientX - r.left) / r.width) * d, model.playing.value);
      }}
    >
      <div class="bar">
        {intervals.map(([a, b], i) => (
          <span key={i} style={{ left: `${(a / d) * 100}%`, width: `${((b - a) / d) * 100}%` }} />
        ))}
      </div>
      {hover != null && (
        <div class="bubble num" style={{ left: Math.min(Math.max(hover - 24, 0), w - 56) }}>
          {timestamp((hover / w) * d, model.hours)}
        </div>
      )}
    </div>
  );
}

function SpeakerRow({ model, speaker, openContext }) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState('');
  const input = useRef(null);
  useEffect(() => {
    if (editing) {
      input.current?.focus();
      input.current?.select();
    }
  }, [editing]);
  const begin = () => {
    setDraft(speaker.name);
    setEditing(true);
  };
  const commit = () => {
    setEditing(false);
    model.renameSpeaker(speaker.id, draft);
  };
  return (
    <div class="speaker">
      <div class="speaker-head" onContextMenu={(e) => openContext(e, [{ label: L('重命名'), onClick: begin }])}>
        <Avatar name={speaker.name} color={speaker.colorHex} />
        {editing ? (
          <input
            ref={input}
            class="field"
            style={{ height: 26, width: 200 }}
            value={draft}
            onInput={(e) => setDraft(e.currentTarget.value)}
            onBlur={commit}
            onKeyDown={(e) => {
              if (e.key === 'Enter') commit();
              if (e.key === 'Escape') {
                e.stopPropagation();
                setEditing(false);
              }
            }}
          />
        ) : (
          <span class="speaker-name" title={L('点击重命名')} onClick={begin}>
            {speaker.name}
          </span>
        )}
        <span class="speaker-pct num">{model.percentages.value[speaker.id] ?? 0}%</span>
      </div>
      <Track model={model} intervals={model.intervals.value[speaker.id] || []} />
    </div>
  );
}

function FileInfo({ model }) {
  const m = model.minute.value;
  const tr = model.transcript.value;
  const rows = [
    ['media', L('媒体文件'), m.mediaFileName],
    ['path', L('媒体路径'), null],
    ['duration', L('时长'), duration(model.totalDuration)],
    ['srt', L('SRT 文件'), m.srtFileName || L('未导入')],
    ['cues', L('字幕条数'), String(tr?.cues.length ?? 0)],
    ['speakers', L('发言人数'), String(tr?.speakers.length ?? 0)],
    ['created', L('创建时间'), createdDate(m.createdAt)],
    ['opened', L('最近打开'), m.lastOpenedAt ? createdDate(m.lastOpenedAt) : '—'],
  ];
  return (
    <div class="info-grid">
      {rows.map(([id, k, v]) => [
        <span class="k" key={id}>
          {k}
        </span>,
        id === 'path' ? (
          <button class="btn-link v" style={{ textAlign: 'left', wordBreak: 'break-all' }} onClick={() => model.revealMedia()} title={L('在资源管理器中显示')} key={id + 'v'}>
            {m.mediaPath || '—'}
          </button>
        ) : (
          <span class="v" key={id + 'v'}>
            {v}
          </span>
        ),
      ])}
    </div>
  );
}

/** "发言人 (N)" / "文件信息" under the video (§4). */
export function LeftBottomPanel({ model }) {
  const [openContext, contextNode] = useContextMenu();
  const tab = model.leftTab.value;
  const tr = model.transcript.value;
  return (
    <div class="left-bottom">
      <div class="tabs small">
        <Tab small title={L('发言人 ({0})', tr?.speakers.length ?? 0)} selected={tab === 'speakers'} onClick={() => (model.leftTab.value = 'speakers')} />
        <Tab small title={L('文件信息')} selected={tab === 'fileInfo'} onClick={() => (model.leftTab.value = 'fileInfo')} />
      </div>
      <div class="left-scroll">
        {tab === 'fileInfo' ? (
          <FileInfo model={model} />
        ) : tr ? (
          tr.speakers.map((s) => <SpeakerRow key={s.id} model={model} speaker={s} openContext={openContext} />)
        ) : (
          <div style={{ color: 'var(--text-3)' }}>{L('导入 SRT 后显示发言人与发言时段')}</div>
        )}
      </div>
      {contextNode}
    </div>
  );
}
