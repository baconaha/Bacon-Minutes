import { useEffect, useRef, useState } from 'preact/hooks';
import { general, updateGeneral } from '../state.js';
import { timestamp } from '../../core/time.js';
import { L } from '../../core/i18n.js';
import { Icon, Logo, Menu } from './ui.jsx';

const RATES = [3, 2, 1.5, 1.25, 1, 0.75, 0.5];
const rateLabel = (r) => `${r}x`;

/** Chapter-segmented progress bar with hover preview and search markers (§3.2). */
function useWidth(ref) {
  const [w, setW] = useState(0);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setW(el.clientWidth));
    ro.observe(el);
    setW(el.clientWidth);
    return () => ro.disconnect();
  }, []);
  return w;
}

function ProgressBar({ model, setActive }) {
  const bar = useRef(null);
  const [hover, setHover] = useState(null); // x in px
  const [dragging, setDragging] = useState(false);
  const measured = useWidth(bar);
  const d = Math.max(model.totalDuration, 0.001);
  const t = model.currentTime.value;
  const progress = Math.min(1, Math.max(0, t / d));
  // A gap at every chapter start except the first: the stretch before it belongs to chapter 1.
  const chapters = (model.summary.value?.chapters || [])
    .map((c) => c.time)
    .sort((a, b) => a - b)
    .slice(1)
    .filter((x) => x > 0.5 && x < d - 0.5);
  const bounds = [0, ...chapters, d];
  const w = measured || 1;
  const gap = 4;

  const timeAt = (clientX) => {
    const r = bar.current.getBoundingClientRect();
    return (Math.min(Math.max(clientX - r.left, 0), r.width) / r.width) * d;
  };

  const onDown = (e) => {
    if (e.button !== 0) return;
    e.preventDefault();
    e.stopPropagation();
    setDragging(true);
    setActive(true);
    model.seek(timeAt(e.clientX));
    const move = (ev) => {
      const r = bar.current.getBoundingClientRect();
      setHover(Math.min(Math.max(ev.clientX - r.left, 0), r.width));
      model.seek(timeAt(ev.clientX));
    };
    const up = (ev) => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      setDragging(false);
      setActive(false);
      model.jumpToTime(timeAt(ev.clientX), model.playing.value);
    };
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
  };

  const hoverTime = hover != null ? (hover / w) * d : null;
  const hoverBucket = hoverTime != null ? Math.floor(hoverTime / 2) : null;
  useEffect(() => {
    if (hoverBucket != null && !model.minute.value.isAudioOnly) model.requestPreview(hoverBucket * 2);
  }, [hoverBucket]);
  const chapter = hoverTime != null ? model.chapterAt(hoverTime) : null;
  const preview = model.preview.value;
  const showShot = !model.minute.value.isAudioOnly;
  const cardW = showShot ? 172 : 120;
  const cardLeft = hover != null ? Math.min(Math.max(hover - cardW / 2, -20), w - cardW + 20) : 0;
  const hits = model.hits.value;
  const hitIndex = model.hitIndex.value;

  return (
    <div
      class={`progress ${hover != null || dragging ? 'active' : ''}`}
      ref={bar}
      onMouseDown={onDown}
      onMouseMove={(e) => {
        const r = bar.current.getBoundingClientRect();
        setHover(Math.min(Math.max(e.clientX - r.left, 0), r.width));
      }}
      onMouseLeave={() => !dragging && setHover(null)}
      onClick={(e) => e.stopPropagation()}
    >
      {bounds.slice(0, -1).map((b, i) => {
        let x0 = (b / d) * w;
        let x1 = (bounds[i + 1] / d) * w;
        if (i > 0) x0 += gap / 2;
        if (i < bounds.length - 2) x1 -= gap / 2;
        if (x1 <= x0) return null;
        const played = Math.min(Math.max(progress * w - x0, 0), x1 - x0);
        return (
          <div class="seg" key={i} style={{ left: x0, width: x1 - x0 }}>
            <div class="played" style={{ width: played }} />
          </div>
        );
      })}
      <div class="knob" style={{ left: progress * w }} />
      {hits.map((h, i) => (
        <div key={i} class={`marker ${i === hitIndex ? 'current' : ''}`} style={{ left: (h.time / d) * w }} />
      ))}
      {hover != null && (
        <div class="preview-card" style={{ left: cardLeft }}>
          {showShot ? (
            <div class="shot">
              {preview?.url && <img src={preview.url} alt="" />}
              <span class="t num">{timestamp(hoverTime, model.hours)}</span>
            </div>
          ) : (
            <div class="num" style={{ fontSize: 12, fontWeight: 600 }}>
              {timestamp(hoverTime, model.hours)}
            </div>
          )}
          {chapter && <div class="chapter">{chapter.title}</div>}
        </div>
      )}
    </div>
  );
}

function VolumeControl({ model }) {
  const [open, setOpen] = useState(false);
  const timer = useRef(null);
  const enter = () => {
    clearTimeout(timer.current);
    setOpen(true);
  };
  const leave = () => {
    timer.current = setTimeout(() => setOpen(false), 300);
  };
  const muted = model.muted.value || model.volume.value === 0;
  return (
    <span style={{ position: 'relative', display: 'inline-flex' }} onMouseEnter={enter} onMouseLeave={leave}>
      {/* Highlighted like the other buttons, and kept lit while the slider is open. */}
      <button class={`pbtn ${open ? 'lit' : ''}`} onClick={() => model.toggleMute()} title={muted ? L('取消静音') : L('静音')}>
        <Icon name={muted ? 'mute' : 'volume'} />
      </button>
      {open && (
        <div class="popup volume-pop" style={{ left: 0 }}>
          <input
            type="range"
            min="0"
            max="1"
            step="0.01"
            value={model.muted.value ? 0 : model.volume.value}
            onInput={(e) => {
              const v = parseFloat(e.currentTarget.value);
              model.setVolume(v);
              updateGeneral({ volume: v });
            }}
          />
        </div>
      )}
    </span>
  );
}

function Controls({ model, hidden, setMenuOpen, setActive, fullscreen, toggleFullscreen }) {
  const [rateOpen, setRateOpen] = useState(false);
  const [moreOpen, setMoreOpen] = useState(false);
  useEffect(() => setMenuOpen(rateOpen || moreOpen), [rateOpen, moreOpen]);
  const g = general.value;
  const hours = model.hours;
  return (
    <div class={`controls ${hidden ? 'hidden' : ''}`} onClick={(e) => e.stopPropagation()}>
      <ProgressBar model={model} setActive={setActive} />
      <div class="controls-row">
        <button class="pbtn" onClick={() => model.togglePlay()} title={model.playing.value ? L('暂停') : L('播放')}>
          <Icon name={model.playing.value ? 'pause' : 'play'} />
        </button>
        <button class="pbtn" onClick={() => model.skip(-15)} title={L('后退 15 秒')}>
          <Icon name="back15" size={20} />
        </button>
        <button class="pbtn" onClick={() => model.skip(15)} title={L('前进 15 秒')}>
          <Icon name="fwd15" size={20} />
        </button>
        <VolumeControl model={model} />
        <span class="time-label num">
          {timestamp(model.currentTime.value, hours)} / {timestamp(model.totalDuration, hours)}
        </span>
        <div style={{ flex: 1 }} />
        <Menu
          up
          dark
          align="center"
          minWidth={96}
          title={L('播放倍率')}
          onOpenChange={setRateOpen}
          items={RATES.map((r) => ({
            label: rateLabel(r),
            selected: r === model.rate.value,
            onClick: () => {
              model.setRate(r);
              updateGeneral({ playbackRate: r });
            },
          }))}
          trigger={({ open, toggle }) => (
            <button class={`pbtn ${open ? 'lit' : ''}`} style={{ minWidth: 44, fontWeight: 600 }} onClick={toggle}>
              {rateLabel(model.rate.value)}
            </button>
          )}
        />
        <button class="pbtn" onClick={() => updateGeneral({ ccEnabled: !g.ccEnabled })} title={g.ccEnabled ? L('关闭字幕') : L('显示字幕')}>
          <span class={`cc-badge ${g.ccEnabled ? 'on' : ''}`}>CC</span>
        </button>
        <Menu
          up
          dark
          align="right"
          minWidth={180}
          title={L('更多')}
          onOpenChange={setMoreOpen}
          items={[{ toggle: true, icon: 'skip', label: L('跳过空白片段'), on: g.skipBlankEnabled, onChange: (v) => updateGeneral({ skipBlankEnabled: v }) }]}
          trigger={({ open, toggle }) => (
            <button class={`pbtn ${open ? 'lit' : ''}`} onClick={toggle}>
              <Icon name="more" />
            </button>
          )}
        />
        <button class="pbtn" onClick={toggleFullscreen} title={fullscreen ? L('退出全屏') : L('全屏')}>
          <Icon name={fullscreen ? 'exitFullscreen' : 'fullscreen'} />
        </button>
      </div>
    </div>
  );
}

export function Player({ model, height }) {
  const root = useRef(null);
  const video = useRef(null);
  const [visible, setVisible] = useState(true);
  const [menuOpen, setMenuOpen] = useState(false);
  const [active, setActive] = useState(false);
  const [flash, setFlash] = useState(null);
  const hideTimer = useRef(null);
  const state = model.mediaState.value;
  const url = model.mediaURL.value;
  const fullscreen = model.fullscreen.value;

  useEffect(() => {
    model.attachVideo(video.current);
  }, [video.current]);

  useEffect(() => {
    const onFs = () => (model.fullscreen.value = document.fullscreenElement === root.current);
    document.addEventListener('fullscreenchange', onFs);
    return () => document.removeEventListener('fullscreenchange', onFs);
  }, []);

  const scheduleHide = (ms) => {
    clearTimeout(hideTimer.current);
    hideTimer.current = setTimeout(() => setVisible(false), ms);
  };
  const playing = model.playing.value;
  const showControls = visible || !playing || menuOpen || active;
  const ready = state === 'ready';

  const toggleFullscreen = () => {
    if (document.fullscreenElement) document.exitFullscreen();
    else root.current?.requestFullscreen();
  };

  const onClick = () => {
    if (!ready) return;
    const wasPlaying = !model.video.paused;
    model.togglePlay();
    setFlash({ icon: wasPlaying ? 'pause' : 'play', key: Date.now() });
  };

  const cue = model.activeCue.value >= 0 ? model.transcript.value?.cues[model.activeCue.value] : null;
  const m = model.minute.value;

  return (
    <div
      class="player"
      ref={root}
      style={{ height }}
      onMouseMove={() => {
        setVisible(true);
        scheduleHide(3000);
      }}
      onMouseLeave={() => scheduleHide(2000)}
      onDblClick={toggleFullscreen}
    >
      {/* No spinner while loading: video stays black and fades in on its first frame;
          audio shows its cover at once. */}
      <video ref={video} src={url || undefined} preload="auto" class={!m.isAudioOnly && ready && model.videoReady.value ? 'shown' : ''} />
      {m.isAudioOnly && state !== 'missing' && state !== 'error' && (
        <div class="audio-cover">
          <Logo size={56} />
          <div>{m.mediaFileName}</div>
        </div>
      )}
      {(state === 'missing' || state === 'error') && (
        <div class="player-msg">
          <Icon name="warning" size={30} />
          <div class="title">{state === 'missing' ? L('找不到媒体文件') : model.mediaError.value}</div>
          <div class="sub" title={m.mediaPath}>
            {m.mediaFileName}
          </div>
          <button class="btn-primary compact" onClick={() => model.relocateMedia()}>
            {L('重新定位')}
          </button>
          <div class="sub">{L('文字记录与纪要仍可正常使用')}</div>
        </div>
      )}
      {ready && <div class="click-catcher" onClick={onClick} />}
      {flash && (
        <div class="flash" key={flash.key}>
          <Icon name={flash.icon} />
        </div>
      )}
      {g_cc(cue) && (
        <div class="cc" style={{ bottom: showControls ? 84 : 24 }}>
          <span>{cue.text}</span>
        </div>
      )}
      {ready && (
        <Controls
          model={model}
          hidden={!showControls}
          setMenuOpen={setMenuOpen}
          setActive={setActive}
          fullscreen={fullscreen}
          toggleFullscreen={toggleFullscreen}
        />
      )}
      {ready && !showControls && (
        <div class="thin-line">
          <div style={{ width: `${Math.min(100, (model.currentTime.value / Math.max(model.totalDuration, 0.001)) * 100)}%` }} />
        </div>
      )}
    </div>
  );
}

function g_cc(cue) {
  return general.value.ccEnabled && cue && cue.text;
}
