// App-wide state (Preact signals) and library actions.
import { signal, computed, batch } from '@preact/signals';
import { defaultLLMConfig, applyPreset } from '../core/llm.js';
import { DEFAULT_SUFFIXES } from '../core/pairing.js';
import { fold } from '../core/text.js';
import { compactDuration } from '../core/time.js';
import { L, setLanguageReader, bestLanguage, localeTag } from '../core/i18n.js';

export const lm = window.lm;
export const call = (channel, ...args) => lm.invoke(channel, ...args);

// ---------- language ----------

export const systemLanguage = signal(bestLanguage(navigator.languages));
export const uiLanguage = signal(systemLanguage.value);
// Every component that calls L() reads this signal, so it re-renders on a language change.
setLanguageReader(() => uiLanguage.value);

function applyLanguage() {
  const id = general.value.language || systemLanguage.value;
  uiLanguage.value = id;
  document.documentElement.lang = id;
  document.title = L('培根妙记');
}

/** `id` null follows the system. */
export async function setUILanguage(id) {
  await updateGeneral({ language: id });
  applyLanguage();
}

// ---------- navigation and list state ----------

export const route = signal({ name: 'list' }); // { name: 'detail', id }
export const section = signal('all'); // all | recent | trash | folder:<id>
export const listQuery = signal('');
export const transcriptMatches = signal(null); // Set of ids matching the query in transcript text
export const minutes = signal([]);
export const folders = signal([]);
export const loading = signal(true);
export const selection = signal(new Set());
export const toast = signal(null);
export const importDialog = signal(null); // { media, subtitle } while open
export const importing = signal(false);
export const settingsOpen = signal(null); // null | 'api' | 'general'
export const renameTarget = signal(null);
export const detail = signal(null); // DetailModel
export const listSearchFocus = signal(0);
/** In-app confirmation: { title, message, emphasis?, confirmTitle, onConfirm }. */
export const confirmRequest = signal(null);
/** Ids being moved with the "移动到文件夹" dialog. */
export const moveTarget = signal(null);
/** Folder whose properties dialog is open. */
export const folderInfoTarget = signal(null);
/** Folder whose name is being edited inline in the sidebar. */
export const renamingFolderID = signal(null);
/** User-uploaded app icon as a data URL; null shows the default artwork. */
export const customIcon = signal(null);

export const general = signal({
  skipBlankEnabled: false,
  skipBlankThreshold: 2,
  perCharHighlight: true,
  insertComma: true,
  filenameSuffixes: DEFAULT_SUFFIXES,
  ccEnabled: false,
  playbackRate: 1,
  volume: 1,
  detailSplit: 0.57,
  listSort: 'created',
  language: null,
});
export const llm = signal(defaultLLMConfig());
export const apiKey = signal('');

export const llmReady = computed(() => {
  const c = llm.value;
  return !!c.baseURL.trim() && !!c.model.trim() && !c.baseURL.includes('{');
});

export const isDialogOpen = computed(() => !!(confirmRequest.value || moveTarget.value || folderInfoTarget.value));

let toastTimer = null;
export function showToast(text) {
  toast.value = text;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (toast.value = null), 3000);
}

export async function alertError(title, message) {
  await call('dialog:alert', { title, message, error: true });
}

export async function loadSettings() {
  const s = await call('settings:get');
  batch(() => {
    general.value = { ...general.value, ...s.general };
    llm.value = s.llm;
    apiKey.value = s.apiKey;
    if (s.systemLanguage) systemLanguage.value = s.systemLanguage;
  });
  applyLanguage();
  customIcon.value = await call('icon:get');
}

export async function updateGeneral(patch) {
  general.value = { ...general.value, ...patch };
  await call('settings:setGeneral', patch);
}

export async function updateLLM(config) {
  llm.value = config;
  const r = await call('settings:setLLM', config);
  if (r.apiKey !== undefined) apiKey.value = r.apiKey;
}

export async function choosePreset(id) {
  await updateLLM(applyPreset(llm.value, id));
}

let keyTimer = null;
export function updateApiKey(value) {
  apiKey.value = value;
  clearTimeout(keyTimer);
  keyTimer = setTimeout(() => call('settings:setApiKey', value), 300);
}

// ---------- library ----------

export async function loadLibrary() {
  loading.value = true;
  try {
    const [list, fs] = await Promise.all([call('lib:list'), call('lib:folders')]);
    batch(() => {
      minutes.value = list;
      folders.value = fs;
    });
  } finally {
    loading.value = false;
  }
}

export function upsertMinute(m) {
  const list = minutes.value.slice();
  const i = list.findIndex((x) => x.id === m.id);
  if (i >= 0) list[i] = m;
  else list.push(m);
  minutes.value = list;
}

export const currentFolderID = computed(() => (section.value.startsWith('folder:') ? section.value.slice(7) : null));
export const folderByID = (id) => folders.value.find((f) => f.id === id) || null;

export const sectionTitle = computed(() => {
  switch (section.value) {
    case 'all':
      return L('全部');
    case 'recent':
      return L('最近打开');
    case 'trash':
      return L('回收站');
    default:
      return folderByID(currentFolderID.value)?.name || L('文件夹');
  }
});

/** Count, total duration and total media size of minutes not in the trash. */
export function libraryStats(folderID = null) {
  const s = { count: 0, duration: 0, bytes: 0 };
  for (const m of minutes.value) {
    if (m.deletedAt || (folderID && m.folderID !== folderID)) continue;
    s.count += 1;
    s.duration += m.duration || 0;
    s.bytes += m.mediaSize || 0;
  }
  return s;
}

/** `1.2 GB` style sizes in decimal units, like the Mac app. */
export function byteText(bytes) {
  if (!(bytes > 0)) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = bytes;
  let i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  const n = new Intl.NumberFormat(localeTag(uiLanguage.value), { maximumFractionDigits: i <= 1 ? 0 : 1 }).format(v);
  return `${n} ${units[i]}`;
}

export const visibleMinutes = computed(() => {
  const sec = section.value;
  const folder = currentFolderID.value;
  let items = minutes.value.filter((m) => {
    if (sec === 'trash') return !!m.deletedAt;
    if (m.deletedAt) return false;
    if (sec === 'recent') return !!m.lastOpenedAt;
    if (folder) return m.folderID === folder;
    return true;
  });
  const q = listQuery.value.trim();
  if (q) {
    const needle = fold(q);
    const matches = transcriptMatches.value;
    items = items.filter((m) => fold(m.title).includes(needle) || matches?.has(m.id));
  }
  const t = (d) => (d ? Date.parse(d) : 0);
  if (sec === 'trash') items.sort((a, b) => t(b.deletedAt) - t(a.deletedAt));
  else if (sec === 'recent' || general.value.listSort === 'opened') items.sort((a, b) => t(b.lastOpenedAt) - t(a.lastOpenedAt) || t(b.createdAt) - t(a.createdAt));
  else items.sort((a, b) => t(b.createdAt) - t(a.createdAt));
  return items;
});

let searchSeq = 0;
export async function runListSearch() {
  const q = listQuery.value.trim();
  const seq = ++searchSeq;
  if (!q) {
    transcriptMatches.value = null;
    return;
  }
  const ids = await call('lib:search', q);
  if (seq === searchSeq) transcriptMatches.value = new Set(ids);
}

function deselect(ids) {
  const sel = new Set(selection.value);
  ids.forEach((id) => sel.delete(id));
  selection.value = sel;
}

// ---------- folders ----------

export async function createFolder() {
  const names = new Set(folders.value.map((f) => f.name));
  let name = L('新建文件夹');
  for (let n = 2; names.has(name); n++) name = L('新建文件夹 {0}', n);
  const f = await call('lib:createFolder', name);
  batch(() => {
    folders.value = [...folders.value, f];
    section.value = `folder:${f.id}`;
    selection.value = new Set();
    renamingFolderID.value = f.id;
  });
}

export async function renameFolder(id, name) {
  const t = (name || '').trim();
  if (renamingFolderID.value === id) renamingFolderID.value = null;
  if (!t || folderByID(id)?.name === t) return;
  folders.value = await call('lib:renameFolder', id, t);
}

export function requestDeleteFolder(id) {
  const f = folderByID(id);
  if (!f) return;
  const count = libraryStats(id).count;
  confirmRequest.value = {
    title: L('删除文件夹「{0}」？', f.name),
    message: count > 0 ? L('文件夹里的 {0} 个妙记不会被删除，仍会保留在「全部」中。', count) : L('这个文件夹是空的。'),
    confirmTitle: L('删除文件夹'),
    onConfirm: async () => {
      if (section.value === `folder:${id}`) section.value = 'all';
      const changed = await call('lib:deleteFolder', id);
      batch(() => {
        changed.forEach(upsertMinute);
        folders.value = folders.value.filter((x) => x.id !== id);
      });
      showToast(L('已删除文件夹'));
    },
  };
}

export async function moveMinutes(ids, folderID) {
  const valid = ids.filter((id) => minutes.value.some((m) => m.id === id));
  if (!valid.length) return;
  const updated = await call('lib:move', valid, folderID);
  batch(() => {
    updated.forEach(upsertMinute);
    deselect(valid);
  });
  const f = folderID && folderByID(folderID);
  if (f) showToast(valid.length === 1 ? L('已移动到「{0}」', f.name) : L('已将 {0} 项移动到「{1}」', valid.length, f.name));
  else showToast(L('已移出文件夹'));
}

export function importIntoFolder(id) {
  section.value = `folder:${id}`;
  importDialog.value = { media: null, subtitle: null };
}

// ---------- minutes ----------

/** Asks first, with an in-app dialog. */
export function requestMoveToTrash(ids) {
  if (!ids.length) return;
  const one = ids.length === 1 && minutes.value.find((m) => m.id === ids[0]);
  confirmRequest.value = {
    title: one ? L('将「{0}」移到回收站？', one.title) : L('将 {0} 个妙记移到回收站？', ids.length),
    message: L('移到回收站后可以随时恢复。'),
    emphasis: L('原始媒体文件不会被删除。'),
    confirmTitle: L('移到回收站'),
    onConfirm: () => moveToTrash(ids),
  };
}

export async function moveToTrash(ids) {
  if (!ids.length) return;
  if (detail.value && ids.includes(detail.value.minute.value.id)) await goBack();
  const updated = await call('lib:trash', ids);
  updated.forEach(upsertMinute);
  deselect(ids);
  showToast(ids.length === 1 ? L('已移到回收站') : L('已将 {0} 项移到回收站', ids.length));
}

export async function restoreMinutes(ids) {
  if (!ids.length) return;
  const updated = await call('lib:restore', ids);
  updated.forEach(upsertMinute);
  deselect(ids);
  showToast(L('已恢复'));
}

export function deleteForever(ids) {
  if (!ids.length) return;
  confirmRequest.value = {
    title: ids.length === 1 ? L('彻底删除这个妙记？') : L('彻底删除 {0} 个妙记？', ids.length),
    message: L('删除后妙记的文字记录和纪要无法恢复。'),
    emphasis: L('原始媒体文件不会被删除。'),
    confirmTitle: L('彻底删除'),
    onConfirm: async () => {
      await call('lib:remove', ids);
      batch(() => {
        minutes.value = minutes.value.filter((m) => !ids.includes(m.id));
        deselect(ids);
      });
    },
  };
}

export async function renameMinute(id, title) {
  const m = minutes.value.find((x) => x.id === id);
  if (!m || !title || title === m.title) return;
  const saved = await call('lib:save', { ...m, title });
  upsertMinute(saved);
  if (detail.value?.minute.value.id === id) detail.value.minute.value = saved;
}

export async function revealMedia(m) {
  try {
    await call('fs:reveal', m.mediaPath);
  } catch {
    alertError(L('找不到媒体文件'), L('文件可能已被移动或删除。打开妙记后可以「重新定位」。'));
  }
}

export async function reimportSRT(id) {
  const path = await call('dialog:openSrt');
  if (!path) return;
  try {
    const { minute, transcript } = await call('lib:attachSrt', id, path);
    upsertMinute(minute);
    showToast(importSummaryText(transcript, minute.duration));
  } catch (e) {
    alertError(L('无法导入字幕'), e.message);
  }
}

export function importSummaryText(transcript, duration) {
  const d = duration > 0 ? duration : Math.max(0, ...transcript.cues.map((c) => c.end));
  return L('已导入 {0} 条字幕，{1} 位发言人，时长 {2}', transcript.cues.length, transcript.speakers.length, compactDuration(d));
}

// ---------- navigation ----------

let DetailModelClass = null;
export function registerDetailModel(cls) {
  DetailModelClass = cls;
}

export async function openMinute(id) {
  const m = minutes.value.find((x) => x.id === id);
  if (!m || m.deletedAt) return;
  if (detail.value) await detail.value.close();
  const saved = await call('lib:save', { ...m, lastOpenedAt: new Date().toISOString() });
  upsertMinute(saved);
  const d = new DetailModelClass(saved);
  // Transcript and summary are loaded before the page appears, so it opens with content in
  // place; media and the transcript text start once the page transition has finished.
  await d.prepare();
  batch(() => {
    detail.value = d;
    route.value = { name: 'detail', id };
    selection.value = new Set();
  });
  setTimeout(() => d.start(), 240);
}

export async function goBack() {
  const d = detail.value;
  if (!d) return;
  if (document.fullscreenElement) await document.exitFullscreen().catch(() => {});
  await d.close();
  upsertMinute(d.minute.value);
  batch(() => {
    detail.value = null;
    route.value = { name: 'list' };
  });
}
