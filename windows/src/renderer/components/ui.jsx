import { useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks';
import { createPortal } from 'preact/compat';

// ---------- icons (24×24, stroke based) ----------

const S = { fill: 'none', stroke: 'currentColor', 'stroke-width': 1.8, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' };
const F = { fill: 'currentColor', stroke: 'none' };

const ICONS = {
  back: <polyline {...S} points="15 18 9 12 15 6" />,
  chevronUp: <polyline {...S} points="18 15 12 9 6 15" />,
  chevronDown: <polyline {...S} points="6 9 12 15 18 9" />,
  chevronsUp: (
    <g {...S}>
      <polyline points="17 11 12 6 7 11" />
      <polyline points="17 18 12 13 7 18" />
    </g>
  ),
  chevronsDown: (
    <g {...S}>
      <polyline points="7 6 12 11 17 6" />
      <polyline points="7 13 12 18 17 13" />
    </g>
  ),
  play: <path {...F} d="M7 4.5v15a1 1 0 0 0 1.5.86l12.4-7.5a1 1 0 0 0 0-1.72L8.5 3.64A1 1 0 0 0 7 4.5z" />,
  pause: (
    <g {...F}>
      <rect x="6" y="4" width="4" height="16" rx="1" />
      <rect x="14" y="4" width="4" height="16" rx="1" />
    </g>
  ),
  back15: (
    <g>
      <path {...S} d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3" />
      <polyline {...S} points="4 3.5 4.5 7.2 8.2 6.7" />
      <text x="12" y="15.2" text-anchor="middle" font-size="7.5" font-weight="700" fill="currentColor" font-family="Segoe UI, sans-serif">15</text>
    </g>
  ),
  fwd15: (
    <g>
      <path {...S} d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3" />
      <polyline {...S} points="20 3.5 19.5 7.2 15.8 6.7" />
      <text x="12" y="15.2" text-anchor="middle" font-size="7.5" font-weight="700" fill="currentColor" font-family="Segoe UI, sans-serif">15</text>
    </g>
  ),
  volume: (
    <g>
      <path {...F} d="M3 9.5h3.5L11 5.5v13l-4.5-4H3z" />
      <path {...S} d="M15 9a4 4 0 0 1 0 6M17.5 6.5a7.5 7.5 0 0 1 0 11" />
    </g>
  ),
  mute: (
    <g>
      <path {...F} d="M3 9.5h3.5L11 5.5v13l-4.5-4H3z" />
      <path {...S} d="M15.5 9.5l5 5M20.5 9.5l-5 5" />
    </g>
  ),
  more: (
    <g {...F}>
      <circle cx="5.5" cy="12" r="1.7" />
      <circle cx="12" cy="12" r="1.7" />
      <circle cx="18.5" cy="12" r="1.7" />
    </g>
  ),
  fullscreen: <path {...S} d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5" />,
  exitFullscreen: <path {...S} d="M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5" />,
  search: (
    <g {...S}>
      <circle cx="11" cy="11" r="6.5" />
      <path d="M20 20l-4.2-4.2" />
    </g>
  ),
  close: <path {...S} d="M6 6l12 12M18 6L6 18" />,
  plus: <path {...S} d="M12 5v14M5 12h14" />,
  home: <path {...S} d="M4 11l8-7 8 7v8.5a1 1 0 0 1-1 1h-4.5v-6h-5v6H5a1 1 0 0 1-1-1z" />,
  clock: (
    <g {...S}>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7.5V12l3 2" />
    </g>
  ),
  trash: <path {...S} d="M4 7h16M9.5 7V4.5h5V7M6.5 7l1 13h9l1-13M10 11v6M14 11v6" />,
  settings: (
    <g {...S}>
      <circle cx="12" cy="12" r="3" />
      <path d="M12 2.8v2.4M12 18.8v2.4M2.8 12h2.4M18.8 12h2.4M5.5 5.5l1.7 1.7M16.8 16.8l1.7 1.7M5.5 18.5l1.7-1.7M16.8 7.2l1.7-1.7" />
    </g>
  ),
  share: <path {...S} d="M12 15V3.5M7.5 8L12 3.5 16.5 8M5 12v7.5a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1V12" />,
  film: (
    <g {...S}>
      <rect x="3.5" y="5" width="17" height="14" rx="2" />
      <path d="M8 5v14M16 5v14M3.5 9.5H8M3.5 14.5H8M16 9.5h4.5M16 14.5h4.5" />
    </g>
  ),
  mic: (
    <g {...S}>
      <rect x="9" y="3.5" width="6" height="11" rx="3" />
      <path d="M5.5 11.5a6.5 6.5 0 0 0 13 0M12 18v3" />
    </g>
  ),
  thumbUp: <path {...S} d="M7 10.5V20M7 10.5l4-7.5a2.3 2.3 0 0 1 3 2.6l-.7 3.9h5.3a2 2 0 0 1 2 2.4l-1.4 6.6a2 2 0 0 1-2 1.5H7M7 10.5H4.5a1 1 0 0 0-1 1V19a1 1 0 0 0 1 1H7" />,
  thumbUpFill: <path {...F} d="M7 10.5l4-7.5a2.3 2.3 0 0 1 3 2.6l-.7 3.9h5.3a2 2 0 0 1 2 2.4l-1.4 6.6a2 2 0 0 1-2 1.5H7zM3.5 11.5a1 1 0 0 1 1-1H6V20H4.5a1 1 0 0 1-1-1z" />,
  sparkle: <path {...F} d="M12 2.5l1.9 6.4 6.6 3.1-6.6 3.1L12 21.5l-1.9-6.4L3.5 12l6.6-3.1z" />,
  check: <polyline {...S} stroke-width="2.4" points="5 12.5 10 17 19 7.5" />,
  minus: <path {...S} stroke-width="2.4" d="M6 12h12" />,
  warning: (
    <g>
      <path {...F} d="M10.3 3.9L2.4 18a2 2 0 0 0 1.7 3h15.8a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" />
      <path stroke="#fff" stroke-width="2" stroke-linecap="round" d="M12 9v4.5M12 17h.01" />
    </g>
  ),
  docPlus: (
    <g {...S}>
      <path d="M14 3.5H7a1.5 1.5 0 0 0-1.5 1.5v14A1.5 1.5 0 0 0 7 20.5h10a1.5 1.5 0 0 0 1.5-1.5V8z" />
      <path d="M14 3.5V8h4.5M12 11v6M9 14h6" />
    </g>
  ),
  bubble: (
    <g {...S}>
      <path d="M4.5 5.5h15a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H10l-4.5 3v-3h-1a1 1 0 0 1-1-1v-10a1 1 0 0 1 1-1z" />
      <path d="M8 10h8M8 13.5h5" />
    </g>
  ),
  inbox: (
    <g {...S}>
      <path d="M3.5 13.5l2.5-8h12l2.5 8v5a1 1 0 0 1-1 1h-15a1 1 0 0 1-1-1z" />
      <path d="M3.5 13.5H8.5l1 2.5h5l1-2.5h5" />
    </g>
  ),
  eye: (
    <g {...S}>
      <path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z" />
      <circle cx="12" cy="12" r="3" />
    </g>
  ),
  eyeOff: <path {...S} d="M3 3l18 18M10.6 6a9.8 9.8 0 0 1 1.4-.1c6 0 9.5 6.1 9.5 6.1a17 17 0 0 1-3 3.6M6.6 7.1A16.8 16.8 0 0 0 2.5 12s3.5 6.5 9.5 6.5a9.5 9.5 0 0 0 4.1-.9M9.9 9.9a3 3 0 0 0 4.2 4.2" />,
  waveform: <path {...S} stroke-width="2" d="M4 10v4M8 7v10M12 4v16M16 7v10M20 10v4" />,
  folder: <path {...S} d="M3.5 6.5a1 1 0 0 1 1-1h5l2 2.5h8a1 1 0 0 1 1 1v9.5a1 1 0 0 1-1 1h-15a1 1 0 0 1-1-1z" />,
};

export function Icon({ name, size = 16, class: cls = '', style }) {
  const flip = name === 'thumbDown' || name === 'thumbDownFill';
  const key = name === 'thumbDown' ? 'thumbUp' : name === 'thumbDownFill' ? 'thumbUpFill' : name;
  return (
    <svg class={`icon ${cls}`} viewBox="0 0 24 24" width={size} height={size} style={{ width: size, height: size, ...style }} aria-hidden="true">
      {flip ? <g transform="rotate(180 12 12)">{ICONS[key]}</g> : ICONS[key]}
    </svg>
  );
}

export function Logo({ size = 32 }) {
  return (
    <span class="logo" style={{ width: size, height: size }}>
      <Icon name="waveform" size={size * 0.62} />
    </span>
  );
}

export function avatarInitial(name) {
  const t = (name || '').trim();
  const m = /^(?:说话人|speaker)\s*(\d+)$/i.exec(t);
  if (m) return m[1].slice(0, 2);
  return t ? Array.from(t)[0].toUpperCase() : '?';
}

export function Avatar({ name, color, size = 22 }) {
  return <span class="avatar" data-initial={avatarInitial(name)} style={{ width: size, height: size, background: color, fontSize: size * 0.5 }} />;
}

export function Tag({ text, warn }) {
  return <span class={`tag ${warn ? 'warn' : ''}`}>{text}</span>;
}

export function Checkbox({ checked, mixed, onChange, class: cls = '' }) {
  return (
    <button
      class={`checkbox ${checked ? 'on' : mixed ? 'mixed' : ''} ${cls}`}
      onClick={(e) => {
        e.stopPropagation();
        onChange?.(!checked);
      }}
      aria-checked={checked}
      role="checkbox"
    >
      {checked ? <Icon name="check" size={12} /> : mixed ? <Icon name="minus" size={12} /> : null}
    </button>
  );
}

export function Switch({ on, onChange, label }) {
  return (
    <div class="switch-row" onClick={() => onChange(!on)} role="switch" aria-checked={on}>
      <span class={`switch ${on ? 'on' : ''}`} />
      <span>{label}</span>
    </div>
  );
}

export function Skeleton({ w, h = 12, r = 4 }) {
  return <div class="skeleton" style={{ width: w, height: h, borderRadius: r }} />;
}

export function Tab({ title, selected, onClick, small }) {
  return (
    <button class={`underline-tab ${small ? 'small' : ''} ${selected ? 'selected' : ''}`} onClick={onClick}>
      {title}
    </button>
  );
}

/**
 * Dropdown menu positioned under (or above) its trigger, rendered in a portal.
 * items: [{ label, onClick, disabled, selected, danger } | 'sep']
 */
export function Menu({ trigger, items, align = 'left', up = false, title }) {
  const [open, setOpen] = useState(false);
  const [pos, setPos] = useState(null);
  const anchor = useRef(null);
  const menu = useRef(null);

  useLayoutEffect(() => {
    if (!open || !anchor.current) return;
    const r = anchor.current.getBoundingClientRect();
    const m = menu.current?.getBoundingClientRect();
    const w = m?.width || 180;
    const h = m?.height || 0;
    let left = align === 'right' ? r.right - w : r.left;
    left = Math.max(8, Math.min(left, window.innerWidth - w - 8));
    let top = up ? r.top - h - 6 : r.bottom + 6;
    if (!up && top + h > window.innerHeight - 8) top = Math.max(8, r.top - h - 6);
    setPos({ left, top });
  }, [open, menu.current]);

  useEffect(() => {
    if (!open) return;
    const close = (e) => {
      if (menu.current?.contains(e.target) || anchor.current?.contains(e.target)) return;
      setOpen(false);
    };
    const esc = (e) => e.key === 'Escape' && setOpen(false);
    window.addEventListener('mousedown', close, true);
    window.addEventListener('keydown', esc, true);
    window.addEventListener('blur', () => setOpen(false), { once: true });
    return () => {
      window.removeEventListener('mousedown', close, true);
      window.removeEventListener('keydown', esc, true);
    };
  }, [open]);

  return (
    <span class="menu-anchor" ref={anchor} title={title}>
      {trigger({ open, toggle: () => setOpen(!open) })}
      {open &&
        createPortal(
          <div class="menu" ref={menu} style={pos ? { left: pos.left, top: pos.top } : { visibility: 'hidden', left: 0, top: 0 }}>
            {items.filter(Boolean).map((it, i) =>
              it === 'sep' ? (
                <div class="menu-sep" key={i} />
              ) : (
                <button
                  key={i}
                  class={`menu-item ${it.selected ? 'selected' : ''} ${it.danger ? 'danger' : ''}`}
                  disabled={it.disabled}
                  onClick={(e) => {
                    e.stopPropagation();
                    setOpen(false);
                    it.onClick?.();
                  }}
                >
                  {it.selected !== undefined && <span style={{ width: 14, display: 'inline-flex' }}>{it.selected && <Icon name="check" size={14} />}</span>}
                  {it.label}
                </button>
              ),
            )}
          </div>,
          document.body,
        )}
    </span>
  );
}

/** Context menu at the mouse position. */
export function useContextMenu() {
  const [state, setState] = useState(null);
  const ref = useRef(null);
  useEffect(() => {
    if (!state) return;
    const close = (e) => {
      if (!ref.current?.contains(e.target)) setState(null);
    };
    window.addEventListener('mousedown', close, true);
    window.addEventListener('blur', () => setState(null), { once: true });
    return () => window.removeEventListener('mousedown', close, true);
  }, [state]);
  const open = (e, items) => {
    e.preventDefault();
    e.stopPropagation();
    setState({ x: Math.min(e.clientX, window.innerWidth - 200), y: Math.min(e.clientY, window.innerHeight - 40 * items.length), items });
  };
  const node =
    state &&
    createPortal(
      <div class="menu" ref={ref} style={{ left: state.x, top: state.y }}>
        {state.items.map((it, i) =>
          it === 'sep' ? (
            <div class="menu-sep" key={i} />
          ) : (
            <button
              key={i}
              class={`menu-item ${it.danger ? 'danger' : ''}`}
              onClick={() => {
                setState(null);
                it.onClick();
              }}
            >
              {it.label}
            </button>
          ),
        )}
      </div>,
      document.body,
    );
  return [open, node];
}

export function Modal({ children, onClose, class: cls = '', width }) {
  useEffect(() => {
    const esc = (e) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        onClose?.();
      }
    };
    window.addEventListener('keydown', esc, true);
    return () => window.removeEventListener('keydown', esc, true);
  }, [onClose]);
  return createPortal(
    <div class="modal-backdrop" onMouseDown={(e) => e.target === e.currentTarget && onClose?.()}>
      <div class={`modal ${cls}`} style={width ? { width } : null} onMouseDown={(e) => e.stopPropagation()}>
        {children}
      </div>
    </div>,
    document.body,
  );
}

/** Small text prompt dialog (rename). */
export function PromptDialog({ title, initial, onDone, onCancel }) {
  const [value, setValue] = useState(initial || '');
  const input = useRef(null);
  useEffect(() => {
    input.current?.focus();
    input.current?.select();
  }, []);
  const submit = () => onDone(value.trim());
  return (
    <Modal onClose={onCancel} width={420}>
      <h2>{title}</h2>
      <input
        ref={input}
        class="field"
        style={{ width: '100%', margin: '16px 0 20px' }}
        value={value}
        onInput={(e) => setValue(e.currentTarget.value)}
        onKeyDown={(e) => e.key === 'Enter' && submit()}
      />
      <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 12 }}>
        <button class="btn-secondary" onClick={onCancel}>
          取消
        </button>
        <button class="btn-primary" onClick={submit} disabled={!value.trim()}>
          确定
        </button>
      </div>
    </Modal>
  );
}
