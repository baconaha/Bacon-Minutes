import { app, BrowserWindow, ipcMain, dialog, shell, Menu, net, nativeTheme, safeStorage, clipboard, nativeImage } from 'electron';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
import { Library } from './store.js';
import { SettingsStore } from './settings.js';
import { FsProbe } from './probe.js';
import { LLMClient, applyFavorite, summaryParameters } from '../core/llm.js';
import { generateSummary } from '../core/summary.js';
import { PROMPT_VERSION } from '../core/prompts.js';
import { cuesHash } from '../core/paragraphs.js';
import { MEDIA_EXT, SUB_EXT, isMedia, isSubtitle, isUnsupported, isSummaryFile, baseName, SUMMARY_EXT } from '../core/pairing.js';
import { L, setLanguage, bestLanguage } from '../core/i18n.js';

const E2E = process.env.LOCALMINUTES_E2E === '1';

// Data lives in %APPDATA%\BaconMinutes. Builds from before the rename used the product name
// "本地妙记" as the folder; it is moved over once.
if (process.env.LOCALMINUTES_USER_DATA) {
  app.setPath('userData', process.env.LOCALMINUTES_USER_DATA);
} else {
  const appData = app.getPath('appData');
  const dataDir = path.join(appData, 'BaconMinutes');
  const legacy = path.join(appData, '本地妙记');
  if (!fs.existsSync(dataDir) && fs.existsSync(legacy)) {
    try {
      fs.renameSync(legacy, dataDir);
    } catch {
      // in use or not movable: start fresh rather than fail
    }
  }
  app.setPath('userData', dataDir);
}

let win = null;
let library = null;
let settings = null;
let probe = null;
const jobs = new Map();

if (!E2E && !app.requestSingleInstanceLock()) {
  app.quit();
}

app.on('second-instance', () => {
  if (win) {
    if (win.isMinimized()) win.restore();
    win.focus();
  }
});

function systemLanguage() {
  if (process.env.LOCALMINUTES_LANG) return bestLanguage([process.env.LOCALMINUTES_LANG]);
  const prefs = typeof app.getPreferredSystemLanguages === 'function' ? app.getPreferredSystemLanguages() : [];
  return bestLanguage([...prefs, app.getLocale()]);
}

function applyLanguage() {
  setLanguage(settings.general.language || systemLanguage());
  win?.setTitle(L('培根妙记'));
}

// ----- app icon (shared by the window, the taskbar and the in-app logo) -----

const iconFile = () => path.join(app.getPath('userData'), 'custom-icon.png');
const defaultIcon = () => nativeImage.createFromPath(path.join(__dirname, 'icon.png'));

function customIcon() {
  const img = nativeImage.createFromPath(iconFile());
  return img.isEmpty() ? null : img;
}

/** Crops transparent margins, then center-crops to a square (like the Mac app). */
function normalizedArtwork(img) {
  const { width, height } = img.getSize();
  const bmp = img.toBitmap(); // BGRA
  let minX = width, minY = height, maxX = -1, maxY = -1;
  const step = Math.max(1, Math.floor(Math.min(width, height) / 256));
  for (let y = 0; y < height; y += step) {
    for (let x = 0; x < width; x += step) {
      if (bmp[(y * width + x) * 4 + 3] > 25) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  let crop = { x: 0, y: 0, width, height };
  if (maxX >= minX && maxY >= minY) {
    crop = { x: minX, y: minY, width: Math.min(width - minX, maxX - minX + step), height: Math.min(height - minY, maxY - minY + step) };
  }
  const side = Math.min(crop.width, crop.height);
  const square = { x: Math.round(crop.x + (crop.width - side) / 2), y: Math.round(crop.y + (crop.height - side) / 2), width: side, height: side };
  return img.crop(square).resize({ width: 512, height: 512, quality: 'best' });
}

function applyWindowIcon() {
  if (!win) return;
  const img = customIcon() || defaultIcon();
  if (!img.isEmpty()) win.setIcon(img);
}

function createWindow() {
  const dark = nativeTheme.shouldUseDarkColors;
  win = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 1024,
    minHeight: 700,
    title: L('培根妙记'),
    show: false,
    backgroundColor: dark ? '#1B1C1F' : '#F5F6FA',
    titleBarStyle: 'hidden',
    titleBarOverlay: { color: dark ? '#1B1C1F' : '#F5F6F7', symbolColor: dark ? '#E6E8EB' : '#1F2329', height: 40 },
    icon: path.join(__dirname, 'icon.png'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      spellcheck: false,
      additionalArguments: E2E ? ['--lm-e2e'] : [],
    },
  });
  applyWindowIcon();
  win.once('ready-to-show', () => win.show());
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  // Dropping a file outside a drop zone must not navigate away from the app.
  win.webContents.on('will-navigate', (e) => e.preventDefault());
  // The page sets its own title; keep the app name.
  win.on('page-title-updated', (e) => e.preventDefault());
  win.webContents.on('context-menu', (_e, params) => {
    const items = [];
    if (params.isEditable) {
      items.push({ role: 'cut', label: L('剪切') }, { role: 'copy', label: L('复制') }, { role: 'paste', label: L('粘贴') }, { type: 'separator' }, { role: 'selectAll', label: L('全选') });
    } else if (params.selectionText) {
      items.push({ role: 'copy', label: L('复制') });
    }
    if (items.length) Menu.buildFromTemplate(items).popup({ window: win });
  });
  win.loadFile(path.join(__dirname, 'index.html'));
}

/** Handlers return `{ ok, data }` / `{ ok:false, error }` so error text survives IPC. */
function handle(channel, fn) {
  ipcMain.handle(channel, async (event, ...args) => {
    try {
      return { ok: true, data: await fn(...args, event) };
    } catch (e) {
      return { ok: false, error: e?.message || String(e), code: e?.code };
    }
  });
}

function expandPaths(paths) {
  const files = [];
  let dirName = null;
  const walk = (p, depth) => {
    let st;
    try {
      st = fs.statSync(p);
    } catch {
      return;
    }
    if (st.isDirectory()) {
      if (depth > 8) return;
      for (const name of fs.readdirSync(p)) {
        if (!name.startsWith('.')) walk(path.join(p, name), depth + 1);
      }
    } else {
      files.push(p);
    }
  };
  for (const p of paths) walk(p, 0);
  if (paths.length === 1) {
    try {
      if (fs.statSync(paths[0]).isDirectory()) dirName = baseName(paths[0].replace(/[\\/]+$/, ''));
    } catch {
      // gone meanwhile
    }
  }
  files.sort((a, b) => a.localeCompare(b, 'zh-Hans-CN', { numeric: true }));
  const other = files.filter((f) => !isMedia(f) && !isSubtitle(f));
  return {
    media: files.filter(isMedia),
    subtitles: files.filter(isSubtitle),
    unsupported: other.filter(isUnsupported),
    summaryFiles: other.filter(isSummaryFile),
    otherCount: other.length,
    dirName,
  };
}

/** Progress of a copy into the app, to the window that asked for it. */
function sendCopyProgress(event, key, fraction) {
  if (key != null && !event.sender.isDestroyed()) event.sender.send('copy:progress', { key, fraction });
}

function unreachableError() {
  const e = new Error(L('所在的磁盘或网络位置（如 NAS）暂时没有响应。'));
  e.code = 'unreachable';
  return e;
}

function copyError(e) {
  return new Error(L('复制到应用失败：{0}', e.code === 'stalled' ? L('所在的磁盘或网络位置（如 NAS）暂时没有响应。') : e.message));
}

function llmClient() {
  return new LLMClient({ fetch: (url, init) => net.fetch(url, init), compat: settings.compat });
}

function registerIPC() {
  // ----- settings -----
  handle('settings:get', () => ({ general: settings.general, llm: settings.llm, apiKey: settings.apiKey(), favorites: settings.favorites, systemLanguage: systemLanguage() }));
  handle('settings:setFavorites', (list) => settings.setFavorites(list));
  handle('settings:setGeneral', (patch) => {
    const g = settings.setGeneral(patch);
    if ('language' in patch) applyLanguage();
    return g;
  });
  handle('settings:setLLM', (config) => {
    const before = settings.llm.presetID;
    const llm = settings.setLLM(config);
    return { llm, apiKey: before !== llm.presetID ? settings.apiKey() : undefined };
  });
  handle('settings:setApiKey', (key) => settings.setApiKey(key));
  handle('settings:resetCompat', () => settings.resetCompat());
  handle('settings:encryption', () => safeStorage.isEncryptionAvailable());

  // ----- app icon -----
  handle('icon:get', () => customIcon()?.toDataURL() || null);
  handle('icon:choose', async () => {
    const r = await dialog.showOpenDialog(win, {
      title: L('选择一张图片作为应用图标'),
      properties: ['openFile'],
      filters: [{ name: L('图片'), extensions: ['png', 'jpg', 'jpeg', 'bmp', 'gif', 'webp', 'ico'] }],
    });
    if (r.canceled || !r.filePaths[0]) return null;
    const img = nativeImage.createFromPath(r.filePaths[0]);
    if (img.isEmpty()) throw new Error(L('无法读取这张图片'));
    const art = normalizedArtwork(img);
    fs.writeFileSync(iconFile(), art.toPNG());
    applyWindowIcon();
    return art.toDataURL();
  });
  handle('icon:reset', () => {
    fs.rmSync(iconFile(), { force: true });
    applyWindowIcon();
    return null;
  });

  // ----- library -----
  handle('lib:list', () => library.list());
  handle('lib:save', (meta) => {
    // Media copied into the app never goes back to being a link, whatever an older copy says.
    const disk = library.get(meta.id);
    if (disk?.storage === 'imported' && meta.storage !== 'imported') {
      meta = { ...meta, storage: 'imported', mediaPath: disk.mediaPath, mediaFileName: disk.mediaFileName };
    }
    return library.save(meta);
  });
  /** Changes only the given fields of what is on disk (positions, titles, flags). */
  handle('lib:patch', (id, patch) => library.update(id, (m) => Object.assign(m, patch)));
  handle('lib:get', (id) => {
    const m = library.get(id);
    return m ? library.withExtras(m) : null;
  });
  handle('lib:transcript', (id) => library.loadTranscript(id));
  handle('lib:saveTranscript', (id, t) => library.saveTranscript(id, t));
  handle('lib:summaries', (id) => library.loadSummaries(id));
  handle('lib:saveSummaries', (id, list) => library.saveSummaries(id, list));
  handle('lib:appendSummary', (id, summary) => library.appendSummary(id, summary));
  handle('lib:findBySummary', ({ cuesHash: hash, cueCount, mediaFileName }) => {
    if (hash) {
      const m = library.findByCuesHash(hash, cueCount, cuesHash);
      if (m) return m;
    }
    const name = (mediaFileName || '').toLowerCase();
    return (name && library.list().find((m) => !m.deletedAt && (m.mediaFileName || '').toLowerCase() === name)) || null;
  });
  handle('lib:trash', (ids) => library.trash(ids));
  handle('lib:restore', (ids) => library.restore(ids));
  handle('lib:remove', (ids) => library.remove(ids));
  handle('lib:search', (q) => library.searchTranscripts(q));
  handle('lib:saveCover', (id, base64) => library.saveCover(id, base64));
  handle('lib:create', async (info, token, event) => {
    const src = info.mediaPath;
    const st = await probe.stat(src, { force: true });
    if (st.state === 'unreachable') throw unreachableError();
    if (st.state !== 'found') throw new Error(L('找不到该文件，可能已被移动或删除'));
    if (info.storage === 'imported') {
      const id = randomUUID();
      const dest = path.join(library.mediaDir(id), baseName(src));
      try {
        await probe.copy(src, dest, (f) => sendCopyProgress(event, token, f));
      } catch (e) {
        fs.rmSync(library.folder(id), { recursive: true, force: true });
        throw copyError(e);
      }
      return library.create({ ...info, id, mediaPath: dest, storage: 'imported', mediaSize: st.size });
    }
    return library.create({ ...info, storage: 'linked', mediaSize: st.size });
  });
  /** "导入到应用": copies a linked minute's media into the app (one way). */
  handle('media:copyIntoApp', async (id, event) => {
    const m = library.get(id);
    if (!m) throw new Error(L('找不到该妙记'));
    if (m.storage === 'imported') return library.withExtras(m);
    const st = await probe.stat(m.mediaPath, { force: true });
    if (st.state !== 'found') {
      const e = new Error(L('请先在妙记里「重新检测路径」或「重新定位」，再导入应用。'));
      e.code = 'notFound';
      throw e;
    }
    const dest = path.join(library.mediaDir(id), baseName(m.mediaPath));
    try {
      await probe.copy(m.mediaPath, dest, (f) => sendCopyProgress(event, id, f));
    } catch (e) {
      fs.rmSync(dest, { force: true });
      throw copyError(e);
    }
    if (!library.get(id)) {
      fs.rmSync(library.folder(id), { recursive: true, force: true });
      return null;
    }
    return library.update(id, (x) => {
      x.storage = 'imported';
      x.mediaPath = dest;
      x.mediaFileName = baseName(dest);
      if (x.mediaSize == null) x.mediaSize = st.size;
    });
  });
  /** "重新定位" on a minute whose media is in the app: the new file is copied in too. */
  handle('media:replaceImported', async (id, src, event) => {
    const m = library.get(id);
    if (!m) throw new Error(L('找不到该妙记'));
    const st = await probe.stat(src, { force: true });
    if (st.state !== 'found') throw st.state === 'unreachable' ? unreachableError() : new Error(L('找不到该文件，可能已被移动或删除'));
    const old = library.mediaPathOf(m);
    const dest = path.join(library.mediaDir(id), baseName(src));
    try {
      await probe.copy(src, dest, (f) => sendCopyProgress(event, id, f));
    } catch (e) {
      throw copyError(e);
    }
    if (path.resolve(old) !== path.resolve(dest)) fs.rmSync(old, { force: true });
    return library.update(id, (x) => {
      x.storage = 'imported';
      x.mediaPath = dest;
      x.mediaFileName = baseName(dest);
      x.mediaSize = st.size;
    });
  });
  /** Where a minute's media is: found, missing, or on a share that does not answer. */
  handle('media:probe', async (id, opts = {}) => {
    const m = library.get(id);
    if (!m) throw new Error(L('找不到该妙记'));
    const p = library.mediaPathOf(m);
    if (m.storage === 'imported') {
      try {
        const st = await fs.promises.stat(p);
        return { state: st.isFile() ? 'found' : 'missing', path: p, size: st.size };
      } catch {
        return { state: 'missing', path: p };
      }
    }
    return { ...(await probe.stat(p, { force: !!opts.force })), path: p };
  });
  handle('media:stat', (p) => probe.stat(p));
  /** Sizes of minutes imported before sizes were recorded, measured without blocking. */
  handle('lib:backfillSizes', async () => {
    const out = [];
    for (const m of library.list()) {
      if (m.mediaSize != null || m.storage === 'imported' || !m.mediaPath) continue;
      const st = await probe.stat(m.mediaPath);
      if (st.state === 'found') out.push(library.update(m.id, (x) => (x.mediaSize = st.size)));
    }
    return out;
  });
  handle('lib:attachSrt', (id, srtPath) => library.attachSRT(id, srtPath));
  handle('lib:folders', () => library.folders());
  handle('lib:createFolder', (name) => library.createFolder(name));
  handle('lib:renameFolder', (id, name) => library.renameFolder(id, name));
  handle('lib:deleteFolder', (id) => library.deleteFolder(id));
  handle('lib:move', (ids, folderID) => library.move(ids, folderID));

  // ----- files -----
  handle('fs:expand', (paths) => expandPaths(paths));
  handle('fs:exists', async (p) => (await probe.stat(p)).state === 'found');
  handle('fs:fileURL', (p) => pathToFileURL(p).href);
  handle('fs:readText', (p) => fs.promises.readFile(p, 'utf8'));
  handle('fs:reveal', async (p) => {
    const st = await probe.stat(p, { force: true });
    if (st.state === 'found') shell.showItemInFolder(p);
    else if (st.state === 'unreachable') throw unreachableError();
    else throw new Error(L('找不到该文件，可能已被移动或删除'));
  });

  // ----- dialogs -----
  const mediaFilter = () => ({ name: L('音视频'), extensions: MEDIA_EXT });
  const srtFilter = () => ({ name: L('SRT 字幕'), extensions: SUB_EXT });
  handle('dialog:openFiles', async () => {
    const r = await dialog.showOpenDialog(win, {
      title: L('选择音视频文件，可同时选择对应的 SRT 字幕'),
      properties: ['openFile', 'multiSelections'],
      filters: [{ name: L('音视频与字幕'), extensions: [...MEDIA_EXT, ...SUB_EXT] }],
    });
    return r.canceled ? [] : r.filePaths;
  });
  handle('dialog:openFolder', async () => {
    const r = await dialog.showOpenDialog(win, { title: L('选择包含音视频与 SRT 字幕的文件夹'), properties: ['openDirectory'], buttonLabel: L('导入') });
    return r.canceled ? null : r.filePaths[0];
  });
  handle('dialog:openMedia', async () => {
    const r = await dialog.showOpenDialog(win, { title: L('选择音视频文件（mp4 / mov / m4v / mp3 / m4a / wav / aac）'), properties: ['openFile'], filters: [mediaFilter()] });
    return r.canceled ? null : r.filePaths[0];
  });
  handle('dialog:openSummaryFile', async () => {
    const r = await dialog.showOpenDialog(win, {
      title: L('选择纪要文件（.{0}）', SUMMARY_EXT),
      properties: ['openFile'],
      filters: [{ name: L('纪要文件'), extensions: [SUMMARY_EXT] }],
    });
    return r.canceled ? null : r.filePaths[0];
  });
  handle('dialog:openSrt', async () => {
    const r = await dialog.showOpenDialog(win, { title: L('选择 SRT 字幕文件'), properties: ['openFile'], filters: [srtFilter()] });
    return r.canceled ? null : r.filePaths[0];
  });
  handle('dialog:confirm', async ({ title, message, ok = L('确定'), cancel = L('取消'), destructive = false }) => {
    if (E2E) return true;
    const r = await dialog.showMessageBox(win, { type: destructive ? 'warning' : 'question', title: L('培根妙记'), message: title, detail: message, buttons: [ok, cancel], defaultId: 0, cancelId: 1, noLink: true });
    return r.response === 0;
  });
  handle('dialog:alert', async ({ title, message, error = false }) => {
    if (E2E) {
      console.log(`[alert] ${title}: ${message}`);
      return;
    }
    await dialog.showMessageBox(win, { type: error ? 'error' : 'info', title: L('培根妙记'), message: title, detail: message, buttons: [L('好')], noLink: true });
  });
  handle('dialog:saveText', async ({ text, name, ext }) => {
    const fallback = L('妙记');
    const safe = (name || fallback).replace(/[\\/:*?"<>|]/g, '_').slice(0, 120) || fallback;
    // End-to-end tests save without the native dialog.
    if (E2E && process.env.BACON_E2E_SAVE_DIR) {
      fs.mkdirSync(process.env.BACON_E2E_SAVE_DIR, { recursive: true });
      fs.writeFileSync(path.join(process.env.BACON_E2E_SAVE_DIR, `${safe}.${ext}`), text, 'utf8');
      return true;
    }
    const r = await dialog.showSaveDialog(win, { defaultPath: `${safe}.${ext}`, filters: [{ name: ext.toUpperCase(), extensions: [ext] }] });
    if (r.canceled || !r.filePath) return false;
    fs.writeFileSync(r.filePath, '﻿'.repeat(ext === 'txt' ? 1 : 0) + text, 'utf8');
    return true;
  });

  // ----- misc -----
  handle('clipboard:write', (text) => clipboard.writeText(text));
  handle('win:titleBar', ({ color, symbolColor }) => {
    if (win && typeof win.setTitleBarOverlay === 'function' && process.platform !== 'darwin') {
      win.setTitleBarOverlay({ color, symbolColor, height: 40 });
    }
  });

  // ----- LLM -----
  handle('llm:test', (config, apiKey) => llmClient().testConnection(config, apiKey));
  handle('llm:models', (config, apiKey) => llmClient().listModels(config, apiKey));
  handle('llm:generate', async ({ jobId, input, favorite }, event) => {
    const ac = new AbortController();
    jobs.set(jobId, ac);
    try {
      // A starred model runs on its own endpoint and provider key; the rest of the settings stay.
      const config = favorite ? applyFavorite(settings.llm, favorite) : settings.llm;
      const draft = await generateSummary({
        client: llmClient(),
        input,
        config,
        apiKey: settings.apiKey(config.presetID),
        signal: ac.signal,
        progress: (p) => {
          if (!event.sender.isDestroyed()) event.sender.send('llm:progress', { jobId, ...p });
        },
      });
      return { draft, model: config.model, parameters: summaryParameters(config, PROMPT_VERSION) };
    } finally {
      jobs.delete(jobId);
    }
  });
  handle('llm:cancel', (jobId) => {
    jobs.get(jobId)?.abort();
    jobs.delete(jobId);
  });
}

app.whenReady().then(() => {
  Menu.setApplicationMenu(null);
  if (E2E && process.env.LOCALMINUTES_THEME) nativeTheme.themeSource = process.env.LOCALMINUTES_THEME;
  const userData = app.getPath('userData');
  library = new Library(path.join(userData, 'minutes'));
  probe = new FsProbe(path.join(__dirname, 'fs-worker.cjs'));
  settings = new SettingsStore(path.join(userData, 'settings.json'), safeStorage);
  applyLanguage();
  registerIPC();
  createWindow();
});

app.on('window-all-closed', () => app.quit());
