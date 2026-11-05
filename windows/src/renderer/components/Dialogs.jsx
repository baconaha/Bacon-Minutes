// In-app dialogs that flip down from the top (Feishu style), replacing native message boxes
// for confirmations, like the Mac app.
import { useEffect, useRef, useState } from 'preact/hooks';
import { createPortal } from 'preact/compat';
import { confirmRequest, moveTarget, folderInfoTarget, folders, moveMinutes, folderByID, libraryStats, byteText, importReview } from '../state.js';
import { confirmImportReview } from '../importer.js';
import { duration, createdDate, compactDuration } from '../../core/time.js';
import { baseName } from '../../core/pairing.js';
import { L, listSeparator } from '../../core/i18n.js';
import { Icon, Checkbox, Menu, Skeleton, menuIsOpen } from './ui.jsx';

/** A fresh dialog for every request, even one set from the previous dialog's handler. */
const keys = new WeakMap();
let nextKey = 1;
export function dialogKey(obj) {
  if (!keys.has(obj)) keys.set(obj, nextKey++);
  return keys.get(obj);
}

/** Dimmed backdrop + card that flips down on open and folds up on close. */
function FlipDialog({ width = 440, onClosed, closeRef, children }) {
  const [closing, setClosing] = useState(false);
  const done = useRef(false);
  const close = () => {
    if (done.current) return;
    done.current = true;
    setClosing(true);
    setTimeout(onClosed, 150);
  };
  closeRef.current = close;
  useEffect(() => {
    const esc = (e) => {
      if (e.key === 'Escape') {
        // A picker open inside the dialog closes first.
        if (menuIsOpen()) return;
        e.stopPropagation();
        e.preventDefault();
        close();
      }
    };
    window.addEventListener('keydown', esc, true);
    return () => window.removeEventListener('keydown', esc, true);
  }, []);
  return createPortal(
    <div class={`flip-backdrop ${closing ? 'closing' : ''}`} onMouseDown={(e) => e.target === e.currentTarget && close()}>
      <div class="flip-card" style={{ width }} onMouseDown={(e) => e.stopPropagation()}>
        {children}
      </div>
    </div>,
    document.body,
  );
}

export function ConfirmDialog() {
  const req = confirmRequest.value;
  const closeRef = useRef(null);
  const confirmed = useRef(false);
  const button = useRef(null);
  const [checked, setChecked] = useState(false);
  const checkedRef = useRef(false);
  useEffect(() => button.current?.focus(), []);
  if (!req) return null;
  const destructive = req.destructive !== false;
  const finish = () => {
    if (confirmRequest.value === req) confirmRequest.value = null;
    if (!confirmed.current) return;
    if (checkedRef.current && req.onConfirmChecked) req.onConfirmChecked();
    else req.onConfirm();
  };
  const confirm = () => {
    confirmed.current = true;
    closeRef.current();
  };
  // With the box ticked the next step is another confirmation, so the button says so.
  const confirmTitle = checked && req.onConfirmChecked ? L('下一步') : req.confirmTitle;
  return (
    <FlipDialog onClosed={finish} closeRef={closeRef}>
      <div class="confirm">
        <div class={`confirm-mark ${destructive ? '' : 'info'}`}>{destructive ? '!' : 'i'}</div>
        <div class="confirm-text">
          <div class="confirm-title">{req.title}</div>
          <div class="confirm-message">{req.message}</div>
          {req.emphasis && <div class="confirm-emphasis">{req.emphasis}</div>}
          {req.checkbox && (
            <label
              class="confirm-check"
              onClick={(e) => {
                e.preventDefault();
                checkedRef.current = !checked;
                setChecked(!checked);
              }}
            >
              <Checkbox checked={checked} onChange={(v) => ((checkedRef.current = v), setChecked(v))} />
              <span>{req.checkbox}</span>
            </label>
          )}
        </div>
      </div>
      <div class="dialog-buttons" style={{ marginTop: 30 }}>
        <button class="btn-cancel" onClick={() => closeRef.current()}>
          {req.cancelTitle || L('取消')}
        </button>
        <button
          ref={button}
          class={destructive ? 'btn-danger' : 'btn-primary dialog'}
          onClick={confirm}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              confirm();
            }
          }}
        >
          {confirmTitle}
        </button>
      </div>
    </FlipDialog>
  );
}

// ---------- batch import review ----------

const names = (paths) => {
  const shown = paths.slice(0, 4).map(baseName).join(listSeparator());
  return paths.length > 4 ? shown + L(' 等') : shown;
};

/** Every detected video with its subtitle, one pair per row, and copy-into-app vs link. */
export function ImportReviewDialog() {
  const review = importReview.value;
  const closeRef = useRef(null);
  const confirmed = useRef(false);
  if (!review) return null;
  const rows = review.rows.value;
  const linkOnly = review.linkOnly.value;
  const included = rows.filter((r) => r.included);
  const all = rows.every((r) => r.included);
  const used = new Set(included.map((r) => r.subtitle).filter(Boolean));
  const unclaimed = review.subtitles.filter((s) => !used.has(s));
  const bytes = included.reduce((n, r) => n + (r.size || 0), 0);
  const folder = review.folderID && folderByID(review.folderID);
  const parts = [];
  if (review.sourceName) parts.push(L('来自「{0}」', review.sourceName));
  parts.push(L('检测到 {0} 个媒体文件、{1} 个字幕', rows.length, review.subtitles.length));
  if (folder) parts.push(L('将导入到「{0}」', folder.name));
  const finish = () => {
    importReview.value = null;
    review.cancelled = true;
    if (confirmed.current) confirmImportReview(review);
  };
  return (
    <FlipDialog width={720} onClosed={finish} closeRef={closeRef}>
      <div class="review">
        <div class="review-head">
          <div class="review-mark">
            <Icon name="importBox" size={20} />
          </div>
          <div class="review-titles">
            <div class="dialog-title">{rows.length === 1 ? L('导入妙记') : L('导入 {0} 个妙记', rows.length)}</div>
            <div class="review-sub">{parts.join(' · ')}</div>
          </div>
          {rows.length > 1 && (
            <button class="btn-link" onClick={() => (review.rows.value = rows.map((r) => ({ ...r, included: !all })))}>
              {all ? L('全不选') : L('全选')}
            </button>
          )}
        </div>
        <div class="review-list">
          {rows.map((r) => (
            <ReviewRow key={r.id} review={review} row={r} usedElsewhere={new Set(included.filter((x) => x.id !== r.id).map((x) => x.subtitle).filter(Boolean))} />
          ))}
          {unclaimed.length > 0 && (
            <div class="review-note">
              <Icon name="bubble" size={13} />
              <span>{L('{0} 个字幕没有配对：{1}。可以在右侧为视频指定。', unclaimed.length, names(unclaimed))}</span>
            </div>
          )}
          {review.skipped.length > 0 && (
            <div class="review-note">
              <Icon name="ban" size={13} />
              <span>{L('已跳过 {0} 个不支持的文件：{1}', review.skipped.length, names(review.skipped))}</span>
            </div>
          )}
        </div>
        <div class="review-foot">
          <div class={`review-storage ${linkOnly ? 'link' : ''}`}>
            <div class="rs-line">
              <Icon name={linkOnly ? 'link' : 'drive'} size={16} />
              <span>
                {linkOnly
                  ? L('妙记只记住源文件的位置，不会另外复制一份。')
                  : L('默认把源文件复制一份保存到应用内{0}。之后原文件移动、改名或删除，都不影响播放。', bytes > 0 ? L('（共 {0}）', byteText(bytes)) : '')}
              </span>
            </div>
            <label class="rs-check" onClick={(e) => (e.preventDefault(), (review.linkOnly.value = !linkOnly))}>
              <Checkbox checked={linkOnly} onChange={(v) => (review.linkOnly.value = v)} />
              <span>{L('只链接文件路径（不复制到应用）')}</span>
            </label>
            {linkOnly && <div class="rs-warn">{L('链接后，源文件被移动、改名，或所在的磁盘、NAS 断开时，需要在妙记里「重新检测路径」或重新导入。')}</div>}
          </div>
          <div class="dialog-buttons">
            <button class="btn-cancel" onClick={() => closeRef.current()}>
              {L('取消')}
            </button>
            <button
              class="btn-primary dialog"
              disabled={!included.length}
              onClick={() => {
                confirmed.current = true;
                closeRef.current();
              }}
            >
              {included.length === 1 ? L('导入') : L('导入 {0} 个', included.length)}
            </button>
          </div>
        </div>
      </div>
    </FlipDialog>
  );
}

function ReviewRow({ review, row, usedElsewhere }) {
  const details = [];
  if (row.inspected) {
    if (row.duration > 0) details.push(duration(row.duration));
    if (row.size > 0) details.push(byteText(row.size));
    if (!row.hasVideo) details.push(L('音频'));
  }
  const pick = (subtitle) => review.update(row.id, { subtitle, guessed: false });
  const items = [
    { label: L('不使用字幕'), icon: 'ban', selected: !row.subtitle, onClick: () => pick(null) },
    review.subtitles.length ? 'sep' : null,
    ...review.subtitles.map((s) => ({
      label: usedElsewhere.has(s) ? L('{0}（已用于其他视频）', baseName(s)) : baseName(s),
      icon: 'bubble',
      selected: row.subtitle === s,
      onClick: () => pick(s),
    })),
  ];
  return (
    <div class={`review-row ${row.included ? '' : 'off'}`}>
      <Checkbox checked={row.included} onChange={(v) => review.update(row.id, { included: v })} />
      <div class="rr-thumb">
        {row.cover ? (
          <img src={`data:image/jpeg;base64,${row.cover}`} alt="" />
        ) : row.inspected ? (
          <Icon name={row.hasVideo ? 'film' : 'waveform'} size={20} />
        ) : (
          <Skeleton w="100%" h="100%" r={0} />
        )}
        {row.duration > 0 && <span class="rr-badge">{compactDuration(row.duration)}</span>}
      </div>
      <div class="rr-text">
        <div class="rr-name" title={row.media}>
          {baseName(row.media)}
        </div>
        <div class="rr-meta">{row.inspected ? details.join(' · ') || '—' : L('正在读取…')}</div>
      </div>
      <Icon name="arrowRight" size={13} class={`rr-arrow ${row.subtitle ? '' : 'dim'}`} />
      <div class="rr-sub">
        <Menu
          hover={false}
          align="right"
          minWidth={240}
          items={items}
          trigger={({ open, toggle }) => (
            <button class={`rr-pick ${open ? 'open' : ''} ${row.guessed ? 'guessed' : ''} ${row.subtitle ? '' : 'none'}`} disabled={!row.included} onClick={toggle}>
              <Icon name="bubble" size={14} />
              <span class="rr-pick-text">{row.subtitle ? baseName(row.subtitle) : L('无字幕')}</span>
              <Icon name="chevronDown" size={11} class="sf-chevron" />
            </button>
          )}
        />
        {row.guessed && <div class="rr-guess">{L('按文件夹推测，请确认')}</div>}
      </div>
    </div>
  );
}

export function FolderInfoDialog() {
  const id = folderInfoTarget.value;
  const closeRef = useRef(null);
  if (!id) return null;
  const folder = folderByID(id);
  const stats = libraryStats(id);
  const rows = [
    [L('妙记数量'), L('{0} 个', stats.count)],
    [L('总时长'), stats.count > 0 ? duration(stats.duration) : '—'],
    [L('总大小'), byteText(stats.bytes)],
    [L('创建时间'), folder ? createdDate(folder.createdAt) : '—'],
  ];
  return (
    <FlipDialog width={380} onClosed={() => (folderInfoTarget.value = null)} closeRef={closeRef}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
        <Icon name="folderFill" size={30} style={{ color: 'var(--brand)' }} />
        <div style={{ minWidth: 0 }}>
          <div class="dialog-title" style={{ overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {folder?.name || L('文件夹')}
          </div>
          <div style={{ fontSize: 12, color: 'var(--text-3)', marginTop: 3 }}>{L('属性')}</div>
        </div>
      </div>
      <div class="dialog-divider" />
      <div class="info-grid dialog-info">
        {rows.map(([k, v]) => [
          <span class="k" key={k}>
            {k}
          </span>,
          <span class="v num" key={k + 'v'}>
            {v}
          </span>,
        ])}
      </div>
      <div class="dialog-buttons" style={{ marginTop: 22 }}>
        <button class="btn-primary" onClick={() => closeRef.current()} autoFocus>
          {L('好')}
        </button>
      </div>
    </FlipDialog>
  );
}

export function MoveToFolderDialog() {
  const ids = moveTarget.value;
  const closeRef = useRef(null);
  const [choice, setChoice] = useState(undefined);
  const applied = useRef(false);
  if (!ids) return null;
  const list = folders.value;
  const finish = () => {
    moveTarget.value = null;
    if (applied.current) moveMinutes(ids, choice || null);
  };
  const option = (id, title, icon) => {
    const selected = choice !== undefined && (choice || null) === id;
    return (
      <button key={id || 'none'} class={`move-option ${selected ? 'selected' : ''}`} onClick={() => setChoice(id)}>
        <Icon name={icon} />
        <span class="mo-title">{title}</span>
        {selected && <Icon name="check" size={14} />}
      </button>
    );
  };
  return (
    <FlipDialog width={400} onClosed={finish} closeRef={closeRef}>
      <div class="dialog-title">{ids.length === 1 ? L('移动到文件夹') : L('将 {0} 个妙记移动到文件夹', ids.length)}</div>
      {list.length === 0 ? (
        <div style={{ fontSize: 13, color: 'var(--text-3)', marginTop: 16 }}>{L('还没有文件夹。可以在左侧边栏「文件夹」旁点 + 新建。')}</div>
      ) : (
        <div class="move-list">
          {option(null, L('不放入文件夹'), 'tray')}
          {list.map((f) => option(f.id, f.name, 'folder'))}
        </div>
      )}
      <div class="dialog-buttons" style={{ marginTop: 18 }}>
        <button class="btn-cancel" onClick={() => closeRef.current()}>
          {L('取消')}
        </button>
        <button
          class="btn-primary"
          disabled={!list.length || choice === undefined}
          onClick={() => {
            applied.current = true;
            closeRef.current();
          }}
        >
          {L('移动')}
        </button>
      </div>
    </FlipDialog>
  );
}
