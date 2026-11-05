import { useEffect, useState } from 'preact/hooks';
import {
  route, detail, toast, importDialog, settingsOpen, renameTarget, minutes, selection, section,
  loadLibrary, loadSettings, goBack, requestMoveToTrash, renameMinute, listSearchFocus, call, lm,
  isDialogOpen, confirmRequest, moveTarget, folderInfoTarget, currentFolderID, folderByID,
  folderSelection, requestDeleteFolders,
} from '../state.js';
import { L } from '../../core/i18n.js';
import { ConfirmDialog, MoveToFolderDialog, FolderInfoDialog } from './Dialogs.jsx';
import { importPaths, importFolder, pathsFromDrop } from '../importer.js';
import { ListPage } from './ListPage.jsx';
import { DetailPage } from './DetailPage.jsx';
import { ImportDialog } from './ImportDialog.jsx';
import { SettingsModal } from './Settings.jsx';
import { Icon, PromptDialog } from './ui.jsx';
import * as state from '../state.js';

function isEditable(el) {
  if (!el) return false;
  const tag = el.tagName;
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable;
}

/** §11 shortcuts, Windows flavour (Ctrl instead of ⌘). */
function onKeyDown(e) {
  if (importDialog.value || settingsOpen.value || renameTarget.value || isDialogOpen.value) return;
  if (document.querySelector('.modal-backdrop')) return;
  const editing = isEditable(document.activeElement);
  const ctrl = e.ctrlKey || e.metaKey;
  const d = detail.value;

  if (ctrl && !e.shiftKey && e.key.toLowerCase() === 'o') {
    e.preventDefault();
    importDialog.value = { media: null, subtitle: null };
    return;
  }
  if (ctrl && e.shiftKey && e.key.toLowerCase() === 'o') {
    e.preventDefault();
    importFolder();
    return;
  }
  if (ctrl && e.key === ',') {
    e.preventDefault();
    settingsOpen.value = 'api';
    return;
  }
  if (ctrl && e.key.toLowerCase() === 'f') {
    e.preventDefault();
    if (d) d.focusSearch();
    else listSearchFocus.value++;
    return;
  }
  if (d) {
    if ((ctrl && e.key === '[') || (e.altKey && e.key === 'ArrowLeft')) {
      e.preventDefault();
      goBack();
      return;
    }
    if (ctrl && (e.key === '1' || e.key === '2')) {
      e.preventDefault();
      d.rightTab.value = e.key === '1' ? 'summary' : 'transcript';
      return;
    }
    if (e.key === 'Escape') {
      if (document.fullscreenElement) return; // the browser exits full screen itself
      if (d.searchQuery.value) {
        e.preventDefault();
        d.clearSearch();
        document.activeElement?.blur?.();
      }
      return;
    }
    if (e.key === 'Enter' && !ctrl && !e.altKey) {
      if (d.searchQuery.value && (!editing || d.searchFieldFocused)) {
        e.preventDefault();
        d.moveHit(e.shiftKey ? -1 : 1);
      }
      return;
    }
    if (editing || ctrl || e.altKey) return;
    if (e.key === ' ') {
      e.preventDefault();
      d.togglePlay();
    } else if (e.key === 'ArrowLeft') {
      e.preventDefault();
      d.skip(-15);
    } else if (e.key === 'ArrowRight') {
      e.preventDefault();
      d.skip(15);
    }
    return;
  }
  // Folders selected in the sidebar: Delete removes them (after confirming), Esc clears.
  if (!editing && folderSelection.value.size) {
    if (e.key === 'Escape') {
      folderSelection.value = new Set();
      return;
    }
    if (e.key === 'Delete' || e.key === 'Backspace') {
      e.preventDefault();
      requestDeleteFolders(folderSelection.value);
      return;
    }
  }
  if (!editing && (e.key === 'Delete' || (ctrl && e.key === 'Backspace')) && selection.value.size && section.value !== 'trash') {
    e.preventDefault();
    requestMoveToTrash([...selection.value]);
  }
}

function useTitleBarColor() {
  const isDetail = route.value.name === 'detail';
  useEffect(() => {
    const css = getComputedStyle(document.documentElement);
    const color = (isDetail ? css.getPropertyValue('--win-top') : css.getPropertyValue('--card')).trim() || '#ffffff';
    const symbolColor = css.getPropertyValue('--text').trim() || '#1f2329';
    call('win:titleBar', { color, symbolColor }).catch(() => {});
  }, [isDetail]);
}

function dropText(isDetail) {
  if (isDetail) return L('松开以导入（SRT 将导入到当前妙记）');
  const f = folderByID(currentFolderID.value);
  return f ? L('松开以导入到「{0}」', f.name) : L('松开以导入');
}

export function App() {
  const [dropping, setDropping] = useState(false);

  useEffect(() => {
    loadSettings().then(loadLibrary);
    window.addEventListener('keydown', onKeyDown);
    // Never let a stray drop navigate the window.
    const block = (e) => e.preventDefault();
    window.addEventListener('dragover', block);
    window.addEventListener('drop', block);
    if (lm.e2e) window.__lm = { state, importPaths };
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);
  useTitleBarColor();

  const onDragOver = (e) => {
    if (!Array.from(e.dataTransfer?.types || []).includes('Files')) return;
    e.preventDefault();
    if (!dropping) setDropping(true);
  };
  const onDragLeave = (e) => {
    if (e.relatedTarget == null) setDropping(false);
  };
  const onDrop = (e) => {
    e.preventDefault();
    setDropping(false);
    if (importDialog.value) return;
    const paths = pathsFromDrop(e);
    if (paths.length) importPaths(paths);
  };

  const isDetail = route.value.name === 'detail' && detail.value;
  const target = renameTarget.value && minutes.value.find((m) => m.id === renameTarget.value);

  return (
    <div style={{ height: '100%' }} onDragOver={onDragOver} onDragLeave={onDragLeave} onDrop={onDrop}>
      {isDetail ? <DetailPage model={detail.value} key={detail.value.minute.value.id} /> : <ListPage />}
      {dropping && !importDialog.value && <div class="drop-overlay">{dropText(isDetail)}</div>}
      {toast.value && (
        <div class="toast">
          <Icon name="check" size={16} style={{ color: 'var(--brand)' }} />
          {toast.value}
        </div>
      )}
      {importDialog.value && <ImportDialog />}
      {settingsOpen.value && <SettingsModal />}
      {confirmRequest.value && <ConfirmDialog key={confirmRequest.value.title} />}
      {moveTarget.value && <MoveToFolderDialog />}
      {folderInfoTarget.value && <FolderInfoDialog key={folderInfoTarget.value} />}
      {target && (
        <PromptDialog
          title={L('重命名')}
          initial={target.title}
          onCancel={() => (renameTarget.value = null)}
          onDone={(title) => {
            renameTarget.value = null;
            renameMinute(target.id, title);
          }}
        />
      )}
    </div>
  );
}
