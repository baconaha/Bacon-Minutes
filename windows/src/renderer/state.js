// App-wide state (Preact signals) and library actions.
import { signal, computed, batch } from '@preact/signals';
import { defaultLLMConfig, applyPreset } from '../core/llm.js';
import { DEFAULT_SUFFIXES } from '../core/pairing.js';
import { fold } from '../core/text.js';

export const lm = window.lm;
export const call = (channel, ...args) => lm.invoke(channel, ...args);

export const route = signal({ name: 'list' }); // { name: 'detail', id }
export const section = signal('all'); // all | recent | trash
export const listQuery = signal('');
export const transcriptMatches = signal(null); // Set of ids matching the query in transcript text
export const minutes = signal([]);
export const loading = signal(true);
export const selection = signal(new Set());
export const toast = signal(null);
export const importDialog = signal(null); // { media, subtitle } while open
export const importing = signal(false);
export const settingsOpen = signal(null); // null | 'api' | 'general'
export const renameTarget = signal(null);
export const detail = signal(null); // DetailModel
export const listSearchFocus = signal(0);

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
});
export const llm = signal(defaultLLMConfig());
export const apiKey = signal('');

export const llmReady = computed(() => {
  const c = llm.value;
  return !!c.baseURL.trim() && !!c.model.trim() && !c.baseURL.includes('{');
});

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
    general.value = s.general;
    llm.value = s.llm;
    apiKey.value = s.apiKey;
  });
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
    minutes.value = await call('lib:list');
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

export const visibleMinutes = computed(() => {
  const sec = section.value;
  let items = minutes.value.filter((m) => (sec === 'trash' ? !!m.deletedAt : !m.deletedAt && (sec !== 'recent' || !!m.lastOpenedAt)));
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

export async function moveToTrash(ids) {
  if (!ids.length) return;
  if (detail.value && ids.includes(detail.value.minute.value.id)) await goBack();
  const updated = await call('lib:trash', ids);
  updated.forEach(upsertMinute);
  const sel = new Set(selection.value);
  ids.forEach((id) => sel.delete(id));
  selection.value = sel;
  showToast(ids.length === 1 ? '已移到回收站' : `已将 ${ids.length} 项移到回收站`);
}

export async function restoreMinutes(ids) {
  if (!ids.length) return;
  const updated = await call('lib:restore', ids);
  updated.forEach(upsertMinute);
  const sel = new Set(selection.value);
  ids.forEach((id) => sel.delete(id));
  selection.value = sel;
  showToast('已恢复');
}

export async function deleteForever(ids) {
  if (!ids.length) return;
  const ok = await call('dialog:confirm', {
    title: ids.length === 1 ? '彻底删除这个妙记？' : `彻底删除 ${ids.length} 个妙记？`,
    message: '删除后无法恢复。原始音视频文件不会被删除。',
    ok: '彻底删除',
    destructive: true,
  });
  if (!ok) return;
  await call('lib:remove', ids);
  batch(() => {
    minutes.value = minutes.value.filter((m) => !ids.includes(m.id));
    const sel = new Set(selection.value);
    ids.forEach((id) => sel.delete(id));
    selection.value = sel;
  });
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
  } catch (e) {
    alertError('找不到媒体文件', `${e.message}。打开妙记后可以「重新定位」。`);
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
    alertError('无法导入字幕', e.message);
  }
}

export function importSummaryText(transcript, duration) {
  const d = duration > 0 ? duration : Math.max(0, ...transcript.cues.map((c) => c.end));
  const total = Math.round(d);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n) => String(n).padStart(2, '0');
  const dur = h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
  return `已导入 ${transcript.cues.length} 条字幕，${transcript.speakers.length} 位发言人，时长 ${dur}`;
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
  batch(() => {
    detail.value = d;
    route.value = { name: 'detail', id };
    selection.value = new Set();
  });
  await d.start();
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
