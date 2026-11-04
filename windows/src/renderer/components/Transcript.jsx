import { useEffect, useRef, useState } from 'preact/hooks';
import { TranscriptView } from '../transcriptView.js';
import { L } from '../../core/i18n.js';
import { Icon, MoreButton } from './ui.jsx';
import { exportMenuItems } from './DetailPage.jsx';

function EmptyTranscript({ model }) {
  return (
    <div class="empty-state">
      <div class="empty-art">
        <Icon name="bubble" />
      </div>
      <div class="empty-title">{L('还没有文字记录')}</div>
      <button class="btn-primary" onClick={() => model.chooseSRT()}>
        {L('导入 SRT 字幕')}
      </button>
      <div style={{ fontSize: 12 }}>{L('支持 .srt，可直接拖入窗口')}</div>
    </div>
  );
}

function Toolbar({ model }) {
  const input = useRef(null);
  const [focused, setFocused] = useState(false);
  const q = model.searchQuery.value;
  const hits = model.hits.value;
  const keywords = model.summary.value?.keywords || [];

  useEffect(() => {
    if (model.searchFocusToken.value) input.current?.focus();
  }, [model.searchFocusToken.value]);

  return (
    <div class="tx-toolbar">
      <div class="tx-search">
        <Icon name="search" style={{ color: 'var(--text-3)' }} />
        <input
          ref={input}
          placeholder={L('搜索')}
          value={q}
          onInput={(e) => {
            model.searchQuery.value = e.currentTarget.value;
            model.scheduleSearch();
          }}
          onFocus={() => {
            setFocused(true);
            model.searchFieldFocused = true;
          }}
          onBlur={() => {
            setTimeout(() => setFocused(false), 150);
            model.searchFieldFocused = false;
          }}
        />
        {q && (
          <>
            <span class="count num">{hits.length ? `${model.hitIndex.value + 1}/${hits.length}` : '0/0'}</span>
            <button class="btn-icon" style={{ width: 22, height: 22 }} disabled={!hits.length} onClick={() => model.moveHit(-1)} title={L('上一个（Shift+Enter）')}>
              <Icon name="chevronUp" size={14} />
            </button>
            <button class="btn-icon" style={{ width: 22, height: 22 }} disabled={!hits.length} onClick={() => model.moveHit(1)} title={L('下一个（Enter）')}>
              <Icon name="chevronDown" size={14} />
            </button>
          </>
        )}
        {focused && !q && keywords.length > 0 && (
          <div class="keywords-pop" onMouseDown={(e) => e.preventDefault()}>
            <div class="label">{L('推荐关键词')}</div>
            <div class="chips">
              {keywords.map((k) => (
                <button class="chip" key={k} onClick={() => model.searchKeyword(k)}>
                  {k}
                </button>
              ))}
            </div>
          </div>
        )}
      </div>
      {q && (
        <button
          class="btn-link"
          onClick={() => {
            model.clearSearch();
            input.current?.blur();
          }}
        >
          {L('取消')}
        </button>
      )}
      <MoreButton title={L('导出文字记录')} items={exportMenuItems(model)} />
    </div>
  );
}

/** Right-hand "文字记录" tab (§5). */
export function TranscriptPanel({ model }) {
  const scroller = useRef(null);
  const viewRef = useRef(null);
  const hasTranscript = !!model.transcript.value;
  const version = model.docVersion.value;
  // Built after the page transition, then faded in, so opening a minute never stalls.
  const revealed = model.transcriptRevealed.value;

  useEffect(() => {
    if (!hasTranscript || !revealed || !scroller.current) return;
    const view = new TranscriptView(scroller.current, model);
    viewRef.current = view;
    return () => {
      view.destroy();
      if (model.view === view) model.view = null;
      viewRef.current = null;
    };
  }, [hasTranscript, revealed]);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    view.render();
    model.viewReady(view);
  }, [version, hasTranscript, revealed]);

  if (!hasTranscript) return <EmptyTranscript model={model} />;
  return (
    <>
      <Toolbar model={model} />
      <div style={{ position: 'relative', flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
        <div class={`tx-scroll ${revealed ? 'revealed' : ''}`} ref={scroller} tabIndex={-1} />
        {!model.following.value && (
          <button class="back-btn" onClick={() => model.resumeFollowing()} title={L('回到当前播放位置')}>
            <Icon name={model.cueAbove.value ? 'chevronsUp' : 'chevronsDown'} size={18} />
          </button>
        )}
      </div>
    </>
  );
}
