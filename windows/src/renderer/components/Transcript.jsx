import { useEffect, useRef, useState } from 'preact/hooks';
import { TranscriptView } from '../transcriptView.js';
import { Icon, Menu } from './ui.jsx';

function EmptyTranscript({ model }) {
  return (
    <div class="empty-state">
      <div class="empty-art">
        <Icon name="bubble" />
      </div>
      <div class="empty-title">还没有文字记录</div>
      <button class="btn-primary" onClick={() => model.chooseSRT()}>
        导入 SRT 字幕
      </button>
      <div style={{ fontSize: 12 }}>支持 .srt，可直接拖入窗口</div>
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
          placeholder="搜索"
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
            <button class="btn-icon" style={{ width: 22, height: 22 }} disabled={!hits.length} onClick={() => model.moveHit(-1)} title="上一个（Shift+Enter）">
              <Icon name="chevronUp" size={14} />
            </button>
            <button class="btn-icon" style={{ width: 22, height: 22 }} disabled={!hits.length} onClick={() => model.moveHit(1)} title="下一个（Enter）">
              <Icon name="chevronDown" size={14} />
            </button>
          </>
        )}
        {focused && !q && keywords.length > 0 && (
          <div class="keywords-pop" onMouseDown={(e) => e.preventDefault()}>
            <div class="label">推荐关键词</div>
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
          取消
        </button>
      )}
      <Menu
        align="right"
        items={[
          { label: '导出 SRT', onClick: () => model.export('srt') },
          { label: '导出 TXT（带时间戳与发言人）', onClick: () => model.export('txt') },
          { label: '导出 Markdown（纪要 + 文字记录）', onClick: () => model.export('markdown') },
        ]}
        trigger={({ toggle }) => (
          <button class="btn-icon" onClick={toggle} title="导出文字记录">
            <Icon name="more" />
          </button>
        )}
      />
    </div>
  );
}

/** Right-hand "文字记录" tab (§5). */
export function TranscriptPanel({ model }) {
  const scroller = useRef(null);
  const viewRef = useRef(null);
  const hasTranscript = !!model.transcript.value;
  const version = model.docVersion.value;

  useEffect(() => {
    if (!hasTranscript || !scroller.current) return;
    const view = new TranscriptView(scroller.current, model);
    viewRef.current = view;
    return () => {
      view.destroy();
      if (model.view === view) model.view = null;
      viewRef.current = null;
    };
  }, [hasTranscript]);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    view.render();
    model.viewReady(view);
  }, [version, hasTranscript]);

  if (!hasTranscript) return <EmptyTranscript model={model} />;
  return (
    <>
      <Toolbar model={model} />
      <div style={{ position: 'relative', flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
        <div class="tx-scroll" ref={scroller} tabIndex={-1} />
        {!model.following.value && (
          <button class="back-btn" onClick={() => model.resumeFollowing()} title="回到当前播放位置">
            <Icon name={model.cueAbove.value ? 'chevronsUp' : 'chevronsDown'} size={18} />
          </button>
        )}
      </div>
    </>
  );
}
