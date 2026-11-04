import { useEffect, useRef, useState } from 'preact/hooks';
import { goBack, general, updateGeneral, moveToTrash } from '../state.js';
import { createdDate, durationCN } from '../../core/time.js';
import { Icon, Logo, Tag, Menu, Tab } from './ui.jsx';
import { Player } from './Player.jsx';
import { LeftBottomPanel } from './Speakers.jsx';
import { TranscriptPanel } from './Transcript.jsx';
import { SummaryPanel } from './Summary.jsx';

function TopBar({ model }) {
  const m = model.minute.value;
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState('');
  const input = useRef(null);
  useEffect(() => {
    if (editing) {
      input.current?.focus();
      input.current?.select();
    }
  }, [editing]);
  const commit = () => {
    setEditing(false);
    model.renameTitle(draft);
  };
  const hasTranscript = !!model.transcript.value;
  return (
    <header class="topbar drag">
      <button class="btn-icon" style={{ width: 30, height: 30, color: 'var(--text)' }} onClick={goBack} title="返回列表（Ctrl+[）">
        <Icon name="back" size={18} />
      </button>
      <Logo size={32} />
      <div style={{ minWidth: 0, flex: '0 1 auto' }}>
        <div class="topbar-title">
          {editing ? (
            <input
              ref={input}
              class="title-input no-drag"
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
            <span
              class="title no-drag"
              title="双击修改标题"
              onDblClick={() => {
                setDraft(m.title);
                setEditing(true);
              }}
            >
              {m.title}
            </span>
          )}
          {model.tags.value.map((t) => (
            <Tag key={t.text} text={t.text} warn={t.warn} />
          ))}
        </div>
        <div class="topbar-sub">
          <span>{createdDate(m.createdAt)}</span>
          <span class="vsep" />
          <span>{durationCN(model.totalDuration)}</span>
        </div>
      </div>
      <div style={{ flex: 1 }} />
      <Menu
        align="right"
        items={[
          { label: '导出 SRT', disabled: !hasTranscript, onClick: () => model.export('srt') },
          { label: '导出 TXT（带时间戳与发言人）', disabled: !hasTranscript, onClick: () => model.export('txt') },
          { label: '导出 Markdown（纪要 + 文字记录）', onClick: () => model.export('markdown') },
        ]}
        trigger={({ toggle }) => (
          <button class="btn-primary" onClick={toggle}>
            <Icon name="share" size={14} />
            导出
          </button>
        )}
      />
      <Menu
        align="right"
        items={[
          { label: '重新导入 SRT…', onClick: () => model.chooseSRT() },
          { label: '更换媒体文件…', onClick: () => model.relocateMedia() },
          { label: '在资源管理器中显示', onClick: () => model.revealMedia() },
          'sep',
          { label: '移到回收站', danger: true, onClick: () => moveToTrash([m.id]) },
        ]}
        trigger={({ toggle }) => (
          <button class="btn-icon" style={{ width: 30, height: 30, color: 'var(--text)' }} onClick={toggle} title="更多">
            <Icon name="more" size={18} />
          </button>
        )}
      />
    </header>
  );
}

function RightCard({ model }) {
  const tab = model.rightTab.value;
  return (
    <section class="right-card">
      <div class="tabs">
        <Tab title="智能纪要" selected={tab === 'summary'} onClick={() => (model.rightTab.value = 'summary')} />
        <Tab title="文字记录" selected={tab === 'transcript'} onClick={() => (model.rightTab.value = 'transcript')} />
      </div>
      <div class="tab-stack">
        <div class={`tab-pane ${tab === 'summary' ? '' : 'hidden'}`}>
          <SummaryPanel model={model} />
        </div>
        <div class={`tab-pane ${tab === 'transcript' ? '' : 'hidden'}`}>
          <TranscriptPanel model={model} />
        </div>
      </div>
    </section>
  );
}

export function DetailPage({ model }) {
  const columns = useRef(null);
  const [width, setWidth] = useState(1100);
  const [height, setHeight] = useState(700);
  const split = Math.min(0.7, Math.max(0.38, general.value.detailSplit || 0.57));

  useEffect(() => {
    const el = columns.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      setWidth(el.clientWidth - 16);
      setHeight(el.clientHeight);
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Re-render the transcript when comma insertion is toggled in settings.
  const comma = general.value.insertComma;
  const firstComma = useRef(comma);
  useEffect(() => {
    if (firstComma.current !== comma) model.rebuildBodies();
    firstComma.current = comma;
  }, [comma]);

  const leftWidth = Math.round(width * split);
  const videoHeight = Math.round(Math.min((leftWidth * 9) / 16, Math.max(220, height - 170)));

  const startDrag = (e) => {
    e.preventDefault();
    const startX = e.clientX;
    const start = split;
    let latest = start;
    const move = (ev) => {
      latest = Math.min(0.7, Math.max(0.38, (start * width + ev.clientX - startX) / width));
      general.value = { ...general.value, detailSplit: latest };
    };
    const up = () => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      updateGeneral({ detailSplit: latest });
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  };

  return (
    <div class="detail">
      <TopBar model={model} />
      <div class="columns" ref={columns}>
        <div class="left-col" style={{ width: leftWidth }}>
          <Player model={model} height={videoHeight} />
          <LeftBottomPanel model={model} />
        </div>
        <div class="split-handle" onMouseDown={startDrag} />
        <RightCard model={model} />
      </div>
    </div>
  );
}
