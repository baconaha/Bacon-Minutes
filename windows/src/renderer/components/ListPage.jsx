import { useEffect, useRef, useState } from 'preact/hooks';
import {
  section, listQuery, visibleMinutes, loading, selection, importing, importDialog, settingsOpen, general,
  openMinute, moveToTrash, restoreMinutes, deleteForever, revealMedia, reimportSRT, renameTarget, updateGeneral,
  runListSearch, listSearchFocus,
} from '../state.js';
import { importFolder } from '../importer.js';
import { durationCN, dateOnly, createdDate } from '../../core/time.js';
import { Icon, Logo, Checkbox, Menu, Skeleton, Tag, useContextMenu } from './ui.jsx';

const SECTIONS = [
  { id: 'all', title: '全部', icon: 'home' },
  { id: 'recent', title: '最近打开', icon: 'clock' },
  { id: 'trash', title: '回收站', icon: 'trash' },
];

function Sidebar() {
  return (
    <aside class="sidebar">
      <div class="sidebar-head drag">
        <Logo size={28} />
        本地妙记
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
          {s.title}
        </button>
      ))}
      <div style={{ flex: 1 }} />
      <button class="nav-item" onClick={() => (settingsOpen.value = 'api')}>
        <Icon name="settings" />
        设置
      </button>
    </aside>
  );
}

function ImportButton() {
  return (
    <Menu
      align="right"
      items={[
        { label: '导入音视频与字幕…', onClick: () => (importDialog.value = { media: null, subtitle: null }) },
        { label: '批量导入文件夹…', onClick: importFolder },
      ]}
      trigger={({ toggle }) => (
        <button class="btn-primary" onClick={toggle}>
          <Icon name="plus" size={14} />
          导入
          <Icon name="chevronDown" size={12} />
        </button>
      )}
    />
  );
}

function remainingDays(deletedAt) {
  const expiry = Date.parse(deletedAt) + 30 * 86400000;
  return Math.max(1, Math.ceil((expiry - Date.now()) / 86400000));
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
    { label: '重命名', onClick: () => (renameTarget.value = m.id) },
    { label: '在资源管理器中显示媒体', onClick: () => revealMedia(m) },
    { label: '重新导入 SRT…', onClick: () => reimportSRT(m.id) },
    'sep',
    { label: '移到回收站', danger: true, onClick: () => moveToTrash([m.id]) },
  ];
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
  return (
    <div
      class={`row ${selected ? 'selected' : ''}`}
      onClick={() => (trash ? toggle() : openMinute(m.id))}
      onContextMenu={(e) =>
        openContext(e, trash ? [{ label: '恢复', onClick: () => restoreMinutes([m.id]) }, { label: '彻底删除', danger: true, onClick: () => deleteForever([m.id]) }] : rowMenuItems(m))
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
                <Tag text="纪要" />
              </span>
            )}
            {m.title}
          </div>
          <div class="row-sub">
            {durationCN(m.duration)}
            {!m.srtFileName && ' · 无字幕'}
          </div>
        </div>
      </div>
      {trash ? (
        <>
          <div class="col-deleted">{createdDate(m.deletedAt)}</div>
          <div class="col-left">{remainingDays(m.deletedAt)} 天</div>
          <div class="col-trash-ops">
            <button class="btn-link" onClick={(e) => (e.stopPropagation(), restoreMinutes([m.id]))}>
              恢复
            </button>
            <button class="btn-link" onClick={(e) => (e.stopPropagation(), deleteForever([m.id]))}>
              彻底删除
            </button>
          </div>
        </>
      ) : (
        <>
          <div class="col-date">{dateOnly(sortOpened ? m.lastOpenedAt || m.createdAt : m.createdAt)}</div>
          <div class="col-ops" onClick={(e) => e.stopPropagation()}>
            <Menu
              align="right"
              items={rowMenuItems(m)}
              trigger={({ toggle: t }) => (
                <button class="btn-icon" onClick={t} title="操作">
                  <Icon name="more" />
                </button>
              )}
            />
          </div>
        </>
      )}
    </div>
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
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
          <span style={{ color: 'var(--text)' }}>已选 {selectedHere.length} 项</span>·
          {trash ? (
            <>
              <button class="btn-link" onClick={() => restoreMinutes(selectedHere)}>
                恢复
              </button>
              ·
              <button class="btn-link" onClick={() => deleteForever(selectedHere)}>
                彻底删除
              </button>
            </>
          ) : (
            <button class="btn-link" onClick={() => moveToTrash(selectedHere)}>
              移到回收站
            </button>
          )}
          ·
          <button class="btn-link" onClick={() => (selection.value = new Set())}>
            取消
          </button>
        </div>
      ) : trash ? (
        <>
          <span class="col-file">文件</span>
          <span class="col-deleted">删除时间</span>
          <span class="col-left">剩余时间 ↓</span>
          <span class="col-trash-ops">操作</span>
        </>
      ) : (
        <>
          <span class="col-file">文件</span>
          <span class="col-date">
            {section.value === 'all' ? (
              <Menu
                items={[
                  { label: '最近创建', selected: general.value.listSort !== 'opened', onClick: () => updateGeneral({ listSort: 'created' }) },
                  { label: '最近打开', selected: general.value.listSort === 'opened', onClick: () => updateGeneral({ listSort: 'opened' }) },
                ]}
                trigger={({ toggle }) => (
                  <button onClick={toggle} style={{ display: 'inline-flex', alignItems: 'center', gap: 4, color: 'inherit' }}>
                    {general.value.listSort === 'opened' ? '最近打开' : '创建时间'}
                    <Icon name="chevronDown" size={11} />
                  </button>
                )}
              />
            ) : (
              '最近打开'
            )}
          </span>
          <span class="col-ops">操作</span>
        </>
      )}
    </div>
  );
}

export function ListPage() {
  const search = useRef(null);
  const [openContext, contextNode] = useContextMenu();
  const items = visibleMinutes.value;
  const trash = section.value === 'trash';
  const title = SECTIONS.find((s) => s.id === section.value).title;

  useEffect(() => {
    if (listSearchFocus.value) search.current?.focus();
  }, [listSearchFocus.value]);

  useEffect(() => {
    const t = setTimeout(runListSearch, 200);
    return () => clearTimeout(t);
  }, [listQuery.value]);

  return (
    <div class="list-page">
      <Sidebar />
      <main class={`list-main ${selection.value.size ? 'selecting' : ''}`}>
        <div class="list-search-row drag">
          <div class="searchbox no-drag">
            <Icon name="search" style={{ color: 'var(--text-3)' }} />
            <input ref={search} placeholder="搜索妙记" value={listQuery.value} onInput={(e) => (listQuery.value = e.currentTarget.value)} />
            {listQuery.value && (
              <button class="btn-icon" style={{ width: 20, height: 20 }} onClick={() => (listQuery.value = '')}>
                <Icon name="close" size={12} />
              </button>
            )}
          </div>
        </div>
        <div class="list-title-row">
          <h1>{title}</h1>
          {importing.value && <span style={{ color: 'var(--text-3)', fontSize: 12 }}>正在导入…</span>}
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
              <Icon name={trash ? 'trash' : 'inbox'} />
            </div>
            <div>{listQuery.value ? '没有找到相关妙记' : trash ? '回收站为空' : section.value === 'recent' ? '还没有打开过妙记' : '暂无妙记文件'}</div>
            {!trash && !listQuery.value && (
              <>
                <button class="btn-primary" onClick={() => (importDialog.value = { media: null, subtitle: null })}>
                  导入
                </button>
                <div style={{ fontSize: 12 }}>也可以把音视频与 SRT 文件直接拖到这里</div>
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
