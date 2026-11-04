// State and behaviour of one open minute (§2–§6).
import { signal, computed, batch } from '@preact/signals';
import { call, lm, general, showToast, upsertMinute, alertError, importSummaryText, registerDetailModel, llm } from './state.js';
import { buildParagraphs, separator, CueTimeline, speakerPercentages, speakerIntervals, transcriptHash } from '../core/paragraphs.js';
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
    this.summary = signal(null);
    this.summaryState = signal({ status: 'idle' });
    this.rightTab = signal('transcript');
    this.leftTab = signal('speakers');
    this.mediaState = signal('loading'); // loading | ready | missing | error
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
      if (!this.transcript.value) out.push({ text: L('无字幕'), warn: true });
      if (this.summary.value) out.push({ text: L('已生成纪要') });
      return out;
    });
  }

  // ---------- lifecycle ----------

  /** Loads transcript and summary before the page is shown. */
  async prepare() {
    const id = this.minute.value.id;
    const [transcript, summary] = await Promise.all([call('lib:transcript', id), call('lib:summary', id)]);
    batch(() => {
      this.transcript.value = transcript;
      this.summary.value = summary;
    });
    this.rebuildDerived();
  }

  /** Media, playback and the transcript text; called once the page transition has finished. */
  async start() {
    if (this.closed) return;
    this.transcriptRevealed.value = true;
    await this.resolveMedia();
    this.saveTimer = setInterval(() => this.persistPosition(), 10000);
  }

  async resolveMedia() {
    const m = this.minute.value;
    const exists = await call('fs:exists', m.mediaPath);
    if (!exists) {
      this.mediaState.value = 'missing';
      return;
    }
    this.mediaURL.value = await call('fs:fileURL', m.mediaPath);
    this.mediaState.value = 'loading';
  }

  async close() {
    this.closed = true;
    await this.persistPosition();
    clearInterval(this.saveTimer);
    clearTimeout(this.searchTimer);
    if (this.jobId) call('llm:cancel', this.jobId);
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
    const saved = await call('lib:save', { ...m, lastPlaybackPosition: t });
    this.minute.value = saved;
  }

  async saveMinute(patch) {
    const saved = await call('lib:save', { ...this.minute.value, ...patch });
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

  async relocateMedia() {
    const path = await call('dialog:openMedia');
    if (!path) return;
    try {
      const info = await probeMedia(path);
      await this.saveMinute({ mediaPath: path, mediaFileName: baseName(path), isAudioOnly: !info.hasVideo, duration: info.duration, mediaSize: null });
      if (info.coverBase64) {
        await call('lib:saveCover', this.minute.value.id, info.coverBase64);
        upsertMinute(await call('lib:get', this.minute.value.id));
      }
      this.previewCache.clear();
      this.previewVideo = null;
      this.mediaState.value = 'loading';
      this.mediaURL.value = await call('fs:fileURL', path);
    } catch (e) {
      alertError(L('无法使用该文件'), e.message);
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

  async generate() {
    const tr = this.transcript.value;
    if (!tr) {
      this.summaryState.value = { status: 'failed', message: L('请先导入 SRT 字幕，再生成智能纪要') };
      return;
    }
    const input = buildSummaryInput({
      title: this.minute.value.title,
      duration: this.totalDuration,
      transcript: tr,
      paragraphs: this.paragraphs.value,
      insertComma: general.value.insertComma,
      language: llm.value.outputLanguage,
    });
    const jobId = `job-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    this.jobId = jobId;
    const hash = this.hash.value;
    batch(() => {
      this.summaryState.value = { status: 'generating', text: L('正在生成…') };
      this.rightTab.value = 'summary';
    });
    const off = lm.onProgress((p) => {
      if (p.jobId !== jobId || this.jobId !== jobId) return;
      const text = p.type === 'part' ? L('正在生成… 第 {0}/{1} 部分', p.i, p.n) : p.type === 'merging' ? L('正在合并各部分…') : L('正在生成…');
      this.summaryState.value = { status: 'generating', text };
    });
    try {
      const { draft, model } = await call('llm:generate', { jobId, input });
      if (this.jobId !== jobId) return;
      const summary = { ...draft, model, generatedAt: new Date().toISOString(), transcriptHash: hash, feedback: null, chaptersFeedback: null };
      await call('lib:saveSummary', this.minute.value.id, summary);
      batch(() => {
        this.summary.value = summary;
        this.summaryState.value = { status: 'idle' };
      });
      await this.saveMinute({ hasSummary: true });
    } catch (e) {
      if (this.jobId !== jobId) return;
      this.summaryState.value = e.code === 'cancelled' ? { status: 'idle' } : { status: 'failed', message: e.message };
    } finally {
      off();
      if (this.jobId === jobId) this.jobId = null;
    }
  }

  cancelGeneration() {
    if (this.jobId) call('llm:cancel', this.jobId);
    this.jobId = null;
    this.summaryState.value = { status: 'idle' };
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
