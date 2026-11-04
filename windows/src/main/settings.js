// Settings in <userData>/settings.json. API keys are encrypted with Electron safeStorage
// (DPAPI on Windows), one per provider preset.
import fs from 'node:fs';
import path from 'node:path';
import { defaultLLMConfig } from '../core/llm.js';
import { DEFAULT_SUFFIXES } from '../core/pairing.js';

export function defaultGeneral() {
  return {
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
    /** UI language id, or null to follow the system. */
    language: null,
  };
}

export class SettingsStore {
  constructor(file, safeStorage) {
    this.file = file;
    this.safe = safeStorage;
    const raw = (() => {
      try {
        return JSON.parse(fs.readFileSync(file, 'utf8'));
      } catch {
        return {};
      }
    })();
    this.data = {
      general: { ...defaultGeneral(), ...(raw.general || {}) },
      llm: { ...defaultLLMConfig(), ...(raw.llm || {}) },
      compat: raw.compat || {},
      keys: raw.keys || {},
    };
  }

  persist() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    fs.writeFileSync(this.file, JSON.stringify(this.data, null, 2));
  }

  get general() {
    return this.data.general;
  }

  get llm() {
    return this.data.llm;
  }

  setGeneral(patch) {
    this.data.general = { ...this.data.general, ...patch };
    this.persist();
    return this.data.general;
  }

  setLLM(config) {
    this.data.llm = { ...defaultLLMConfig(), ...config };
    this.persist();
    return this.data.llm;
  }

  apiKey(presetID = this.data.llm.presetID) {
    const entry = this.data.keys[presetID];
    if (!entry) return '';
    if (entry.enc && this.safe?.isEncryptionAvailable()) {
      try {
        return this.safe.decryptString(Buffer.from(entry.enc, 'base64'));
      } catch {
        return '';
      }
    }
    return entry.plain || '';
  }

  setApiKey(key, presetID = this.data.llm.presetID) {
    const value = (key || '').trim();
    if (!value) delete this.data.keys[presetID];
    else if (this.safe?.isEncryptionAvailable()) this.data.keys[presetID] = { enc: this.safe.encryptString(value).toString('base64') };
    else this.data.keys[presetID] = { plain: value };
    this.persist();
  }

  get compat() {
    return {
      get: (k) => this.data.compat[k],
      set: (k, flags) => {
        this.data.compat[k] = flags;
        this.persist();
      },
    };
  }

  resetCompat() {
    this.data.compat = {};
    this.persist();
  }
}
