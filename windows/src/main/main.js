import { app, BrowserWindow, ipcMain, dialog, shell, Menu, net, nativeTheme, safeStorage, clipboard } from 'electron';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { Library } from './store.js';
import { SettingsStore } from './settings.js';
import { LLMClient } from '../core/llm.js';
import { generateSummary } from '../core/summary.js';
import { MEDIA_EXT, SUB_EXT, isMedia, isSubtitle } from '../core/pairing.js';

const E2E = process.env.LOCALMINUTES_E2E === '1';
if (process.env.LOCALMINUTES_USER_DATA) app.setPath('userData', process.env.LOCALMINUTES_USER_DATA);

let win = null;
let library = null;
let settings = null;
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

function createWindow() {
  const dark = nativeTheme.shouldUseDarkColors;
  win = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 1024,
    minHeight: 700,
    title: '本地妙记',
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
  win.once('ready-to-show', () => win.show());
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  // Dropping a file outside a drop zone must not navigate away from the app.
  win.webContents.on('will-navigate', (e) => e.preventDefault());
  win.webContents.on('context-menu', (_e, params) => {
    const items = [];
    if (params.isEditable) {
      items.push({ role: 'cut', label: '剪切' }, { role: 'copy', label: '复制' }, { role: 'paste', label: '粘贴' }, { type: 'separator' }, { role: 'selectAll', label: '全选' });
    } else if (params.selectionText) {
      items.push({ role: 'copy', label: '复制' });
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
  files.sort((a, b) => a.localeCompare(b, 'zh-Hans-CN', { numeric: true }));
  return { media: files.filter(isMedia), subtitles: files.filter(isSubtitle), otherCount: files.filter((f) => !isMedia(f) && !isSubtitle(f)).length };
}

function llmClient() {
  return new LLMClient({ fetch: (url, init) => net.fetch(url, init), compat: settings.compat });
}

function registerIPC() {
  // ----- settings -----
  handle('settings:get', () => ({ general: settings.general, llm: settings.llm, apiKey: settings.apiKey() }));
  handle('settings:setGeneral', (patch) => settings.setGeneral(patch));
  handle('settings:setLLM', (config) => {
    const before = settings.llm.presetID;
    const llm = settings.setLLM(config);
    return { llm, apiKey: before !== llm.presetID ? settings.apiKey() : undefined };
  });
  handle('settings:setApiKey', (key) => settings.setApiKey(key));
  handle('settings:resetCompat', () => settings.resetCompat());
  handle('settings:encryption', () => safeStorage.isEncryptionAvailable());

  // ----- library -----
  handle('lib:list', () => library.list());
  handle('lib:save', (meta) => library.save(meta));
  handle('lib:get', (id) => {
    const m = library.get(id);
    return m ? library.withExtras(m) : null;
  });
  handle('lib:transcript', (id) => library.loadTranscript(id));
  handle('lib:saveTranscript', (id, t) => library.saveTranscript(id, t));
  handle('lib:summary', (id) => library.loadSummary(id));
  handle('lib:saveSummary', (id, s) => library.saveSummary(id, s));
  handle('lib:trash', (ids) => library.trash(ids));
  handle('lib:restore', (ids) => library.restore(ids));
  handle('lib:remove', (ids) => library.remove(ids));
  handle('lib:search', (q) => library.searchTranscripts(q));
  handle('lib:saveCover', (id, base64) => library.saveCover(id, base64));
  handle('lib:create', (info) => library.create(info));
  handle('lib:attachSrt', (id, srtPath) => library.attachSRT(id, srtPath));

  // ----- files -----
  handle('fs:expand', (paths) => expandPaths(paths));
  handle('fs:exists', (p) => !!p && fs.existsSync(p));
  handle('fs:fileURL', (p) => pathToFileURL(p).href);
  handle('fs:reveal', (p) => {
    if (p && fs.existsSync(p)) shell.showItemInFolder(p);
    else throw new Error('找不到该文件，可能已被移动或删除');
  });

  // ----- dialogs -----
  const mediaFilter = { name: '音视频', extensions: MEDIA_EXT };
  const srtFilter = { name: 'SRT 字幕', extensions: SUB_EXT };
  handle('dialog:openFiles', async () => {
    const r = await dialog.showOpenDialog(win, { properties: ['openFile', 'multiSelections'], filters: [{ name: '音视频与字幕', extensions: [...MEDIA_EXT, ...SUB_EXT] }] });
    return r.canceled ? [] : r.filePaths;
  });
  handle('dialog:openFolder', async () => {
    const r = await dialog.showOpenDialog(win, { properties: ['openDirectory'], buttonLabel: '导入' });
    return r.canceled ? null : r.filePaths[0];
  });
  handle('dialog:openMedia', async () => {
    const r = await dialog.showOpenDialog(win, { properties: ['openFile'], filters: [mediaFilter] });
    return r.canceled ? null : r.filePaths[0];
  });
  handle('dialog:openSrt', async () => {
    const r = await dialog.showOpenDialog(win, { properties: ['openFile'], filters: [srtFilter] });
    return r.canceled ? null : r.filePaths[0];
  });
  handle('dialog:confirm', async ({ title, message, ok = '确定', cancel = '取消', destructive = false }) => {
    if (E2E) return true;
    const r = await dialog.showMessageBox(win, { type: destructive ? 'warning' : 'question', title: '本地妙记', message: title, detail: message, buttons: [ok, cancel], defaultId: 0, cancelId: 1, noLink: true });
    return r.response === 0;
  });
  handle('dialog:alert', async ({ title, message, error = false }) => {
    if (E2E) {
      console.log(`[alert] ${title}: ${message}`);
      return;
    }
    await dialog.showMessageBox(win, { type: error ? 'error' : 'info', title: '本地妙记', message: title, detail: message, buttons: ['好'], noLink: true });
  });
  handle('dialog:saveText', async ({ text, name, ext }) => {
    const safe = (name || '妙记').replace(/[\\/:*?"<>|]/g, '_').slice(0, 120) || '妙记';
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
  handle('llm:generate', async ({ jobId, input }, event) => {
    const ac = new AbortController();
    jobs.set(jobId, ac);
    try {
      const config = settings.llm;
      const draft = await generateSummary({
        client: llmClient(),
        input,
        config,
        apiKey: settings.apiKey(),
        signal: ac.signal,
        progress: (p) => {
          if (!event.sender.isDestroyed()) event.sender.send('llm:progress', { jobId, ...p });
        },
      });
      return { draft, model: config.model };
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
  settings = new SettingsStore(path.join(userData, 'settings.json'), safeStorage);
  registerIPC();
  createWindow();
});

app.on('window-all-closed', () => app.quit());
