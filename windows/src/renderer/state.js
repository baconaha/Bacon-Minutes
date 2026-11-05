// App-wide state (Preact signals) and library actions.
import { signal, computed, batch, effect } from '@preact/signals';
import { defaultLLMConfig, applyPreset, makeFavorite, favoriteID, applyFavorite } from '../core/llm.js';
import { DEFAULT_SUFFIXES } from '../core/pairing.js';
import { fold } from '../core/text.js';
import { compactDuration } from '../core/time.js';
import { L, setLanguageReader, bestLanguage, localeTag } from '../core/i18n.js';

export const lm = window.lm;
export const call = (channel, ...args) => lm.invoke(channel, ...args);

export const uuid = () =>
  typeof crypto.randomUUID === 'function'
    ? crypto.randomUUID()
    : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
        const r = (Math.random() * 16) | 0;
        return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
      });

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
/**
 * In-app confirmation: { title, message, emphasis?, confirmTitle, onConfirm, destructive = true,
 * checkbox?, onConfirmChecked? }. With the checkbox ticked, onConfirmChecked runs instead.
 */
export const confirmRequest = signal(null);
/** Batch import waiting for review (see importer.js). */
export const importReview = signal(null);
/** { index, total, fraction|null } while files are imported. */
export const importProgress = signal(null);
/** Minute id → copy progress (0…1) for "导入到应用". */
export const copyingMedia = signal(new Map());
/** Minute id → { phase: 'running' | 'failed', text, model, jobId }. Runs on after the page closes. */
export const summaryJobs = signal(new Map());
/** Starred models. */
export const favorites = signal([]);
/** Ids being moved with the "移动到文件夹" dialog. */
export const moveTarget = signal(null);
/** Folder whose properties dialog is open. */
export const folderInfoTarget = signal(null);
/** Folder whose name is being edited inline in the sidebar. */
export const renamingFolderID = signal(null);
/** Folders picked with a drag across the sidebar (or Ctrl-click), for batch actions. */
export const folderSelection = signal(new Set());
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

// Checking recordings ends a folder selection, so Delete acts on what was picked last.
effect(() => {
  if (selection.value.size && folderSelection.peek().size) folderSelection.value = new Set();
});

export const isDialogOpen = computed(() => !!(confirmRequest.value || moveTarget.value || folderInfoTarget.value || importReview.value));

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
    favorites.value = s.favorites || [];
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

// ---------- starred models ----------

export const isFavorite = (id) => favorites.value.some((f) => favoriteID(f) === id);

async function saveFavorites(list) {
  favorites.value = list;
  await call('settings:setFavorites', list);
}

/** Stars or unstars `model` on the endpoint currently set up. */
export function toggleFavorite(model) {
  const name = (model || '').trim();
  if (!name) return;
  const fav = makeFavorite(llm.value, name);
  const id = favoriteID(fav);
  saveFavorites(isFavorite(id) ? favorites.value.filter((f) => favoriteID(f) !== id) : [...favorites.value, fav]);
}

export function removeFavorite(id) {
  saveFavorites(favorites.value.filter((f) => favoriteID(f) !== id));
}

/** Makes a favorite the default model (switching provider and key if needed). */
export async function useFavoriteAsDefault(fav) {
  await updateLLM(applyFavorite(llm.value, fav));
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
  // Sizes of old minutes are measured in the file-check process, never blocking anything.
  call('lib:backfillSizes')
    .then((updated) => updated.forEach(upsertMinute))
    .catch(() => {});
}

lm.onCopyProgress?.(({ key, fraction }) => {
  if (typeof key === 'string' && copyingMedia.peek().has(key)) setCopying(key, fraction);
  else if (key === 'import' && importProgress.peek()) importProgress.value = { ...importProgress.peek(), fraction };
});

export function setCopying(id, fraction) {
  const map = new Map(copyingMedia.peek());
  if (fraction == null) map.delete(id);
  else map.set(id, fraction);
  copyingMedia.value = map;
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
  else if (general.value.listSort === 'name') {
    // Explorer order: "第2讲" before "第10讲", case ignored.
    const collator = new Intl.Collator(localeTag(uiLanguage.value), { numeric: true, sensitivity: 'base' });
    items.sort((a, b) => collator.compare(a.title, b.title));
  } else items.sort((a, b) => t(b.createdAt) - t(a.createdAt));
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
    folderSelection.value = new Set();
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
    checkbox: count > 0 ? L('同时删除文件夹内的 {0} 个妙记', count) : null,
    onConfirmChecked: () => requestDeleteFoldersWithMinutes([id]),
    onConfirm: () => deleteFolders([id]),
  };
}

/** Several folders at once (sidebar drag-select); one folder uses the single-folder wording. */
export function requestDeleteFolders(ids) {
  const targets = folders.value.filter((f) => ids.has(f.id));
  if (!targets.length) return;
  if (targets.length === 1) return requestDeleteFolder(targets[0].id);
  const count = targets.reduce((n, f) => n + libraryStats(f.id).count, 0);
  const tids = targets.map((f) => f.id);
  confirmRequest.value = {
    title: L('删除 {0} 个文件夹？', targets.length),
    message: count > 0 ? L('这些文件夹里的 {0} 个妙记不会被删除，仍会保留在「全部」中。', count) : L('这些文件夹都是空的。'),
    confirmTitle: L('删除文件夹'),
    checkbox: count > 0 ? L('同时删除文件夹内的 {0} 个妙记', count) : null,
    onConfirmChecked: () => requestDeleteFoldersWithMinutes(tids),
    onConfirm: () => deleteFolders(tids),
  };
}

async function deleteFolders(ids) {
  const gone = new Set(ids);
  const targets = folders.value.filter((f) => gone.has(f.id));
  if (targets.some((f) => section.value === `folder:${f.id}`)) section.value = 'all';
  for (const f of targets) {
    const changed = await call('lib:deleteFolder', f.id);
    changed.forEach(upsertMinute);
  }
  batch(() => {
    folders.value = folders.value.filter((x) => !gone.has(x.id));
    const sel = new Set(folderSelection.value);
    ids.forEach((id) => sel.delete(id));
    folderSelection.value = sel;
  });
  showToast(targets.length === 1 ? L('已删除文件夹') : L('已删除 {0} 个文件夹', targets.length));
}

/** Second step after "同时删除文件夹内的妙记": the same confirmation as deleting minutes. */
function requestDeleteFoldersWithMinutes(folderIDs) {
  const set = new Set(folderIDs);
  const targets = folders.value.filter((f) => set.has(f.id));
  if (!targets.length) return;
  const ids = minutes.value.filter((m) => !m.deletedAt && m.folderID && set.has(m.folderID)).map((m) => m.id);
  confirmRequest.value = {
    title:
      targets.length === 1
        ? L('删除文件夹「{0}」，并将其中 {1} 个妙记移到回收站？', targets[0].name, ids.length)
        : L('删除 {0} 个文件夹，并将其中 {1} 个妙记移到回收站？', targets.length, ids.length),
    message: L('移到回收站后可以随时恢复。'),
    emphasis: sourceFileNote(ids, false),
    confirmTitle: L('删除并移到回收站'),
    onConfirm: async () => {
      await moveToTrash(ids);
      await deleteFolders(folderIDs);
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
    emphasis: sourceFileNote(ids, false),
    confirmTitle: L('移到回收站'),
    onConfirm: () => moveToTrash(ids),
  };
}

/** What happens to the media: copies inside the app go with the minute, linked originals stay. */
export function sourceFileNote(ids, forever) {
  const ms = ids.map((id) => minutes.value.find((m) => m.id === id)).filter(Boolean);
  const imported = ms.filter((m) => m.storage === 'imported').length;
  const linked = ms.length - imported;
  if (!imported) return L('只删除妙记，链接的原始媒体文件不会被删除。');
  if (forever) {
    if (!linked) return ms.length === 1 ? L('这个妙记的源文件保存在应用内，会和妙记一起删除。') : L('这些妙记的源文件保存在应用内，会和妙记一起删除。');
    return L('其中 {0} 个妙记的源文件保存在应用内，会一起删除；另外 {1} 个只链接了路径，原始媒体文件不会被删除。', imported, linked);
  }
  if (!linked) return ms.length === 1 ? L('这个妙记的源文件保存在应用内，在回收站彻底删除时会一起删除。') : L('这些妙记的源文件保存在应用内，在回收站彻底删除时会一起删除。');
  return L('其中 {0} 个妙记的源文件保存在应用内，彻底删除时会一起删除；另外 {1} 个只链接了路径，原始媒体文件不会被删除。', imported, linked);
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
    emphasis: sourceFileNote(ids, true),
    confirmTitle: L('彻底删除'),
    onConfirm: async () => {
      ids.forEach(cancelSummary);
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
  const saved = await call('lib:patch', id, { title });
  upsertMinute(saved);
  if (detail.value?.minute.value.id === id) detail.value.minute.value = saved;
}

export async function revealMedia(m) {
  try {
    await call('fs:reveal', m.mediaPath);
  } catch (e) {
    if (e.code === 'unreachable') alertError(L('无法访问源文件所在位置'), L('所在的磁盘或网络位置（如 NAS）暂时没有响应。'));
    else alertError(L('找不到媒体文件'), L('文件可能已被移动或删除。打开妙记后可以「重新检测路径」或「重新定位」。'));
  }
}

// ---------- import into the app ----------

/** Copies a linked minute's media into the app. One way: it cannot become a link again. */
export function requestImportIntoApp(id) {
  const m = minutes.value.find((x) => x.id === id);
  if (!m || m.storage === 'imported') return;
  const size = m.mediaSize > 0 ? L('（{0}）', byteText(m.mediaSize)) : '';
  confirmRequest.value = {
    title: L('将「{0}」的源文件导入应用？', m.title),
    message: L('会把源文件复制一份{0}保存在应用内。之后原文件移动、改名，或所在的磁盘、NAS 断开，都不影响播放。', size),
    emphasis: L('导入后不能再改回链接路径，只能连同妙记一起删除。'),
    confirmTitle: L('导入到应用'),
    destructive: false,
    onConfirm: () => importIntoApp(id),
  };
}

async function importIntoApp(id) {
  if (copyingMedia.value.has(id)) return;
  setCopying(id, 0);
  try {
    const m = await call('media:copyIntoApp', id);
    setCopying(id, null);
    if (!m) return;
    upsertMinute(m);
    if (detail.value?.minute.value.id === id) await detail.value.mediaMovedIntoApp(m);
    showToast(L('已将源文件导入应用'));
  } catch (e) {
    setCopying(id, null);
    if (e.code === 'notFound') alertError(L('找不到源文件'), e.message);
    else alertError(L('导入应用失败'), e.message);
  }
}

// ---------- summary generation (background, per minute) ----------

const jobState = (id) => summaryJobs.peek().get(id) || null;

function setJob(id, job) {
  const map = new Map(summaryJobs.peek());
  if (job) map.set(id, job);
  else map.delete(id);
  summaryJobs.value = map;
}

export const isGeneratingSummary = (id) => summaryJobs.value.get(id)?.phase === 'running';

/** Starts (or restarts) generation; it keeps running when the detail page closes. */
export async function startSummary({ minuteID, input, favorite, transcriptHash, cuesHash }) {
  const old = jobState(minuteID);
  if (old?.jobId) call('llm:cancel', old.jobId);
  const jobId = `job-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const model = favorite ? favorite.model : llm.value.model;
  setJob(minuteID, { phase: 'running', text: L('正在生成…'), model, jobId });
  const off = lm.onProgress((p) => {
    if (p.jobId !== jobId || jobState(minuteID)?.jobId !== jobId) return;
    const text = p.type === 'part' ? L('正在生成… 第 {0}/{1} 部分', p.i, p.n) : p.type === 'merging' ? L('正在合并各部分…') : L('正在生成…');
    setJob(minuteID, { ...jobState(minuteID), text });
  });
  try {
    const r = await call('llm:generate', { jobId, input, favorite: favorite || null });
    if (jobState(minuteID)?.jobId !== jobId) return;
    setJob(minuteID, null);
    const summary = {
      id: uuid(),
      ...r.draft,
      model: r.model,
      generatedAt: new Date().toISOString(),
      transcriptHash,
      cuesHash,
      parameters: r.parameters,
    };
    await addSummary(minuteID, summary);
    const m = minutes.value.find((x) => x.id === minuteID);
    if (m && detail.value?.minute.value.id !== minuteID) showToast(L('「{0}」的智能纪要已生成', m.title));
  } catch (e) {
    if (jobState(minuteID)?.jobId !== jobId) return;
    if (e.code === 'cancelled') {
      setJob(minuteID, null);
      return;
    }
    setJob(minuteID, { phase: 'failed', text: e.message, model, jobId: null });
    const m = minutes.value.find((x) => x.id === minuteID);
    if (m && detail.value?.minute.value.id !== minuteID) showToast(L('「{0}」的智能纪要生成失败', m.title));
  } finally {
    off();
  }
}

export function cancelSummary(id) {
  const job = jobState(id);
  if (job?.jobId) call('llm:cancel', job.jobId);
  if (job) setJob(id, null);
}

export function clearSummaryFailure(id) {
  if (jobState(id)?.phase === 'failed') setJob(id, null);
}

/** Stores a new version (generated or imported) and shows it. */
export async function addSummary(minuteID, summary) {
  const r = await call('lib:appendSummary', minuteID, summary);
  if (!r) return;
  upsertMinute(r.minute);
  if (detail.value?.minute.value.id === minuteID) detail.value.summariesChanged(r.list, r.minute);
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
  const saved = await call('lib:patch', id, { lastOpenedAt: new Date().toISOString() });
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
