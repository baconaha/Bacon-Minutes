import { useState } from 'preact/hooks';
import { importDialog, call, currentFolderID, folderByID } from '../state.js';
import { L } from '../../core/i18n.js';
import { importPaths, runImport, pathsFromDrop } from '../importer.js';
import { isMedia, isSubtitle, baseName } from '../../core/pairing.js';
import { Icon, Modal } from './ui.jsx';

function Slot({ title, path, placeholder, onChange }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 12, height: 40, padding: '0 12px', borderRadius: 6, background: 'var(--search-fill)' }}>
      <span style={{ width: 80, color: 'var(--text-3)' }}>{title}</span>
      {path ? (
        <>
          <Icon name={isSubtitle(path) ? 'bubble' : 'film'} style={{ color: 'var(--brand)' }} />
          <span style={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }} title={path}>
            {baseName(path)}
          </span>
        </>
      ) : (
        <span style={{ flex: 1, color: 'var(--text-3)' }}>{placeholder}</span>
      )}
      <button class="btn-link" onClick={onChange}>
        {path ? L('更换') : L('选择')}
      </button>
    </div>
  );
}

/** "导入音视频文件" dialog (§9.1). */
export function ImportDialog() {
  const draft = importDialog.value;
  const [over, setOver] = useState(false);
  const close = () => (importDialog.value = null);
  const folder = folderByID(currentFolderID.value);
  const set = (patch) => (importDialog.value = { ...importDialog.value, ...patch });

  const accept = async (paths) => {
    const { media, subtitles } = await call('fs:expand', paths);
    if (media.length > 1 || subtitles.length > 1) {
      // Several files: hand over to the batch importer with automatic pairing.
      close();
      await importPaths(paths);
      return;
    }
    const patch = {};
    if (media[0]) patch.media = media[0];
    if (subtitles[0]) patch.subtitle = subtitles[0];
    set(patch);
  };

  const choose = async () => {
    const paths = await call('dialog:openFiles');
    if (paths.length) accept(paths);
  };

  const submit = () => {
    if (!draft.media) return;
    const pair = { media: draft.media, subtitle: draft.subtitle || null };
    close();
    runImport([pair]);
  };

  return (
    <Modal onClose={close} width={540}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div>
          <h2>{L('导入音视频文件')}</h2>
          {folder && <div style={{ fontSize: 12, color: 'var(--text-2)', marginTop: 4 }}>{L('将导入到「{0}」', folder.name)}</div>}
        </div>
        <button class="btn-icon" onClick={close}>
          <Icon name="close" />
        </button>
      </div>
      <div
        onDragOver={(e) => {
          e.preventDefault();
          e.stopPropagation();
          setOver(true);
        }}
        onDragLeave={() => setOver(false)}
        onDrop={(e) => {
          e.preventDefault();
          e.stopPropagation();
          setOver(false);
          const paths = pathsFromDrop(e);
          if (paths.length) accept(paths);
        }}
        style={{
          margin: '18px 0',
          height: 190,
          borderRadius: 8,
          border: `1px dashed ${over ? 'var(--brand)' : 'var(--divider)'}`,
          background: over ? 'color-mix(in srgb, var(--cur-cue) 50%, transparent)' : 'color-mix(in srgb, var(--search-fill) 40%, transparent)',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          gap: 12,
        }}
      >
        <Icon name="docPlus" size={36} style={{ color: 'var(--brand)' }} />
        <div style={{ fontSize: 14, color: 'var(--text-2)' }}>
          {L('将文件拖拽至此区域或 ')}
          <button class="btn-link" style={{ fontSize: 14 }} onClick={choose}>
            {L('选择文件')}
          </button>
        </div>
        <div style={{ fontSize: 12, color: 'var(--text-3)' }}>{L('媒体：mp4 / mov / m4v / mp3 / m4a / wav / aac　字幕：srt')}</div>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        <Slot
          title={L('媒体文件')}
          path={draft.media}
          placeholder={L('未选择（必选）')}
          onChange={async () => {
            const p = await call('dialog:openMedia');
            if (p && isMedia(p)) set({ media: p });
          }}
        />
        <Slot
          title={L('字幕文件')}
          path={draft.subtitle}
          placeholder={L('未选择（可选，之后也能补导）')}
          onChange={async () => {
            const p = await call('dialog:openSrt');
            if (p) set({ subtitle: p });
          }}
        />
      </div>
      <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 12, marginTop: 20 }}>
        <button class="btn-secondary" onClick={close}>
          {L('取消')}
        </button>
        <button class="btn-primary" disabled={!draft.media} onClick={submit}>
          {L('导入')}
        </button>
      </div>
    </Modal>
  );
}
