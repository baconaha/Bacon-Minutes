import { useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks';
import { goBack, general, updateGeneral, requestMoveToTrash, copyingMedia, requestImportIntoApp } from '../state.js';
import { createdDate, duration } from '../../core/time.js';
import { L } from '../../core/i18n.js';
import { Icon, Logo, Tag, Menu, Tab } from './ui.jsx';
import { Player } from './Player.jsx';
import { LeftBottomPanel } from './Speakers.jsx';
import { TranscriptPanel } from './Transcript.jsx';
import { SummaryPanel } from './Summary.jsx';

/** Shared by the top bar "导出" button and the transcript "···" menu (§2, §5.1). */
export function exportMenuItems(model) {
  const none = !model.transcript.value;
  return [
    { label: L('导出 SRT'), icon: 'bubble', disabled: none, onClick: () => model.export('srt') },
    { label: L('导出 TXT（带时间戳与发言人）'), icon: 'doc', disabled: none, onClick: () => model.export('txt') },
    { label: L('导出 Markdown（纪要 + 文字记录）'), icon: 'docPlus', onClick: () => model.export('markdown') },
    'sep',
    { label: L('导出纪要文件（.{0}）', 'baconsummary'), icon: 'sparkle', disabled: !model.summary.value, onClick: () => model.exportSummaryFile() },
  ];
}

/** "应用内" or "链接": where the media lives. The link tag opens a menu with the path. */
function StorageTag({ model }) {
  const m = model.minute.value;
  const p = copyingMedia.value.get(m.id);
  if (p != null)
    return (
      <span class="storage-badge accent num">
        <Icon name="download" size={11} />
        {L('正在导入应用 {0}%', Math.round(p * 100))}
      </span>
    );
  if (m.storage === 'imported')
    return (
      <span class="storage-badge accent" title={L('源文件已复制到应用内，原文件移动或删除都不影响播放。')}>
        <Icon name="drive" size={11} />
        {L('应用内')}
      </span>
    );
  return (
    <Menu
      hover={false}
      minWidth={280}
      title={L('只链接了源文件的路径，点击查看')}
      items={[
        { label: m.mediaPath || m.mediaFileName, icon: 'doc', disabled: true },
        'sep',
        { label: L('在资源管理器中显示'), icon: 'folder', onClick: () => model.revealMedia() },
        { label: L('将源文件导入应用…'), icon: 'drive', onClick: () => requestImportIntoApp(m.id) },
      ]}
      trigger={({ open, toggle }) => (
        <button class={`storage-badge ${open ? 'open' : ''}`} onClick={toggle}>
          <Icon name="link" size={11} />
          {L('链接')}
          <Icon name="chevronDown" size={9} />
        </button>
      )}
    />
  );
}

/**
 * Title that edits in place, like a Google Docs title: I-beam on hover, a click puts the caret
 * there, Enter or a click anywhere else saves, Esc restores the old title.
 */
function EditableTitle({ model }) {
  const title = model.minute.value.title;
  const [draft, setDraft] = useState(title);
  const [editing, setEditing] = useState(false);
  const [width, setWidth] = useState(0);
  const input = useRef(null);
  const measure = useRef(null);
  const cancelled = useRef(false);

  useEffect(() => {
    if (!editing) setDraft(title);
  }, [title]);
  useLayoutEffect(() => {
    if (measure.current) setWidth(Math.min(520, Math.max(40, Math.ceil(measure.current.getBoundingClientRect().width) + 6)));
  }, [draft, title]);

  const end = () => {
    setEditing(false);
    if (cancelled.current) {
      cancelled.current = false;
      setDraft(title);
      return;
    }
    const t = draft.trim();
    if (!t) setDraft(title);
    else if (t !== title) model.renameTitle(t);
  };

  return (
    <span class={`title-edit ${editing ? 'editing' : ''}`}>
      <span class="title-measure" ref={measure} aria-hidden="true">
        {draft || title}
      </span>
      <input
        ref={input}
        class="title-input"
        value={draft}
        spellcheck={false}
        style={{ width }}
        title={editing ? '' : L('点击修改标题')}
        onFocus={() => setEditing(true)}
        onInput={(e) => setDraft(e.currentTarget.value)}
        onBlur={end}
        onKeyDown={(e) => {
          if (e.key === 'Enter') {
            e.preventDefault();
            input.current.blur();
          } else if (e.key === 'Escape') {
            e.preventDefault();
            e.stopPropagation();
            cancelled.current = true;
            input.current.blur();
          }
        }}
      />
    </span>
  );
}

function TopBar({ model }) {
  const m = model.minute.value;
  return (
    <header class="topbar drag">
      <button class="btn-icon back-button" onClick={goBack} title={L('返回列表（Ctrl+[）')}>
        <Icon name="back" size={18} />
      </button>
      <Logo size={32} />
      <div style={{ minWidth: 0, flex: '0 1 auto' }}>
        <div class="topbar-title">
          <EditableTitle model={model} />
          <StorageTag model={model} />
          {model.tags.value.map((t) => (
            <Tag key={t.text} text={t.text} warn={t.warn} />
          ))}
        </div>
        <div class="topbar-sub">
          <span>{createdDate(m.createdAt)}</span>
          <span class="vsep" />
          <span>{duration(model.totalDuration)}</span>
        </div>
      </div>
      <div style={{ flex: 1 }} />
      <Menu
        align="right"
        minWidth={200}
        items={exportMenuItems(model)}
        trigger={({ toggle }) => (
          <button class="btn-primary" onClick={toggle}>
            <Icon name="share" size={14} />
            {L('导出')}
          </button>
        )}
      />
      <Menu
        align="right"
        title={L('更多')}
        minWidth={190}
        items={[
          { label: L('重新导入 SRT…'), icon: 'bubble', onClick: () => model.chooseSRT() },
          { label: L('导入纪要文件…'), icon: 'docPlus', onClick: () => model.chooseAndImportSummaryFile() },
          { label: L('更换媒体文件…'), icon: 'film', onClick: () => model.relocateMedia() },
          { label: L('在资源管理器中显示'), icon: 'folder', onClick: () => model.revealMedia() },
          m.storage !== 'imported' && { label: L('将源文件导入应用…'), icon: 'drive', disabled: copyingMedia.value.has(m.id), onClick: () => requestImportIntoApp(m.id) },
          'sep',
          { label: L('移到回收站'), icon: 'trash', danger: true, onClick: () => requestMoveToTrash([m.id]) },
        ]}
        trigger={({ open, toggle }) => (
          <button class={`btn-icon ${open ? 'active-bg' : ''}`} style={{ width: 30, height: 30, color: 'var(--text)' }} onClick={toggle}>
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
        <Tab title={L('智能纪要')} selected={tab === 'summary'} onClick={() => (model.rightTab.value = 'summary')} />
        <Tab title={L('文字记录')} selected={tab === 'transcript'} onClick={() => (model.rightTab.value = 'transcript')} />
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

  // Back from Explorer, where the file may have been moved back: look again, quietly.
  useEffect(() => {
    const onFocus = () => {
      if (model.mediaState.value === 'missing') model.recheckMedia(true);
    };
    window.addEventListener('focus', onFocus);
    return () => window.removeEventListener('focus', onFocus);
  }, [model]);

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
    <div class="detail detail-enter">
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
