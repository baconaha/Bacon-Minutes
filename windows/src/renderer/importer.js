// §9.1 import pipeline: expand folders, pair media with SRTs, probe media in a hidden
// <video>, create the minute and attach its SRT.
import { call, general, importing, importDialog, showToast, upsertMinute, section, alertError, importSummaryText, detail, currentFolderID } from './state.js';
import { L } from '../core/i18n.js';
import { compactDuration } from '../core/time.js';
import { pairFiles, normalizedTitle, stem, baseName, dateFromFileName } from '../core/pairing.js';

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

async function createMinute(media, subtitle, folderID) {
  const info = await probeMedia(media);
  const base = stem(media);
  const now = new Date();
  const created = dateFromFileName(base, now) || now;
  let minute = await call('lib:create', {
    mediaPath: media,
    title: normalizedTitle(base, general.value.filenameSuffixes),
    createdAt: created.toISOString(),
    duration: info.duration,
    isAudioOnly: !info.hasVideo,
    folderID,
  });
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

export async function runImport(pairs) {
  if (!pairs.length) return;
  // Imports land in the folder that was open when they started.
  const folderID = currentFolderID.value;
  importing.value = true;
  const created = [];
  const failures = [];
  try {
    for (const p of pairs) {
      try {
        created.push(await createMinute(p.media, p.subtitle, folderID));
      } catch (e) {
        failures.push(L('{0}：{1}', baseName(p.media), e.message));
      }
    }
  } finally {
    importing.value = false;
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

/** Files and/or folders from drag-and-drop or dialogs. */
export async function importPaths(paths) {
  const { media, subtitles, otherCount } = await call('fs:expand', paths);
  if (!media.length) {
    if (subtitles.length === 1) {
      if (detail.value) await detail.value.importSRT(subtitles[0]);
      else importDialog.value = { media: null, subtitle: subtitles[0] };
    } else if (subtitles.length > 1) {
      await call('dialog:alert', { title: L('请同时选择音视频文件'), message: L('字幕需要与对应的音视频一起导入。') });
    } else if (otherCount || paths.length) {
      await call('dialog:alert', { title: L('没有可导入的文件'), message: L('支持的媒体：mp4 / mov / m4v / mp3 / m4a / wav / aac；字幕：srt。') });
    }
    return [];
  }
  let pairs;
  const leftovers = [];
  if (media.length === 1 && subtitles.length <= 1) {
    pairs = [{ media: media[0], subtitle: subtitles[0] || null }];
  } else {
    const r = pairFiles(media, subtitles, general.value.filenameSuffixes);
    pairs = r.pairs;
    for (const s of r.suggestions) {
      const use = await call('dialog:confirm', {
        title: L('使用「{0}」作为字幕？', baseName(s.subtitle)),
        message: L('没有找到与「{0}」同名的 SRT，同一文件夹中只有这一个字幕文件。', baseName(s.media)),
        ok: L('使用'),
        cancel: L('不使用'),
      });
      if (use) pairs.push(s);
      else {
        pairs.push({ media: s.media, subtitle: null });
        leftovers.push(s.subtitle);
      }
    }
    leftovers.push(...r.unmatched);
  }
  const created = await runImport(pairs);
  if (leftovers.length) {
    await call('dialog:alert', {
      title: L('有 {0} 个字幕未能配对', leftovers.length),
      message: L('{0}\n\n可以打开对应的妙记，在「··· → 重新导入 SRT」或文字记录空状态中手动指定。', leftovers.map(baseName).join('\n')),
    });
  }
  return created;
}

export async function importFolder() {
  const folder = await call('dialog:openFolder');
  if (folder) await importPaths([folder]);
}

export function pathsFromDrop(e) {
  const files = Array.from(e.dataTransfer?.files || []);
  return files.map((f) => window.lm.pathForFile(f)).filter(Boolean);
}
