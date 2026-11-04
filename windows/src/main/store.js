// On-disk library: <userData>/minutes/<uuid>/{meta.json, transcript.json, summary.json, source.srt, thumbs/cover.jpg}
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { parseSRT } from '../core/srt.js';
import { fold } from '../core/text.js';
import { baseName } from '../core/pairing.js';

export const TRASH_DAYS = 30;

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
    this.searchCache = new Map();
    fs.mkdirSync(root, { recursive: true });
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

  withExtras(m) {
    return { ...m, coverURL: this.coverURL(m.id), mediaExists: !!m.mediaPath && fs.existsSync(m.mediaPath) };
  }

  /** All minutes; trash older than 30 days is deleted on the way. */
  list() {
    const out = [];
    const cutoff = Date.now() - TRASH_DAYS * 86400000;
    let dirs = [];
    try {
      dirs = fs.readdirSync(this.root, { withFileTypes: true }).filter((d) => d.isDirectory() && !d.name.startsWith('.'));
    } catch {
      return out;
    }
    for (const d of dirs) {
      const meta = readJSON(path.join(this.root, d.name, 'meta.json'));
      if (!meta?.id) continue;
      if (meta.deletedAt && Date.parse(meta.deletedAt) < cutoff) {
        fs.rmSync(path.join(this.root, d.name), { recursive: true, force: true });
        continue;
      }
      out.push(this.withExtras(meta));
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
    if (!m) throw new Error('找不到该妙记');
    change(m);
    return this.save(m);
  }

  create({ mediaPath, title, createdAt, duration, isAudioOnly }) {
    const id = randomUUID();
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
    });
  }

  loadTranscript(id) {
    return readJSON(path.join(this.folder(id), 'transcript.json'));
  }

  saveTranscript(id, t) {
    writeJSON(path.join(this.folder(id), 'transcript.json'), t);
    this.searchCache.delete(id);
  }

  loadSummary(id) {
    return readJSON(path.join(this.folder(id), 'summary.json'));
  }

  saveSummary(id, s) {
    const file = path.join(this.folder(id), 'summary.json');
    if (s) writeJSON(file, s);
    else fs.rmSync(file, { force: true });
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
