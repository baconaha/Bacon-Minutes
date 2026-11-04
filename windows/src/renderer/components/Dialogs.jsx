// In-app dialogs that flip down from the top (Feishu style), replacing native message boxes
// for confirmations, like the Mac app.
import { useEffect, useRef, useState } from 'preact/hooks';
import { createPortal } from 'preact/compat';
import { confirmRequest, moveTarget, folderInfoTarget, folders, moveMinutes, folderByID, libraryStats, byteText } from '../state.js';
import { duration, createdDate } from '../../core/time.js';
import { L } from '../../core/i18n.js';
import { Icon } from './ui.jsx';

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
  useEffect(() => button.current?.focus(), []);
  if (!req) return null;
  const finish = () => {
    confirmRequest.value = null;
    if (confirmed.current) req.onConfirm();
  };
  return (
    <FlipDialog onClosed={finish} closeRef={closeRef}>
      <div class="confirm">
        <div class="confirm-mark">!</div>
        <div class="confirm-text">
          <div class="confirm-title">{req.title}</div>
          <div class="confirm-message">{req.message}</div>
          {req.emphasis && <div class="confirm-emphasis">{req.emphasis}</div>}
        </div>
      </div>
      <div class="dialog-buttons" style={{ marginTop: 30 }}>
        <button class="btn-cancel" onClick={() => closeRef.current()}>
          {req.cancelTitle || L('取消')}
        </button>
        <button
          ref={button}
          class="btn-danger"
          onClick={() => {
            confirmed.current = true;
            closeRef.current();
          }}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              confirmed.current = true;
              closeRef.current();
            }
          }}
        >
          {req.confirmTitle}
        </button>
      </div>
    </FlipDialog>
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
