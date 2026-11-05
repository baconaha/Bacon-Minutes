// §9.1 import pipeline: expand folders, pair media with SRTs, show them for review, then copy
// each file into the app (default) or link to it, probe it in a hidden <video>, create the
// minute and attach its SRT.
import { signal } from '@preact/signals';
import { call, general, importing, importDialog, importReview, importProgress, showToast, upsertMinute, section, alertError, importSummaryText, detail, currentFolderID, uuid } from './state.js';
import { importSummaryFilePaths } from './summaryFiles.js';
import { L } from '../core/i18n.js';
import { compactDuration } from '../core/time.js';
import { pairFiles, normalizedTitle, stem, baseName, dateFromFileName, pairingKey, kindOf } from '../core/pairing.js';

/** Loads metadata (and a cover frame at 10% for video) without touching the DOM. */
export async function probeMedia(path, { cover = true } = {}) {
  const url = await call('fs:fileURL', path);
  const video = document.createElement('video');
  video.preload = 'auto';
  video.muted = true;
  video.src = url;
  try {
    await new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(L('读取媒体超时'))), 20000);
      video.onloadedmetadata = () => {
        clearTimeout(t);
        resolve();
      };
      video.onerror = () => {
        clearTimeout(t);
        reject(new Error(L('无法读取该媒体文件（格式或编码不受支持）')));
      };
    });
    const duration = Number.isFinite(video.duration) ? video.duration : 0;
    const hasVideo = video.videoWidth > 0;
    let coverBase64 = null;
    if (hasVideo && cover) {
      try {
        await new Promise((resolve, reject) => {
          const t = setTimeout(() => reject(new Error('seek timeout')), 10000);
          video.onseeked = () => {
            clearTimeout(t);
            resolve();
          };
          video.currentTime = Math.max(0, duration * 0.1);
        });
        const canvas = document.createElement('canvas');
        canvas.width = 480;
        canvas.height = 270;
        const ctx = canvas.getContext('2d');
        ctx.fillStyle = '#000';
        ctx.fillRect(0, 0, 480, 270);
        const scale = Math.min(480 / video.videoWidth, 270 / video.videoHeight);
        const w = video.videoWidth * scale;
        const h = video.videoHeight * scale;
        ctx.drawImage(video, (480 - w) / 2, (270 - h) / 2, w, h);
        coverBase64 = canvas.toDataURL('image/jpeg', 0.8).split(',')[1];
      } catch {
        coverBase64 = null;
      }
    }
    return { duration, hasVideo, coverBase64 };
  } finally {
    video.removeAttribute('src');
    video.load();
  }
}

async function createMinute({ media, subtitle, cover, info: known }, storage, folderID) {
  // Duration and cover were read for the review dialog; read them again only if missing.
  const info = known?.duration > 0 ? { ...known, coverBase64: cover ?? known.coverBase64 } : await probeMedia(media);
  const base = stem(media);
  const now = new Date();
  const created = dateFromFileName(base, now) || now;
  let minute = await call(
    'lib:create',
    {
      mediaPath: media,
      title: normalizedTitle(base, general.value.filenameSuffixes),
      createdAt: created.toISOString(),
      duration: info.duration,
      isAudioOnly: !info.hasVideo,
      folderID,
      storage,
    },
    'import',
  );
  if (info.coverBase64) {
    await call('lib:saveCover', minute.id, info.coverBase64);
    minute = await call('lib:get', minute.id);
  }
  let transcript = null;
  if (subtitle) {
    try {
      const r = await call('lib:attachSrt', minute.id, subtitle);
      minute = r.minute;
      transcript = r.transcript;
    } catch (e) {
      await alertError(L('字幕「{0}」解析失败', baseName(subtitle)), e.message);
    }
  }
  upsertMinute(minute);
  return { minute, transcript };
}

let chain = Promise.resolve();

/** Imports run one batch after another, so a second drop waits for the first. */
export function runImport(items, { storage = 'imported', folderID = currentFolderID.value } = {}) {
  const next = chain.then(() => importBatch(items, storage, folderID));
  chain = next.catch(() => {});
  return next;
}

async function importBatch(items, storage, folderID) {
  if (!items.length) return [];
  importing.value = true;
  const created = [];
  const failures = [];
  try {
    for (const [i, item] of items.entries()) {
      importProgress.value = { index: i + 1, total: items.length, fraction: storage === 'imported' ? 0 : null };
      try {
        created.push(await createMinute(item, storage, folderID));
      } catch (e) {
        failures.push(L('{0}：{1}', baseName(item.media), e.message));
      }
    }
  } finally {
    importing.value = false;
    importProgress.value = null;
  }
  if (section.value === 'trash') section.value = 'all';
  if (created.length === 1) {
    const { minute, transcript } = created[0];
    showToast(transcript ? importSummaryText(transcript, minute.duration) : L('已导入「{0}」，时长 {1}', minute.title, compactDuration(minute.duration)));
  } else if (created.length > 1) {
    showToast(L('已导入 {0} 个妙记', created.length));
  }
  if (failures.length) await alertError(L('部分文件导入失败'), failures.join('\n'));
  return created;
}

// ---------- review dialog ----------

/** What a drop or a chosen folder would import, shown before anything is copied. */
export class ImportReview {
  constructor({ rows, subtitles, skipped, sourceName, folderID }) {
    this.id = uuid();
    this.rows = signal(rows.map((r) => ({ id: uuid(), included: true, guessed: false, inspected: false, ...r })));
    this.subtitles = subtitles;
    this.skipped = skipped;
    this.sourceName = sourceName;
    this.folderID = folderID;
    /** Off by default: media is copied into the app unless the user asks for links. */
    this.linkOnly = signal(false);
    this.cancelled = false;
  }

  update(id, patch) {
    this.rows.value = this.rows.value.map((r) => (r.id === id ? { ...r, ...patch } : r));
  }

  included() {
    return this.rows.value.filter((r) => r.included);
  }

  /** Reads duration, size and a cover frame for each row, one after another. */
  async loadDetails() {
    for (const row of this.rows.peek()) {
      if (this.cancelled) return;
      const [info, st] = await Promise.all([probeMedia(row.media).catch(() => null), call('media:stat', row.media).catch(() => null)]);
      if (this.cancelled) return;
      this.update(row.id, {
        inspected: true,
        info,
        duration: info?.duration ?? null,
        hasVideo: info ? info.hasVideo : row.hasVideo,
        size: st?.size ?? null,
        cover: info?.coverBase64 ?? null,
      });
    }
  }
}

/** "导入" in the review dialog. */
export function confirmImportReview(review) {
  const items = review.included().map((r) => ({ media: r.media, subtitle: r.subtitle, cover: r.cover, info: r.info }));
  return runImport(items, { storage: review.linkOnly.peek() ? 'linked' : 'imported', folderID: review.folderID });
}

/** Files and/or folders from drag-and-drop or dialogs: paired, then shown for review. */
export async function importPaths(paths) {
  const { media, subtitles, unsupported = [], summaryFiles = [], otherCount, dirName } = await call('fs:expand', paths);
  if (summaryFiles.length) {
    await importSummaryFilePaths(summaryFiles);
    if (!media.length) return [];
  }
  if (!media.length) {
    if (subtitles.length === 1) {
      if (detail.value) await detail.value.importSRT(subtitles[0]);
      else importDialog.value = { media: null, subtitle: subtitles[0] };
    } else if (subtitles.length > 1) {
      await call('dialog:alert', { title: L('请同时选择音视频文件'), message: L('字幕需要与对应的音视频一起导入。') });
    } else if (unsupported.length) {
      await call('dialog:alert', {
        title: L('没有可导入的文件'),
        message: L('这些文件的格式不受支持：{0}\n\n支持的媒体：mp4 / mov / m4v / mp3 / m4a / wav / aac；字幕：srt。', unsupported.slice(0, 5).map(baseName).join('\n')),
      });
    } else if (otherCount || paths.length) {
      await call('dialog:alert', { title: L('没有可导入的文件'), message: L('支持的媒体：mp4 / mov / m4v / mp3 / m4a / wav / aac；字幕：srt。') });
    }
    return [];
  }
  const suffixes = general.value.filenameSuffixes;
  let rows;
  if (media.length === 1 && subtitles.length <= 1) {
    const sub = subtitles[0] || null;
    rows = [{ media: media[0], subtitle: sub, guessed: !!sub && pairingKey(sub, suffixes) !== pairingKey(media[0], suffixes), hasVideo: kindOf(media[0]) === 'video' }];
  } else {
    const r = pairFiles(media, subtitles, suffixes);
    rows = [
      ...r.pairs.map((p) => ({ media: p.media, subtitle: p.subtitle || null, hasVideo: kindOf(p.media) === 'video' })),
      ...r.suggestions.map((p) => ({ media: p.media, subtitle: p.subtitle, guessed: true, hasVideo: kindOf(p.media) === 'video' })),
    ];
    const collator = new Intl.Collator('zh-Hans-CN', { numeric: true });
    rows.sort((a, b) => collator.compare(a.media, b.media));
  }
  const review = new ImportReview({ rows, subtitles, skipped: unsupported, sourceName: dirName, folderID: currentFolderID.value });
  importReview.value = review;
  review.loadDetails();
  return [];
}

export async function importFolder() {
  const folder = await call('dialog:openFolder');
  if (folder) await importPaths([folder]);
}

export function pathsFromDrop(e) {
  const files = Array.from(e.dataTransfer?.files || []);
  return files.map((f) => window.lm.pathForFile(f)).filter(Boolean);
}
