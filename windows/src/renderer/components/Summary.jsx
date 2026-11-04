import { useLayoutEffect, useRef, useState } from 'preact/hooks';
import { llmReady, settingsOpen } from '../state.js';
import { timestamp, createdDate } from '../../core/time.js';
import { L } from '../../core/i18n.js';
import { Icon, MoreButton, Skeleton } from './ui.jsx';
import { APIForm } from './Settings.jsx';

function CardTitle({ title, children }) {
  return (
    <div class="ai-title">
      <Icon name="sparkle" size={15} class="sparkle" />
      <span class="t">{title}</span>
      <span class="grow" />
      {children}
    </div>
  );
}

/** Clips to ~8 lines with "展开 ⌄ / 收起 ⌃" (§6.1). */
function Collapsible({ children }) {
  const ref = useRef(null);
  const [tall, setTall] = useState(false);
  const [expanded, setExpanded] = useState(false);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => setTall(el.scrollHeight > 196);
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  });
  return (
    <>
      <div ref={ref} class={`collapsible ${tall && !expanded ? 'clipped' : ''}`}>
        {children}
      </div>
      {tall && (
        <button class="btn-link" style={{ marginTop: 6 }} onClick={() => setExpanded(!expanded)}>
          {expanded ? L('收起 ⌃') : L('展开 ⌄')}
        </button>
      )}
    </>
  );
}

function MeetingCard({ model, s }) {
  const hours = model.hours;
  return (
    <div class="ai-card">
      <CardTitle title={L('会议纪要')} />
      <Collapsible>
        {s.overview && <div class="overview">{s.overview}</div>}
        {s.keyPoints.map((kp, i) => (
          <div class="kp" key={i}>
            <div>
              {kp.title && <b>{kp.title + L('：')}</b>}
              {kp.content}
            </div>
          </div>
        ))}
      </Collapsible>
      <div class="todo-title">{L('待办')}</div>
      {s.todos.length === 0 ? (
        <div style={{ color: 'var(--text-3)' }}>{L('本场会议无待办内容')}</div>
      ) : (
        s.todos.map((t, i) => (
          <div class="todo" key={i}>
            <span class="box" />
            <span>{t.content}</span>
            <span class="meta">· {t.owner} ·</span>
            <button class="btn-link num" onClick={() => model.jumpToTime(t.time)}>
              {timestamp(t.time, hours)}
            </button>
          </div>
        ))
      )}
    </div>
  );
}

/**
 * One chapter. "展开" appears whenever the two-line summary is cut off (not only on hover), so
 * hovering never shifts the text.
 */
function ChapterRow({ model, c, last, expanded, toggle }) {
  const sum = useRef(null);
  const [cut, setCut] = useState(false);
  useLayoutEffect(() => {
    const el = sum.current;
    if (!el) return;
    const measure = () => setCut(!expanded && el.scrollHeight > el.clientHeight + 1);
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [expanded, c.summary]);
  return (
    <div class="chapter">
      <span class="time">{timestamp(c.time, model.hours)}</span>
      <span class="dot" />
      {!last && <span class="line" />}
      <div class="body">
        <button class="ctitle" onClick={() => model.jumpToTime(c.time)} title={L('跳到本章节并播放')}>
          {c.title}
        </button>
        <div ref={sum} class={`csum ${expanded ? '' : 'clamp'}`}>
          {c.summary}
        </div>
        {(expanded || cut) && (
          <button class="btn-link expand" onClick={toggle}>
            {expanded ? L('收起') : L('展开')}
          </button>
        )}
      </div>
    </div>
  );
}

function ChapterCard({ model, s }) {
  const [all, setAll] = useState(false);
  const [open, setOpen] = useState(() => new Set());
  return (
    <div class="ai-card">
      <CardTitle title={L('章节纪要')}>
        <button
          class="btn-link"
          style={{ fontSize: 12 }}
          onClick={() => {
            setAll(!all);
            setOpen(new Set());
          }}
        >
          {all ? L('收起全部') : L('展开全部')}
        </button>
      </CardTitle>
      {s.chapters.map((c, i) => (
        <ChapterRow
          key={i}
          model={model}
          c={c}
          last={i === s.chapters.length - 1}
          expanded={all || open.has(i)}
          toggle={() => {
            const next = new Set(open);
            if (next.has(i)) next.delete(i);
            else next.add(i);
            setOpen(next);
          }}
        />
      ))}
    </div>
  );
}

function ErrorCard({ message, retry }) {
  return (
    <div class="error-card">
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontWeight: 600 }}>
        <Icon name="warning" style={{ color: 'var(--error)' }} />
        {L('生成失败')}
      </div>
      <div class="msg">{message}</div>
      <button class="btn-primary compact" onClick={retry}>
        {L('重试')}
      </button>
    </div>
  );
}

function Placeholder({ icon, title, message, children }) {
  return (
    <div class="empty-state">
      <div class="placeholder-art">
        <Icon name={icon} />
      </div>
      <div class="empty-title">{title}</div>
      <div style={{ fontSize: 12 }}>{message}</div>
      {children}
    </div>
  );
}

function Generating({ text, cancel }) {
  return (
    <div class="generating">
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 18, color: 'var(--text-2)' }}>
        <Icon name="sparkle" class="sparkle" />
        <span>{text}</span>
        <span style={{ flex: 1 }} />
        <button class="btn-link" onClick={cancel}>
          {L('取消')}
        </button>
      </div>
      {[0, 1].map((i) => (
        <div class="ai-card" key={i} style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          <Skeleton w={120} h={14} />
          <Skeleton h={12} />
          <Skeleton h={12} />
          <Skeleton w={240} h={12} />
          <Skeleton h={12} />
          <Skeleton w={180} h={12} />
        </div>
      ))}
    </div>
  );
}

/** Right-hand "智能纪要" tab (§6). */
export function SummaryPanel({ model }) {
  const state = model.summaryState.value;
  const s = model.summary.value;
  let content;
  if (state.status === 'generating') {
    content = <Generating text={state.text} cancel={() => model.cancelGeneration()} />;
  } else if (s) {
    content = (
      <div class="sum-scroll">
        <div style={{ display: 'flex', alignItems: 'center', marginBottom: 12 }}>
          <span style={{ fontSize: 11, color: 'var(--text-3)' }}>
            {s.model} · {createdDate(s.generatedAt)}
          </span>
          <span style={{ flex: 1 }} />
          <MoreButton
            items={[
              { label: L('重新生成'), icon: 'refresh', onClick: () => model.generate() },
              { label: L('复制为 Markdown'), icon: 'copy', onClick: () => model.copySummaryMarkdown() },
            ]}
          />
        </div>
        {state.status === 'failed' && <ErrorCard message={state.message} retry={() => model.generate()} />}
        {model.stale.value && (
          <div class="banner">
            <Icon name="warning" size={14} />
            {L('文字记录已变更，纪要可能过期 ·')}
            <button class="btn-link" style={{ fontSize: 12 }} onClick={() => model.generate()}>
              {L('重新生成')}
            </button>
          </div>
        )}
        <MeetingCard model={model} s={s} />
        <ChapterCard model={model} s={s} />
      </div>
    );
  } else if (state.status === 'failed') {
    content = (
      <div class="sum-scroll">
        <ErrorCard message={state.message} retry={() => model.generate()} />
        {!llmReady.value && <APIForm embedded />}
      </div>
    );
  } else if (!model.transcript.value) {
    content = (
      <Placeholder icon="bubble" title={L('还没有文字记录')} message={L('导入 SRT 字幕后即可生成智能纪要')}>
        <button class="btn-primary" onClick={() => model.chooseSRT()}>
          {L('导入 SRT 字幕')}
        </button>
      </Placeholder>
    );
  } else if (!llmReady.value) {
    content = (
      <div class="sum-scroll">
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10, margin: '12px 0 20px', color: 'var(--text-3)' }}>
          <div class="placeholder-art">
            <Icon name="sparkle" />
          </div>
          <div class="empty-title">{L('配置 API 后即可生成智能纪要')}</div>
          <div style={{ fontSize: 12 }}>{L('支持 OpenAI 兼容、Anthropic、Azure OpenAI 以及本地模型服务')}</div>
        </div>
        <APIForm embedded />
        <div style={{ display: 'flex', justifyContent: 'center', marginTop: 16 }}>
          <button class="btn-primary" disabled={!llmReady.value} onClick={() => model.generate()}>
            {L('保存并生成')}
          </button>
        </div>
      </div>
    );
  } else {
    content = (
      <Placeholder icon="sparkle" title={L('让 AI 帮你整理这段内容')} message={L('将生成总述、要点、待办、章节与关键词')}>
        <button class="btn-primary" onClick={() => model.generate()}>
          {L('生成智能纪要')}
        </button>
        <button class="btn-link" style={{ fontSize: 12 }} onClick={() => (settingsOpen.value = 'api')}>
          {L('API 设置')}
        </button>
      </Placeholder>
    );
  }
  return (
    <>
      <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>{content}</div>
      <div class="sum-footer">{L('智能纪要由 AI 生成，请谨慎使用')}</div>
    </>
  );
}
