// State and behaviour of one open minute (§2–§6).
import { signal, computed, batch } from '@preact/signals';
import {
  call,
  general,
  showToast,
  upsertMinute,
  alertError,
  importSummaryText,
  registerDetailModel,
  llm,
  summaryJobs,
  favorites,
  startSummary,
  cancelSummary,
  clearSummaryFailure,
  confirmRequest,
  copyingMedia,
  setCopying,
} from './state.js';
import { buildParagraphs, separator, CueTimeline, speakerPercentages, speakerIntervals, transcriptHash, cuesHash } from '../core/paragraphs.js';
import { favoriteID, isConfigured } from '../core/llm.js';
import { makeSummaryFile, encodeSummaryFile, SUMMARY_FILE_EXT } from '../core/summaryFile.js';
import { createdDate } from '../core/time.js';
import { readSummaryFile, confirmAndImportSummary, APP_IDENTITY } from './summaryFiles.js';
import { usesHours } from '../core/time.js';
import { fold, occurrences } from '../core/text.js';
import { exportSRT, exportTXT, exportMarkdown, summaryMarkdown } from '../core/exporter.js';
import { buildSummaryInput } from '../core/summary.js';
import { baseName } from '../core/pairing.js';
import { probeMedia } from './importer.js';
import { L } from '../core/i18n.js';

const clamp01 = (x) => Math.min(1, Math.max(0, x));

export class DetailModel {
  constructor(minute) {
    this.minute = signal(minute);
    this.transcript = signal(null);
    this.paragraphs = signal([]);
    this.bodies = [];
    this.timeline = new CueTimeline([]);
    /** Every summary version, oldest first; `summary` is the one shown. */
    this.summaries = signal([]);
    this.summary = computed(() => {
      const list = this.summaries.value;
      const id = this.minute.value.activeSummaryID;
      return list.find((x) => x.id === id) || list[list.length - 1] || null;
    });
    /** Problem found before a request was sent (no subtitles, API not set up). */
    this.summaryNotice = signal(null);
    this.summaryState = computed(() => {
      const job = summaryJobs.value.get(this.minute.value.id);
      if (job?.phase === 'running') return { status: 'generating', text: job.text, model: job.model };
      if (job?.phase === 'failed') return { status: 'failed', message: job.text };
      if (this.summaryNotice.value) return { status: 'failed', message: this.summaryNotice.value };
      return { status: 'idle' };
    });
    /** Model picked in the summary tab: a favorite's id, or null for the default in Settings. */
    this.chosenModelID = signal(null);
    this.chosenFavorite = computed(() => {
      const id = this.chosenModelID.value;
      return (id && favorites.value.find((f) => favoriteID(f) === id)) || null;
    });
    this.rightTab = signal('transcript');
    this.leftTab = signal('speakers');
    this.mediaState = signal('loading'); // loading | ready | missing | unreachable | error
    /** "重新检测路径" in progress, and whether the last one found nothing. */
    this.rechecking = signal(false);
    this.recheckFailed = signal(false);
    this.mediaError = signal('');
    this.mediaURL = signal(null);
    /** True once the first video frame can be shown; the picture fades in then. */
    this.videoReady = signal(false);
    /** The transcript DOM is built only after the page transition (it is the heavy part). */
    this.transcriptRevealed = signal(false);
    this.currentTime = signal(minute.lastPlaybackPosition || 0);
    this.duration = signal(minute.duration || 0);
    this.playing = signal(false);
    this.rate = signal(general.value.playbackRate || 1);
    this.volume = signal(general.value.volume ?? 1);
    this.muted = signal(false);
    this.activeCue = signal(-1);
    this.currentCue = -1;
    this.following = signal(true);
    this.cueAbove = signal(false);
    this.searchQuery = signal('');
    this.hits = signal([]);
    this.hitIndex = signal(0);
    this.searchFocusToken = signal(0);
    this.searchFieldFocused = false;
    this.fullscreen = signal(false);
    this.percentages = signal({});
    this.intervals = signal({});
    this.hash = signal('');
    this.docVersion = signal(0);
    this.preview = signal(null); // { bucket, url }

    this.video = null;
    this.view = null;
    this.raf = 0;
    this.seeking = false;
    this.jobId = null;
    this.searchTimer = null;
    this.saveTimer = null;
    this.previewVideo = null;
    this.previewCache = new Map();
    this.previewTimer = null;
    this.closed = false;

    this.stale = computed(() => !!this.summary.value && !!this.transcript.value && this.summary.value.transcriptHash !== this.hash.value);
    this.tags = computed(() => {
      const out = [];
      if (this.mediaState.value === 'missing') out.push({ text: L('媒体缺失'), warn: true });
      if (this.mediaState.value === 'unreachable') out.push({ text: L('无法访问源文件'), warn: true });
      if (!this.transcript.value) out.push({ text: L('无字幕'), warn: true });
      const n = this.summaries.value.length;
      if (n > 1) out.push({ text: L('{0} 份纪要', n) });
      else if (n === 1) out.push({ text: L('已生成纪要') });
      return out;
    });
  }

  // ---------- lifecycle ----------

  /** Loads transcript and summary before the page is shown. */
  async prepare() {
    const id = this.minute.value.id;
    const [transcript, summaries] = await Promise.all([call('lib:transcript', id), call('lib:summaries', id)]);
    batch(() => {
      this.transcript.value = transcript;
      this.summaries.value = summaries;
    });
    if (!!this.minute.value.hasSummary !== summaries.length > 0) await this.saveMinute({ hasSummary: summaries.length > 0 });
    this.rebuildDerived();
  }

  /** Media, playback and the transcript text; called once the page transition has finished. */
  async start() {
    if (this.closed) return;
    this.transcriptRevealed.value = true;
    await this.resolveMedia();
    this.saveTimer = setInterval(() => this.persistPosition(), 10000);
  }

  /** Asks the main process where the media is; it never blocks on an unreachable share. */
  async resolveMedia({ force = false, showLoading = true } = {}) {
    if (showLoading) this.mediaState.value = 'loading';
    const r = await call('media:probe', this.minute.value.id, { force });
    if (this.closed) return;
    if (r.state !== 'found') {
      this.mediaState.value = r.state === 'unreachable' ? 'unreachable' : 'missing';
      return;
    }
    batch(() => {
      this.recheckFailed.value = false;
      this.mediaState.value = 'loading';
    });
    this.mediaURL.value = await call('fs:fileURL', r.path);
  }

  /**
   * "重新检测路径": looks again at the last known location, so a file moved back where it
   * was comes back. `silent` is the automatic check when the window gets focus again.
   */
  async recheckMedia(silent = false) {
    const st = this.mediaState.value;
    if (this.rechecking.value || (st !== 'missing' && st !== 'unreachable')) return;
    this.rechecking.value = true;
    if (!silent) this.recheckFailed.value = false;
    try {
      await this.resolveMedia({ force: !silent, showLoading: false });
    } finally {
      this.rechecking.value = false;
    }
    const now = this.mediaState.value;
    if (now === 'missing' || now === 'unreachable') {
      if (!silent) this.recheckFailed.value = true;
    } else if (!silent) {
      showToast(L('已重新找到源文件'));
    }
  }

  /** The media was copied into the app: play from the copy at the same position. */
  async mediaMovedIntoApp(m) {
    const position = this.video?.currentTime ?? this.minute.value.lastPlaybackPosition ?? 0;
    const wasPlaying = this.video && !this.video.paused;
    this.minute.value = { ...this.minute.value, storage: m.storage, mediaPath: m.mediaPath, mediaFileName: m.mediaFileName, mediaSize: m.mediaSize, lastPlaybackPosition: position };
    this.previewCache.clear();
    this.previewVideo = null;
    this.resumePlaying = wasPlaying;
    await this.resolveMedia();
  }

  async close() {
    this.closed = true;
    await this.persistPosition();
    clearInterval(this.saveTimer);
    clearTimeout(this.searchTimer);
    // Summary generation is not cancelled: it belongs to the app and finishes in the background.
    cancelAnimationFrame(this.raf);
    this.video?.pause();
    this.view?.clearHighlights();
    if (this.previewVideo) {
      this.previewVideo.removeAttribute('src');
      this.previewVideo.load();
      this.previewVideo = null;
    }
  }

  async persistPosition() {
    if (!this.video || this.mediaState.value !== 'ready') return;
    const t = this.video.currentTime;
    const m = this.minute.value;
    if (Math.abs(t - (m.lastPlaybackPosition || 0)) < 0.5) return;
    const saved = await call('lib:patch', m.id, { lastPlaybackPosition: t });
    this.minute.value = saved;
  }

  /** Writes only the changed fields, so it never undoes changes made elsewhere meanwhile. */
  async saveMinute(patch) {
    const saved = await call('lib:patch', this.minute.value.id, patch);
    this.minute.value = saved;
    upsertMinute(saved);
    return saved;
  }

  // ---------- media ----------

  get totalDuration() {
    if (this.duration.value > 0) return this.duration.value;
    if (this.minute.value.duration > 0) return this.minute.value.duration;
    const cues = this.transcript.value?.cues || [];
    return cues.length ? Math.max(...cues.map((c) => c.end)) : 0;
  }

  get hours() {
    return usesHours(this.totalDuration);
  }

  attachVideo(el) {
    if (this.video === el) return;
    this.video = el;
    if (!el) return;
    el.playbackRate = this.rate.value;
    el.volume = this.volume.value;
    el.muted = this.muted.value;
    el.addEventListener('loadedmetadata', () => {
      if (Number.isFinite(el.duration) && el.duration > 0) {
        this.duration.value = el.duration;
        if (Math.abs((this.minute.value.duration || 0) - el.duration) > 1) this.saveMinute({ duration: el.duration });
      }
      const resume = this.minute.value.lastPlaybackPosition || 0;
      if (resume > 1 && resume < el.duration - 2) el.currentTime = resume;
      el.playbackRate = this.rate.value;
      this.mediaState.value = 'ready';
      this.refreshHighlight(resume);
      if (this.resumePlaying) {
        this.resumePlaying = false;
        this.play();
      }
    });
    el.addEventListener('loadeddata', () => (this.videoReady.value = true));
    el.addEventListener('emptied', () => (this.videoReady.value = false));
    el.addEventListener('play', () => {
      this.playing.value = true;
      this.loop();
    });
    el.addEventListener('pause', () => {
      this.playing.value = false;
      this.tick();
      this.persistPosition();
    });
    el.addEventListener('ended', () => (this.playing.value = false));
    el.addEventListener('seeking', () => (this.seeking = true));
    el.addEventListener('seeked', () => {
      this.seeking = false;
      this.currentTime.value = el.currentTime;
      this.refreshHighlight(el.currentTime);
    });
    el.addEventListener('timeupdate', () => {
      if (el.paused) this.currentTime.value = el.currentTime;
    });
    el.addEventListener('error', () => {
      this.mediaError.value = L('无法播放此文件（格式或编码不受支持）');
      this.mediaState.value = 'error';
    });
  }

  loop() {
    cancelAnimationFrame(this.raf);
    const step = () => {
      this.tick();
      if (this.video && !this.video.paused && !this.closed) this.raf = requestAnimationFrame(step);
    };
    this.raf = requestAnimationFrame(step);
  }

  tick() {
    const v = this.video;
    if (!v) return;
    const t = v.currentTime;
    if (Math.abs(t - this.currentTime.value) > 0.03) this.currentTime.value = t;
    if (this.seeking) return;
    const g = general.value;
    if (g.skipBlankEnabled && !v.paused && !this.timeline.isEmpty) {
      const target = this.timeline.skipTarget(t, Math.max(0.5, g.skipBlankThreshold));
      if (target != null) {
        this.seek(target);
        return;
      }
    }
    this.refreshHighlight(t);
  }

  play() {
    if (!this.video || this.mediaState.value !== 'ready') return;
    if (this.video.ended) this.video.currentTime = 0;
    this.video.play().catch(() => {});
  }

  pause() {
    this.video?.pause();
  }

  togglePlay() {
    if (!this.video) return;
    if (this.video.paused) this.play();
    else this.pause();
  }

  seek(t) {
    const d = this.totalDuration;
    const target = Math.max(0, d > 0 ? Math.min(t, d) : t);
    this.currentTime.value = target;
    if (this.video && this.mediaState.value === 'ready') {
      this.seeking = true;
      this.video.currentTime = target;
    }
  }

  skip(delta) {
    this.seek((this.video?.currentTime ?? this.currentTime.value) + delta);
  }

  setRate(r) {
    this.rate.value = r;
    if (this.video) this.video.playbackRate = r;
  }

  setVolume(v) {
    this.volume.value = v;
    if (this.video) this.video.volume = v;
    if (v > 0 && this.muted.value) this.toggleMute();
  }

  toggleMute() {
    this.muted.value = !this.muted.value;
    if (this.video) this.video.muted = this.muted.value;
  }

  /**
   * "重新定位" / "更换媒体文件". A linked minute links to the new file; a minute whose media is
   * in the app gets a copy of the new file instead.
   */
  async relocateMedia() {
    const path = await call('dialog:openMedia');
    if (!path) return;
    const id = this.minute.value.id;
    try {
      const info = await probeMedia(path);
      if (this.minute.value.storage === 'imported') {
        if (copyingMedia.value.has(id)) return;
        this.mediaURL.value = null;
        this.mediaState.value = 'loading';
        setCopying(id, 0);
        let m;
        try {
          m = await call('media:replaceImported', id, path);
        } finally {
          setCopying(id, null);
        }
        this.minute.value = m;
        await this.saveMinute({ isAudioOnly: !info.hasVideo, duration: info.duration });
      } else {
        const size = await call('media:stat', path);
        await this.saveMinute({ mediaPath: path, mediaFileName: baseName(path), isAudioOnly: !info.hasVideo, duration: info.duration, mediaSize: size.size ?? null });
      }
      if (info.coverBase64) {
        await call('lib:saveCover', id, info.coverBase64);
        upsertMinute(await call('lib:get', id));
      }
      this.previewCache.clear();
      this.previewVideo = null;
      await this.resolveMedia();
    } catch (e) {
      alertError(L('无法使用该文件'), e.message);
      if (this.minute.value.storage === 'imported') this.resolveMedia();
    }
  }

  revealMedia() {
    call('fs:reveal', this.minute.value.mediaPath).catch((e) => alertError(L('找不到媒体文件'), e.message));
  }

  /** Progress-bar hover thumbnail in 2-second buckets (§3.2). */
  requestPreview(t) {
    if (this.minute.value.isAudioOnly || !this.mediaURL.value) return;
    const bucket = Math.max(0, Math.floor(t / 2));
    if (this.preview.value?.bucket === bucket) return;
    const cached = this.previewCache.get(bucket);
    if (cached) {
      this.preview.value = { bucket, url: cached };
      return;
    }
    this.preview.value = { bucket, url: null };
    clearTimeout(this.previewTimer);
    this.previewTimer = setTimeout(() => this.renderPreview(bucket), 70);
  }

  renderPreview(bucket) {
    if (!this.previewVideo) {
      const v = document.createElement('video');
      v.muted = true;
      v.preload = 'auto';
      v.src = this.mediaURL.value;
      this.previewVideo = v;
    }
    const v = this.previewVideo;
    const draw = () => {
      try {
        const c = document.createElement('canvas');
        c.width = 320;
        c.height = 180;
        const ctx = c.getContext('2d');
        ctx.fillStyle = '#000';
        ctx.fillRect(0, 0, 320, 180);
        const s = Math.min(320 / v.videoWidth, 180 / v.videoHeight);
        ctx.drawImage(v, (320 - v.videoWidth * s) / 2, (180 - v.videoHeight * s) / 2, v.videoWidth * s, v.videoHeight * s);
        const url = c.toDataURL('image/jpeg', 0.75);
        this.previewCache.set(bucket, url);
        if (this.preview.value?.bucket === bucket) this.preview.value = { bucket, url };
      } catch {
        // drawing can fail while the element is still loading; the next hover retries
      }
    };
    const seekTo = () => {
      v.onseeked = draw;
      v.currentTime = bucket * 2 + 1;
    };
    if (v.readyState >= 1) seekTo();
    else v.onloadedmetadata = seekTo;
  }

  // ---------- transcript ----------

  rebuildDerived() {
    const tr = this.transcript.value;
    if (!tr) {
      batch(() => {
        this.paragraphs.value = [];
        this.percentages.value = {};
        this.intervals.value = {};
        this.hash.value = '';
      });
      this.timeline = new CueTimeline([]);
      this.bodies = [];
      this.docVersion.value++;
      return;
    }
    const paragraphs = buildParagraphs(tr.cues);
    this.timeline = new CueTimeline(tr.cues);
    const intervals = {};
    for (const s of tr.speakers) intervals[s.id] = speakerIntervals(tr.cues, s.id);
    batch(() => {
      this.paragraphs.value = paragraphs;
      this.percentages.value = speakerPercentages(tr.cues);
      this.intervals.value = intervals;
      this.hash.value = transcriptHash(tr);
    });
    this.rebuildBodies();
  }

  /** Paragraph bodies as segments (cue text + glue), shared by the view and search. */
  rebuildBodies() {
    const tr = this.transcript.value;
    if (!tr) return;
    const comma = general.value.insertComma;
    this.bodies = this.paragraphs.value.map((p) => {
      const segs = [];
      let text = '';
      let prevText = null;
      let prevID = null;
      for (const id of p.cueIDs) {
        const t = tr.cues[id].text;
        if (!t) {
          segs.push({ cue: id, start: text.length, text: '', glue: false });
          continue;
        }
        if (prevText != null) {
          const g = separator(prevText, t, comma);
          if (g) {
            segs.push({ cue: prevID, start: text.length, text: g, glue: true });
            text += g;
          }
        }
        segs.push({ cue: id, start: text.length, text: t, glue: false });
        text += t;
        prevText = t;
        prevID = id;
      }
      return { text, folded: fold(text), segs };
    });
    this.currentCue = -1;
    this.recomputeHits(false);
    this.docVersion.value++;
  }

  /** Called by the transcript view after it has (re)built its DOM. */
  viewReady(view) {
    this.view = view;
    view.setHits(this.hits.value, this.hits.value.length ? this.hitIndex.value : -1);
    this.currentCue = -1;
    this.refreshHighlight(this.video ? this.video.currentTime : this.currentTime.value);
  }

  refreshHighlight(t, forced) {
    const tr = this.transcript.value;
    if (!tr || !tr.cues.length) return;
    const active = forced ?? this.timeline.activeCue(t);
    if (this.activeCue.value !== active) this.activeCue.value = active;
    const cue = active >= 0 ? active : this.currentCue;
    let offset = null;
    if (cue >= 0 && cue === active && general.value.perCharHighlight) {
      const c = tr.cues[cue];
      const len = c.text.length;
      if (c.end > c.start && len) offset = Math.min(len - 1, Math.floor(clamp01((t - c.start) / (c.end - c.start)) * len));
    }
    if (cue !== this.currentCue) {
      this.currentCue = cue;
      if (this.following.value && cue >= 0) this.view?.scrollToCue(cue, true);
      this.view?.updateDirection();
    }
    this.view?.setCurrent(cue, offset);
  }

  /** Click on transcript text: seek to the cue (or the estimated character) and play (§5.4). */
  jumpToCue(id, offset) {
    const tr = this.transcript.value;
    if (!tr || id < 0 || id >= tr.cues.length) return;
    const c = tr.cues[id];
    let t = c.start;
    if (general.value.perCharHighlight && offset != null && c.text.length && c.end > c.start) {
      t = c.start + ((c.end - c.start) * offset) / c.text.length;
    }
    this.following.value = true;
    this.seek(t);
    this.refreshHighlight(t, id);
    this.play();
  }

  jumpToParagraph(i) {
    const p = this.paragraphs.value[i];
    if (!p) return;
    this.following.value = true;
    this.seek(p.start);
    this.refreshHighlight(p.start, p.cueIDs[0]);
    this.play();
  }

  /** Chapter titles, todo timestamps, track clicks. */
  jumpToTime(t, play = true) {
    this.following.value = true;
    this.seek(t);
    this.refreshHighlight(t);
    if (play) this.play();
  }

  userScrolled() {
    if (this.following.value) this.following.value = false;
    this.view?.updateDirection();
  }

  resumeFollowing() {
    this.following.value = true;
    if (this.currentCue >= 0) this.view?.scrollToCue(this.currentCue, true);
  }

  async renameSpeaker(id, name) {
    const tr = this.transcript.value;
    const n = (name || '').trim();
    const s = tr?.speakers.find((x) => x.id === id);
    if (!s || !n || s.name === n) return;
    const next = { ...tr, speakers: tr.speakers.map((x) => (x.id === id ? { ...x, name: n } : x)) };
    this.transcript.value = next;
    this.hash.value = transcriptHash(next);
    await call('lib:saveTranscript', this.minute.value.id, next);
    this.rebuildBodies();
  }

  async renameTitle(title) {
    const t = (title || '').trim();
    if (!t || t === this.minute.value.title) return;
    await this.saveMinute({ title: t });
  }

  async importSRT(path) {
    try {
      const { minute, transcript } = await call('lib:attachSrt', this.minute.value.id, path);
      this.minute.value = minute;
      upsertMinute(minute);
      this.transcript.value = transcript;
      this.rebuildDerived();
      this.rightTab.value = 'transcript';
      showToast(importSummaryText(transcript, this.totalDuration));
    } catch (e) {
      alertError(L('无法导入字幕'), e.message);
    }
  }

  async chooseSRT() {
    const path = await call('dialog:openSrt');
    if (path) await this.importSRT(path);
  }

  // ---------- search (§5.1) ----------

  scheduleSearch() {
    clearTimeout(this.searchTimer);
    this.searchTimer = setTimeout(() => this.runSearch(), 150);
  }

  recomputeHits(reset) {
    const q = this.searchQuery.value.trim();
    const tr = this.transcript.value;
    if (!q || !tr) {
      this.hits.value = [];
      this.hitIndex.value = 0;
      return;
    }
    const needle = fold(q);
    const hits = [];
    this.bodies.forEach((b, p) => {
      for (const start of occurrences(needle, b.folded)) {
        // Owner of the first matched character: the last non-empty segment starting at or before it.
        let seg = b.segs.find((s) => s.text.length > 0) || b.segs[0];
        for (const s of b.segs) {
          if (!s.text.length) continue;
          if (s.start <= start) seg = s;
          else break;
        }
        hits.push({ p, start, end: start + needle.length, cue: seg.cue, time: tr.cues[seg.cue].start });
      }
    });
    batch(() => {
      this.hits.value = hits;
      if (reset || this.hitIndex.value >= hits.length) this.hitIndex.value = 0;
    });
  }

  runSearch() {
    this.recomputeHits(true);
    const hits = this.hits.value;
    this.view?.setHits(hits, hits.length ? 0 : -1);
    if (hits.length) {
      this.following.value = false;
      this.view?.scrollToHit(0);
      this.view?.updateDirection();
    }
  }

  searchKeyword(k) {
    this.searchQuery.value = k;
    clearTimeout(this.searchTimer);
    this.runSearch();
  }

  moveHit(delta) {
    const hits = this.hits.value;
    if (!hits.length) return;
    const i = (this.hitIndex.value + delta + hits.length) % hits.length;
    this.hitIndex.value = i;
    const h = hits[i];
    this.view?.setHits(hits, i);
    this.following.value = true;
    this.seek(h.time);
    this.refreshHighlight(h.time, h.cue);
    this.view?.scrollToHit(i);
  }

  clearSearch() {
    clearTimeout(this.searchTimer);
    batch(() => {
      this.searchQuery.value = '';
      this.hits.value = [];
      this.hitIndex.value = 0;
    });
    this.view?.setHits([], -1);
  }

  focusSearch() {
    this.rightTab.value = 'transcript';
    this.searchFocusToken.value++;
  }

  // ---------- summary (§6) ----------

  chapterAt(t) {
    let found = null;
    for (const c of this.summary.value?.chapters || []) {
      if (c.time <= t + 0.001) found = c;
      else break;
    }
    return found;
  }

  /** Generates a new version with the model picked in the summary tab, in the background. */
  async generate() {
    const id = this.minute.value.id;
    this.summaryNotice.value = null;
    clearSummaryFailure(id);
    const tr = this.transcript.value;
    if (!tr) {
      this.summaryNotice.value = L('请先导入 SRT 字幕，再生成智能纪要');
      return;
    }
    const fav = this.chosenFavorite.value;
    const model = fav ? fav.model : llm.value.model;
    if (!fav && !isConfigured(llm.value)) {
      this.summaryNotice.value = L('请先在 API 设置中填写 Base URL 与模型');
      return;
    }
    if (!model) return;
    const input = buildSummaryInput({
      title: this.minute.value.title,
      duration: this.totalDuration,
      transcript: tr,
      paragraphs: this.paragraphs.value,
      insertComma: general.value.insertComma,
      language: llm.value.outputLanguage,
    });
    this.rightTab.value = 'summary';
    await startSummary({ minuteID: id, input, favorite: fav, transcriptHash: this.hash.value, cuesHash: cuesHash(tr) });
  }

  cancelGeneration() {
    cancelSummary(this.minute.value.id);
  }

  /** A version was added (generated or imported) while this page is open. */
  summariesChanged(list, minute) {
    batch(() => {
      this.summaries.value = list;
      this.minute.value = { ...this.minute.value, hasSummary: minute.hasSummary, activeSummaryID: minute.activeSummaryID };
    });
  }

  selectSummary(sid) {
    if (this.minute.value.activeSummaryID === sid) return;
    this.saveMinute({ activeSummaryID: sid });
  }

  requestDeleteSummary(sid) {
    const s = this.summaries.value.find((x) => x.id === sid);
    if (!s) return;
    confirmRequest.value = {
      title: L('删除这份纪要？'),
      message: L('{0} · {1} 生成的纪要会被删除，其他版本不受影响。', s.model, createdDate(s.generatedAt)),
      confirmTitle: L('删除'),
      onConfirm: async () => {
        const list = this.summaries.value.filter((x) => x.id !== sid);
        await call('lib:saveSummaries', this.minute.value.id, list);
        this.summaries.value = list;
        const active = this.minute.value.activeSummaryID === sid ? list[list.length - 1]?.id || null : this.minute.value.activeSummaryID;
        await this.saveMinute({ hasSummary: list.length > 0, activeSummaryID: active });
        showToast(L('已删除纪要'));
      },
    };
  }

  // ---------- summary files ----------

  async exportSummaryFile() {
    const s = this.summary.value;
    if (!s) return;
    const file = makeSummaryFile({ summary: s, minute: this.minute.value, transcript: this.transcript.value, app: APP_IDENTITY });
    const ok = await call('dialog:saveText', { text: encodeSummaryFile(file), name: `${this.minute.value.title} · ${s.model}`, ext: SUMMARY_FILE_EXT });
    if (ok) showToast(L('已导出'));
  }

  async chooseAndImportSummaryFile() {
    const path = await call('dialog:openSummaryFile');
    if (path) await this.importSummaryFile(path);
  }

  /** Checks the file against this minute and asks before importing when they differ. */
  async importSummaryFile(path) {
    try {
      const file = await readSummaryFile(path);
      this.rightTab.value = 'summary';
      confirmAndImportSummary(file, this.minute.value.id);
    } catch (e) {
      alertError(L('无法导入纪要'), L('{0}：{1}', baseName(path), e.message));
    }
  }

  async copySummaryMarkdown() {
    const s = this.summary.value;
    if (!s) return;
    await call('clipboard:write', summaryMarkdown(s, this.hours));
    showToast(L('已复制为 Markdown'));
  }

  // ---------- export (§2) ----------

  async export(kind) {
    const m = this.minute.value;
    const tr = this.transcript.value;
    const comma = general.value.insertComma;
    let text;
    let ext;
    if (kind === 'srt') {
      if (!tr) return;
      text = exportSRT(tr);
      ext = 'srt';
    } else if (kind === 'txt') {
      if (!tr) return;
      text = exportTXT(tr, this.paragraphs.value, comma, this.hours);
      ext = 'txt';
    } else {
      text = exportMarkdown({ title: m.title, createdAt: m.createdAt, duration: this.totalDuration, summary: this.summary.value, transcript: tr, paragraphs: this.paragraphs.value, insertComma: comma });
      ext = 'md';
    }
    const ok = await call('dialog:saveText', { text, name: m.title, ext });
    if (ok) showToast(L('已导出'));
  }
}

registerDetailModel(DetailModel);
