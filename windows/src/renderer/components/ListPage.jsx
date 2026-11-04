import { useEffect, useRef, useState } from 'preact/hooks';
import {
  section, listQuery, visibleMinutes, loading, selection, importing, importDialog, settingsOpen, general, folders,
  openMinute, requestMoveToTrash, restoreMinutes, deleteForever, revealMedia, reimportSRT, renameTarget, updateGeneral,
  runListSearch, listSearchFocus, createFolder, renameFolder, requestDeleteFolder, moveMinutes, importIntoFolder,
  renamingFolderID, folderInfoTarget, moveTarget, currentFolderID, sectionTitle, folderByID, libraryStats, byteText,
} from '../state.js';
import { importFolder } from '../importer.js';
import { duration, roughDuration, dateOnly, createdDate } from '../../core/time.js';
import { L } from '../../core/i18n.js';
import { Icon, Logo, Checkbox, Menu, MoreButton, Skeleton, Tag, useContextMenu } from './ui.jsx';

/** Minute rows are dragged onto sidebar folders as their ids, one per line. */
const DRAG_TYPE = 'application/x-bacon-minutes';

const SECTIONS = [
  { id: 'all', title: () => L('全部'), icon: 'home' },
  { id: 'recent', title: () => L('最近打开'), icon: 'clock' },
  { id: 'trash', title: () => L('回收站'), icon: 'trash' },
];

function folderItems(f) {
  return [
    { label: L('属性'), icon: 'info', onClick: () => (folderInfoTarget.value = f.id) },
    { label: L('重命名'), icon: 'pencil', onClick: () => (renamingFolderID.value = f.id) },
    { label: L('导入到此文件夹…'), icon: 'download', onClick: () => importIntoFolder(f.id) },
    'sep',
    { label: L('删除文件夹'), icon: 'trash', danger: true, onClick: () => requestDeleteFolder(f.id) },
  ];
}

function FolderRow({ folder, openContext }) {
  const [hovering, setHovering] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [dropping, setDropping] = useState(false);
  const input = useRef(null);
  const selected = section.value === `folder:${folder.id}`;
  const editing = renamingFolderID.value === folder.id;
  useEffect(() => {
    if (editing) {
      input.current?.focus();
      input.current?.select();
    }
  }, [editing]);
  const accepts = (e) => Array.from(e.dataTransfer?.types || []).includes(DRAG_TYPE);
  return (
    <div
      class={`folder-row ${selected ? 'selected' : ''} ${dropping ? 'drop' : ''}`}
      onMouseEnter={() => setHovering(true)}
      onMouseLeave={() => setHovering(false)}
      onClick={() => {
        section.value = `folder:${folder.id}`;
        selection.value = new Set();
      }}
      onContextMenu={(e) => openContext(e, folderItems(folder))}
      onDragOver={(e) => {
        if (!accepts(e)) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
        if (!dropping) setDropping(true);
      }}
      onDragLeave={() => setDropping(false)}
      onDrop={(e) => {
        if (!accepts(e)) return;
        e.preventDefault();
        e.stopPropagation();
        setDropping(false);
        const ids = e.dataTransfer.getData(DRAG_TYPE).split('\n').filter(Boolean);
        moveMinutes(ids, folder.id);
      }}
    >
      <Icon name={selected ? 'folderFill' : 'folder'} />
      {editing ? (
        <input
          ref={input}
          class="folder-input"
          defaultValue={folder.name}
          placeholder={L('文件夹名称')}
          onClick={(e) => e.stopPropagation()}
          onBlur={(e) => renameFolder(folder.id, e.currentTarget.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') e.currentTarget.blur();
            if (e.key === 'Escape') {
              e.stopPropagation();
              renamingFolderID.value = null;
            }
          }}
        />
      ) : (
        <span class="folder-name">{folder.name}</span>
      )}
      {/* Kept while its menu is open: the pointer leaves the row on its way to the menu. */}
      {(hovering || menuOpen) && !editing ? (
        <span onClick={(e) => e.stopPropagation()}>
          <MoreButton size={22} hover={false} title={L('文件夹操作')} items={folderItems(folder)} onOpenChange={setMenuOpen} />
        </span>
      ) : (
        <span class="folder-count num">{libraryStats(folder.id).count}</span>
      )}
    </div>
  );
}

function LibraryStats() {
  const s = libraryStats();
  const rows = [
    [L('妙记'), L('{0} 个', s.count)],
    [L('总时长'), s.count > 0 ? roughDuration(s.duration) : '—'],
    [L('总大小'), byteText(s.bytes)],
  ];
  return (
    <div class="lib-stats">
      {rows.map(([k, v]) => (
        <div class="ls-row" key={k}>
          <span class="k">{k}</span>
          <span class="v num">{v}</span>
        </div>
      ))}
    </div>
  );
}

function Sidebar({ openContext }) {
  return (
    <aside class="sidebar">
      <div class="sidebar-head drag">
        <Logo size={28} />
        {L('培根妙记')}
      </div>
      {SECTIONS.map((s) => (
        <button
          key={s.id}
          class={`nav-item ${section.value === s.id ? 'selected' : ''}`}
          onClick={() => {
            section.value = s.id;
            selection.value = new Set();
          }}
        >
          <Icon name={s.icon} />
          {s.title()}
        </button>
      ))}
      <div class="folders-head">
        <span>{L('文件夹')}</span>
        <button class="btn-icon sidebar-plus" onClick={createFolder} title={L('新建文件夹')}>
          <Icon name="plus" size={13} />
        </button>
      </div>
      <div class="folders-scroll">
        {folders.value.map((f) => (
          <FolderRow key={f.id} folder={f} openContext={openContext} />
        ))}
      </div>
      <LibraryStats />
      <div class="sidebar-sep" />
      <button class="nav-item" onClick={() => (settingsOpen.value = 'api')}>
        <Icon name="settings" />
        {L('设置')}
      </button>
    </aside>
  );
}

function ImportButton() {
  return (
    <Menu
      align="right"
      minWidth={200}
      items={[
        { label: L('导入音视频与字幕…'), icon: 'docPlus', onClick: () => (importDialog.value = { media: null, subtitle: null }) },
        { label: L('批量导入文件夹…'), icon: 'folder', onClick: importFolder },
      ]}
      trigger={({ toggle }) => (
        <button class="btn-primary" onClick={toggle}>
          <Icon name="plus" size={14} />
          {L('导入')}
          <Icon name="chevronDown" size={12} />
        </button>
      )}
    />
  );
}

function Thumb({ m }) {
  return (
    <div class="thumb">
      {m.coverURL ? <img src={m.coverURL} alt="" draggable={false} /> : <Icon name={m.isAudioOnly ? 'mic' : 'film'} />}
    </div>
  );
}

function rowMenuItems(m) {
  return [
    { label: L('重命名'), icon: 'pencil', onClick: () => (renameTarget.value = m.id) },
    { label: L('移动到文件夹…'), icon: 'folder', onClick: () => (moveTarget.value = [m.id]) },
    m.folderID && { label: L('移出文件夹'), icon: 'folderMinus', onClick: () => moveMinutes([m.id], null) },
    { label: L('在资源管理器中显示媒体'), icon: 'search', onClick: () => revealMedia(m) },
    { label: L('重新导入 SRT…'), icon: 'bubble', onClick: () => reimportSRT(m.id) },
    'sep',
    { label: L('移到回收站'), icon: 'trash', danger: true, onClick: () => requestMoveToTrash([m.id]) },
  ].filter(Boolean);
}

function Row({ m, trash, openContext }) {
  const selected = selection.value.has(m.id);
  const toggle = () => {
    const s = new Set(selection.value);
    if (selected) s.delete(m.id);
    else s.add(m.id);
    selection.value = s;
  };
  const sortOpened = general.value.listSort === 'opened' || section.value === 'recent';
  const folder = !currentFolderID.value && m.folderID ? folderByID(m.folderID) : null;
  return (
    <div
      class={`row ${selected ? 'selected' : ''}`}
      draggable={!trash}
      onDragStart={(e) => {
        // Dragging a selected row carries the whole selection.
        const ids = selected && selection.value.size > 1 ? [...selection.value] : [m.id];
        e.dataTransfer.setData(DRAG_TYPE, ids.join('\n'));
        e.dataTransfer.effectAllowed = 'move';
      }}
      onClick={() => (trash ? toggle() : openMinute(m.id))}
      onContextMenu={(e) =>
        openContext(e, trash ? [{ label: L('恢复'), onClick: () => restoreMinutes([m.id]) }, { label: L('彻底删除'), danger: true, onClick: () => deleteForever([m.id]) }] : rowMenuItems(m))
      }
    >
      <span class="checkbox-slot">
        <Checkbox checked={selected} onChange={toggle} />
      </span>
      <div class="col-file" style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
        <Thumb m={m} />
        <div style={{ minWidth: 0 }}>
          <div class="row-title">
            {m.hasSummary && !trash && (
              <span style={{ marginRight: 6 }}>
                <Tag text={L('纪要')} />
              </span>
            )}
            {m.title}
          </div>
          <div class="row-sub">
            <span>{duration(m.duration)}</span>
            {!m.srtFileName && <span>{L('· 无字幕')}</span>}
            {folder && (
              <span class="row-folder">
                <Icon name="folder" size={11} />
                {folder.name}
              </span>
            )}
          </div>
        </div>
      </div>
      {trash ? (
        <>
          <div class="col-deleted">{createdDate(m.deletedAt)}</div>
          <div class="col-trash-ops">
            <button class="btn-link" onClick={(e) => (e.stopPropagation(), restoreMinutes([m.id]))}>
              {L('恢复')}
            </button>
            <button class="btn-link" onClick={(e) => (e.stopPropagation(), deleteForever([m.id]))}>
              {L('彻底删除')}
            </button>
          </div>
        </>
      ) : (
        <>
          <div class="col-date">{dateOnly(sortOpened ? m.lastOpenedAt || m.createdAt : m.createdAt)}</div>
          <div class="col-ops" onClick={(e) => e.stopPropagation()}>
            {/* Opens on click (not hover) with the flip-down animation. */}
            <MoreButton hover={false} title={L('操作')} items={rowMenuItems(m)} />
          </div>
        </>
      )}
    </div>
  );
}

function SortMenu() {
  if (section.value === 'recent') return L('最近打开');
  const opened = general.value.listSort === 'opened';
  return (
    <Menu
      minWidth={140}
      items={[
        { label: L('最近创建'), selected: !opened, onClick: () => updateGeneral({ listSort: 'created' }) },
        { label: L('最近打开'), selected: opened, onClick: () => updateGeneral({ listSort: 'opened' }) },
      ]}
      trigger={({ toggle }) => (
        <button class="sort-trigger" onClick={toggle}>
          {opened ? L('最近打开') : L('创建时间')}
          <Icon name="chevronDown" size={11} />
        </button>
      )}
    />
  );
}

function Header({ items, trash }) {
  const ids = items.map((m) => m.id);
  const selectedHere = ids.filter((id) => selection.value.has(id));
  const all = ids.length > 0 && selectedHere.length === ids.length;
  const toggleAll = () => {
    const s = new Set(selection.value);
    if (all) ids.forEach((id) => s.delete(id));
    else ids.forEach((id) => s.add(id));
    selection.value = s;
  };
  return (
    <div class="list-header">
      <span style={{ width: 16, visibility: ids.length ? 'visible' : 'hidden' }}>
        <Checkbox checked={all} mixed={selectedHere.length > 0 && !all} onChange={toggleAll} />
      </span>
      {selectedHere.length ? (
        <div class="selection-bar">
          <span style={{ color: 'var(--text)' }}>{L('已选 {0} 项', selectedHere.length)}</span>·
          {trash ? (
            <>
              <button class="btn-link" onClick={() => restoreMinutes(selectedHere)}>
                {L('恢复')}
              </button>
              ·
              <button class="btn-link" onClick={() => deleteForever(selectedHere)}>
                {L('彻底删除')}
              </button>
            </>
          ) : (
            <>
              <button class="btn-link" onClick={() => (moveTarget.value = selectedHere)}>
                {L('移动到文件夹')}
              </button>
              ·
              <button class="btn-link" onClick={() => requestMoveToTrash(selectedHere)}>
                {L('移到回收站')}
              </button>
            </>
          )}
          ·
          <button class="btn-link" onClick={() => (selection.value = new Set())}>
            {L('取消')}
          </button>
        </div>
      ) : trash ? (
        <>
          <span class="col-file">{L('文件')}</span>
          <span class="col-deleted">{L('删除时间 ↓')}</span>
          <span class="col-trash-ops">{L('操作')}</span>
        </>
      ) : (
        <>
          <span class="col-file">{L('文件')}</span>
          <span class="col-date">
            <SortMenu />
          </span>
          <span class="col-ops">{L('操作')}</span>
        </>
      )}
    </div>
  );
}

function emptyText() {
  if (listQuery.value) return L('没有找到相关妙记');
  if (section.value === 'trash') return L('回收站为空');
  if (section.value === 'recent') return L('还没有打开过妙记');
  if (currentFolderID.value) return L('这个文件夹还是空的');
  return L('暂无妙记文件');
}

export function ListPage() {
  const search = useRef(null);
  const [openContext, contextNode] = useContextMenu();
  const items = visibleMinutes.value;
  const trash = section.value === 'trash';
  const inFolder = !!currentFolderID.value;

  useEffect(() => {
    if (listSearchFocus.value) search.current?.focus();
  }, [listSearchFocus.value]);

  useEffect(() => {
    const t = setTimeout(runListSearch, 200);
    return () => clearTimeout(t);
  }, [listQuery.value]);

  return (
    <div class="list-page">
      <Sidebar openContext={openContext} />
      <main class={`list-main ${selection.value.size ? 'selecting' : ''}`}>
        <div class="list-search-row drag">
          <div class="searchbox no-drag">
            <Icon name="search" style={{ color: 'var(--text-3)' }} />
            <input ref={search} placeholder={L('搜索妙记')} value={listQuery.value} onInput={(e) => (listQuery.value = e.currentTarget.value)} />
            {listQuery.value && (
              <button class="btn-icon" style={{ width: 20, height: 20 }} onClick={() => (listQuery.value = '')}>
                <Icon name="close" size={12} />
              </button>
            )}
          </div>
        </div>
        <div class="list-title-row">
          {inFolder && <Icon name="folderFill" size={20} style={{ color: 'var(--brand)' }} />}
          <h1>{sectionTitle.value}</h1>
          {importing.value && <span style={{ color: 'var(--text-3)', fontSize: 12 }}>{L('正在导入…')}</span>}
          <div style={{ flex: 1 }} />
          {!trash && <ImportButton />}
        </div>
        <Header items={items} trash={trash} />
        {loading.value ? (
          <div class="list-scroll">
            {[0, 1, 2, 3, 4].map((i) => (
              <div class="row" key={i} style={{ cursor: 'default' }}>
                <span style={{ width: 16 }} />
                <Skeleton w={120} h={68} r={6} />
                <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 10 }}>
                  <Skeleton w={260} h={14} />
                  <Skeleton w={120} h={10} />
                </div>
                <Skeleton w={110} h={12} />
                <Skeleton w={30} h={12} />
              </div>
            ))}
          </div>
        ) : items.length === 0 ? (
          <div class="empty-state">
            <div class="empty-art">
              <Icon name={trash ? 'trash' : inFolder ? 'folder' : 'inbox'} />
            </div>
            <div>{emptyText()}</div>
            {!trash && !listQuery.value && section.value !== 'recent' && (
              <>
                <button class="btn-primary" onClick={() => (importDialog.value = { media: null, subtitle: null })}>
                  {L('导入')}
                </button>
                <div style={{ fontSize: 12 }}>{inFolder ? L('也可以把文件拖到这里，或把左侧「全部」里的妙记拖到这个文件夹') : L('也可以把音视频与 SRT 文件直接拖到这里')}</div>
              </>
            )}
          </div>
        ) : (
          <div class="list-scroll">
            {items.map((m) => (
              <Row key={m.id} m={m} trash={trash} openContext={openContext} />
            ))}
          </div>
        )}
      </main>
      {contextNode}
    </div>
  );
}
