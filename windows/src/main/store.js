// On-disk library: <userData>/minutes/<uuid>/{meta.json, transcript.json, summaries.json, source.srt,
// thumbs/cover.jpg, media/<file>} and <userData>/folders.json. Same layout as the Mac app.
// Nothing here touches a minute's linked media file: on an unreachable network share any such
// call can block the main process, so media checks go through the file-check process (probe.js).
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { parseSRT } from '../core/srt.js';
import { fold } from '../core/text.js';
import { baseName } from '../core/pairing.js';
import { L } from '../core/i18n.js';

function readJSON(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(value));
  fs.renameSync(tmp, file);
}

export class Library {
  constructor(root) {
    this.root = root;
    this.foldersFile = path.join(path.dirname(root), 'folders.json');
    this.searchCache = new Map();
    fs.mkdirSync(root, { recursive: true });
  }

  // ----- folders -----

  folders() {
    return readJSON(this.foldersFile) || [];
  }

  saveFolders(list) {
    writeJSON(this.foldersFile, list);
    return list;
  }

  createFolder(name) {
    const f = { id: randomUUID(), name, createdAt: new Date().toISOString() };
    this.saveFolders([...this.folders(), f]);
    return f;
  }

  renameFolder(id, name) {
    return this.saveFolders(this.folders().map((f) => (f.id === id ? { ...f, name } : f)));
  }

  /** Removes the folder; its minutes stay in the library, just unfiled. */
  deleteFolder(id) {
    this.saveFolders(this.folders().filter((f) => f.id !== id));
    const changed = [];
    for (const m of this.list()) {
      if (m.folderID === id) changed.push(this.update(m.id, (x) => (x.folderID = null)));
    }
    return changed;
  }

  move(ids, folderID) {
    return ids.map((id) => this.update(id, (m) => (m.folderID = folderID || null)));
  }

  folder(id) {
    return path.join(this.root, id);
  }

  coverURL(id) {
    const file = path.join(this.folder(id), 'thumbs', 'cover.jpg');
    try {
      const st = fs.statSync(file);
      return pathToFileURL(file).href + '?v=' + Math.round(st.mtimeMs);
    } catch {
      return null;
    }
  }

  /** Folder holding media imported into the app. */
  mediaDir(id) {
    return path.join(this.folder(id), 'media');
  }

  /** The playable path: the in-app copy for imported minutes, else the linked file. */
  mediaPathOf(m) {
    return m.storage === 'imported' ? path.join(this.mediaDir(m.id), m.mediaFileName) : m.mediaPath;
  }

  withExtras(m) {
    const out = { ...m, storage: m.storage || 'linked', coverURL: this.coverURL(m.id) };
    if (out.storage === 'imported') out.mediaPath = this.mediaPathOf(out);
    return out;
  }

  /** All minutes. Trash is kept until the user deletes it. */
  list() {
    const out = [];
    let dirs = [];
    try {
      dirs = fs.readdirSync(this.root, { withFileTypes: true }).filter((d) => d.isDirectory() && !d.name.startsWith('.'));
    } catch {
      return out;
    }
    for (const d of dirs) {
      const meta = readJSON(path.join(this.root, d.name, 'meta.json'));
      if (meta?.id) out.push(this.withExtras(meta));
    }
    return out;
  }

  get(id) {
    return readJSON(path.join(this.folder(id), 'meta.json'));
  }

  save(meta) {
    const clean = { ...meta };
    delete clean.coverURL;
    delete clean.mediaExists;
    writeJSON(path.join(this.folder(meta.id), 'meta.json'), clean);
    return this.withExtras(clean);
  }

  update(id, change) {
    const m = this.get(id);
    if (!m) throw new Error(L('找不到该妙记'));
    change(m);
    return this.save(m);
  }

  create({ id = randomUUID(), mediaPath, title, createdAt, duration, isAudioOnly, folderID, storage = 'linked', mediaSize = null }) {
    return this.save({
      id,
      title,
      createdAt: createdAt || new Date().toISOString(),
      lastOpenedAt: null,
      duration: duration || 0,
      mediaPath,
      mediaFileName: baseName(mediaPath),
      isAudioOnly: !!isAudioOnly,
      srtPath: null,
      srtFileName: null,
      cueCount: 0,
      speakerCount: 0,
      hasSummary: false,
      deletedAt: null,
      lastPlaybackPosition: 0,
      folderID: folderID || null,
      mediaSize,
      storage,
      activeSummaryID: null,
    });
  }

  loadTranscript(id) {
    return readJSON(path.join(this.folder(id), 'transcript.json'));
  }

  saveTranscript(id, t) {
    writeJSON(path.join(this.folder(id), 'transcript.json'), t);
    this.searchCache.delete(id);
  }

  /** Every summary version, oldest first. A single summary.json from older builds is moved in. */
  loadSummaries(id) {
    const dir = this.folder(id);
    const list = readJSON(path.join(dir, 'summaries.json'));
    if (Array.isArray(list)) return list;
    const old = readJSON(path.join(dir, 'summary.json'));
    if (!old) return [];
    const migrated = [{ ...old, id: old.id || randomUUID() }];
    writeJSON(path.join(dir, 'summaries.json'), migrated);
    fs.rmSync(path.join(dir, 'summary.json'), { force: true });
    return migrated;
  }

  saveSummaries(id, list) {
    const file = path.join(this.folder(id), 'summaries.json');
    if (list?.length) writeJSON(file, list);
    else fs.rmSync(file, { force: true });
  }

  /** Adds a version and makes it the one shown; null when the minute is gone. */
  appendSummary(id, summary) {
    if (!this.get(id)) return null;
    const list = [...this.loadSummaries(id), summary];
    this.saveSummaries(id, list);
    const minute = this.update(id, (m) => {
      m.hasSummary = true;
      m.activeSummaryID = summary.id;
    });
    return { list, minute };
  }

  /** A minute whose subtitles have this cues hash (exported summaries find their minute). */
  findByCuesHash(hash, cueCount, cuesHashOf) {
    for (const m of this.list()) {
      if (m.deletedAt || (cueCount != null && m.cueCount !== cueCount)) continue;
      const t = this.loadTranscript(m.id);
      if (t && cuesHashOf(t) === hash) return m;
    }
    return null;
  }

  saveCover(id, base64) {
    const file = path.join(this.folder(id), 'thumbs', 'cover.jpg');
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, Buffer.from(base64, 'base64'));
    return this.coverURL(id);
  }

  /**
   * Parses an SRT, copies it into the minute folder and updates the minute (§9.2, §9.4).
   * Speakers that were renamed keep their names when their ids reappear.
   */
  attachSRT(id, srtPath) {
    const data = fs.readFileSync(srtPath);
    const result = parseSRT(new Uint8Array(data));
    const old = this.loadTranscript(id);
    if (old) {
      for (const s of result.speakers) {
        const prev = old.speakers.find((p) => p.id === s.id);
        if (prev) s.name = prev.name;
      }
    }
    const transcript = { cues: result.cues, speakers: result.speakers, srtFileName: baseName(srtPath), importedAt: new Date().toISOString() };
    this.saveTranscript(id, transcript);
    fs.writeFileSync(path.join(this.folder(id), 'source.srt'), data);
    const minute = this.update(id, (m) => {
      m.srtPath = srtPath;
      m.srtFileName = baseName(srtPath);
      m.cueCount = transcript.cues.length;
      m.speakerCount = transcript.speakers.length;
      if (!(m.duration > 0)) m.duration = Math.max(0, ...transcript.cues.map((c) => c.end));
    });
    return { minute, transcript };
  }

  trash(ids) {
    const now = new Date().toISOString();
    return ids.map((id) => this.update(id, (m) => (m.deletedAt = now)));
  }

  restore(ids) {
    return ids.map((id) => this.update(id, (m) => (m.deletedAt = null)));
  }

  remove(ids) {
    for (const id of ids) {
      fs.rmSync(this.folder(id), { recursive: true, force: true });
      this.searchCache.delete(id);
    }
  }

  /** Ids whose transcript text contains the (folded) query. */
  searchTranscripts(query) {
    const q = fold(query.trim());
    if (!q) return [];
    const hits = [];
    for (const m of this.list()) {
      let text = this.searchCache.get(m.id);
      if (text == null) {
        const t = this.loadTranscript(m.id);
        text = t ? fold(t.cues.map((c) => c.text).join('\n')) : '';
        this.searchCache.set(m.id, text);
      }
      if (text.includes(q)) hits.push(m.id);
    }
    return hits;
  }
}
