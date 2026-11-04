const { contextBridge, ipcRenderer, webUtils } = require('electron');

const CHANNELS = new Set([
  'settings:get', 'settings:setGeneral', 'settings:setLLM', 'settings:setApiKey', 'settings:resetCompat', 'settings:encryption',
  'lib:list', 'lib:save', 'lib:get', 'lib:transcript', 'lib:saveTranscript', 'lib:summary', 'lib:saveSummary',
  'lib:trash', 'lib:restore', 'lib:remove', 'lib:search', 'lib:saveCover', 'lib:create', 'lib:attachSrt',
  'fs:expand', 'fs:exists', 'fs:fileURL', 'fs:reveal',
  'dialog:openFiles', 'dialog:openFolder', 'dialog:openMedia', 'dialog:openSrt', 'dialog:confirm', 'dialog:alert', 'dialog:saveText',
  'clipboard:write', 'win:titleBar',
  'llm:test', 'llm:models', 'llm:generate', 'llm:cancel',
]);

contextBridge.exposeInMainWorld('lm', {
  platform: process.platform,
  e2e: process.argv.includes('--lm-e2e'),
  async invoke(channel, ...args) {
    if (!CHANNELS.has(channel)) throw new Error(`unknown channel ${channel}`);
    const r = await ipcRenderer.invoke(channel, ...args);
    if (!r.ok) {
      const e = new Error(r.error);
      e.code = r.code;
      throw e;
    }
    return r.data;
  },
  onProgress(cb) {
    const h = (_e, data) => cb(data);
    ipcRenderer.on('llm:progress', h);
    return () => ipcRenderer.removeListener('llm:progress', h);
  },
  pathForFile(file) {
    return webUtils.getPathForFile(file);
  },
});
