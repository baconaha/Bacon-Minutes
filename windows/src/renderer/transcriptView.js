// The transcript as plain DOM (one span per cue), highlighted with the CSS Custom Highlight API
// so playback updates never touch layout — the web counterpart of NSLayoutManager temporary attributes.
import { escapeHTML } from '../core/text.js';
import { timestamp } from '../core/time.js';
import { avatarInitial } from './components/ui.jsx';

const HL = {
  hit: 'lm-hit',
  hitCur: 'lm-hit-cur',
  char: 'lm-char',
};

function highlights() {
  if (!globalThis.CSS?.highlights) return null;
  let reg = CSS.highlights;
  if (!reg.has(HL.hit)) {
    const hit = new Highlight();
    const cur = new Highlight();
    const ch = new Highlight();
    hit.priority = 1;
    cur.priority = 2;
    ch.priority = 3;
    reg.set(HL.hit, hit);
    reg.set(HL.hitCur, cur);
    reg.set(HL.char, ch);
  }
  return { hit: reg.get(HL.hit), hitCur: reg.get(HL.hitCur), char: reg.get(HL.char) };
}

export class TranscriptView {
  constructor(scroller, model) {
    this.scroller = scroller;
    this.model = model;
    this.hl = highlights();
    this.cueEls = [];
    this.segNodes = []; // per paragraph: [{ node, start, len }]
    this.curEl = null;
    this.down = null;
    this.dirRaf = 0;

    this.onMouseDown = (e) => {
      if (e.button !== 0) return;
      // Clicking the scrollbar counts as manual scrolling.
      if (e.offsetX >= this.scroller.clientWidth && e.target === this.scroller) {
        this.model.userScrolled();
        return;
      }
      this.down = { x: e.clientX, y: e.clientY };
    };
    this.onMouseUp = (e) => this.handleClick(e);
    this.onWheel = () => this.model.userScrolled();
    this.onKey = (e) => {
      if (['PageUp', 'PageDown', 'Home', 'End', 'ArrowUp', 'ArrowDown'].includes(e.key)) this.model.userScrolled();
    };
    this.onScroll = () => {
      cancelAnimationFrame(this.dirRaf);
      this.dirRaf = requestAnimationFrame(() => this.updateDirection());
    };
    scroller.addEventListener('mousedown', this.onMouseDown);
    scroller.addEventListener('mouseup', this.onMouseUp);
    scroller.addEventListener('wheel', this.onWheel, { passive: true });
    scroller.addEventListener('keydown', this.onKey);
    scroller.addEventListener('scroll', this.onScroll, { passive: true });
  }

  destroy() {
    this.scroller.removeEventListener('mousedown', this.onMouseDown);
    this.scroller.removeEventListener('mouseup', this.onMouseUp);
    this.scroller.removeEventListener('wheel', this.onWheel);
    this.scroller.removeEventListener('keydown', this.onKey);
    this.scroller.removeEventListener('scroll', this.onScroll);
    this.clearHighlights();
  }

  clearHighlights() {
    if (!this.hl) return;
    this.hl.hit.clear();
    this.hl.hitCur.clear();
    this.hl.char.clear();
  }

  /** Builds the whole transcript DOM once per document version. */
  render() {
    const m = this.model;
    const tr = m.transcript.value;
    const paragraphs = m.paragraphs.value;
    const hours = m.hours;
    const speakers = new Map((tr?.speakers || []).map((s) => [s.id, s]));
    const parts = [];
    paragraphs.forEach((p, pi) => {
      const sp = speakers.get(p.speakerID);
      const name = sp?.name ?? p.speakerID;
      const color = sp?.colorHex ?? '#3370FF';
      parts.push(
        `<div class="para" data-p="${pi}"><div class="para-head"><span class="avatar" data-initial="${escapeHTML(avatarInitial(name))}" style="width:22px;height:22px;font-size:11px;background:${color}"></span>` +
          `<span class="name">${escapeHTML(name)}</span><span class="ts" data-ts="${pi}">${timestamp(p.start, hours)}</span></div><div class="para-body">`,
      );
      for (const s of m.bodies[pi].segs) {
        if (s.glue) parts.push(`<span class="glue" data-c="${s.cue}">${escapeHTML(s.text)}</span>`);
        else parts.push(`<span class="cue" data-c="${s.cue}">${escapeHTML(s.text)}</span>`);
      }
      parts.push('</div></div>');
    });
    this.clearHighlights();
    this.scroller.innerHTML = `<div class="tx-content">${parts.join('')}</div>`;

    this.cueEls = new Array(tr ? tr.cues.length : 0);
    this.segNodes = [];
    this.paraBodies = [];
    const paraEls = this.scroller.querySelectorAll('.para');
    paraEls.forEach((pEl, pi) => {
      const body = pEl.querySelector('.para-body');
      this.paraBodies[pi] = body;
      const segs = m.bodies[pi].segs;
      const nodes = [];
      Array.from(body.children).forEach((span, i) => {
        const seg = segs[i];
        if (!seg.glue) this.cueEls[seg.cue] = span;
        if (span.firstChild) nodes.push({ node: span.firstChild, start: seg.start, len: seg.text.length });
      });
      this.segNodes[pi] = nodes;
    });
    this.curEl = null;
  }

  // ---------- highlights ----------

  setCurrent(cue, offset) {
    const el = cue >= 0 ? this.cueEls[cue] : null;
    if (el !== this.curEl) {
      this.curEl?.classList.remove('cur');
      el?.classList.add('cur');
      this.curEl = el;
    }
    if (!this.hl) return;
    this.hl.char.clear();
    if (el && offset != null && el.firstChild) {
      const text = el.firstChild.textContent;
      let start = Math.min(offset, text.length - 1);
      const code = text.charCodeAt(start);
      if (code >= 0xdc00 && code <= 0xdfff && start > 0) start--; // never split a surrogate pair
      const end = Math.min(text.length, start + (text.codePointAt(start) > 0xffff ? 2 : 1));
      const r = new Range();
      r.setStart(el.firstChild, start);
      r.setEnd(el.firstChild, end);
      this.hl.char.add(r);
    }
  }

  rangeFor(hit) {
    const nodes = this.segNodes[hit.p];
    if (!nodes) return null;
    const locate = (offset, isEnd) => {
      for (const n of nodes) {
        if (offset > n.start + n.len) continue;
        if (offset < n.start) return null;
        if (isEnd ? offset > n.start : offset < n.start + n.len) return { node: n.node, off: offset - n.start };
      }
      const last = nodes[nodes.length - 1];
      return isEnd && last ? { node: last.node, off: last.len } : null;
    };
    const a = locate(hit.start, false);
    const b = locate(hit.end, true);
    if (!a || !b) return null;
    const r = new Range();
    r.setStart(a.node, a.off);
    r.setEnd(b.node, b.off);
    return r;
  }

  setHits(hits, current) {
    if (!this.hl) return;
    this.hl.hit.clear();
    this.hl.hitCur.clear();
    hits.forEach((h, i) => {
      const r = this.rangeFor(h);
      if (!r) return;
      if (i === current) this.hl.hitCur.add(r);
      else this.hl.hit.add(r);
    });
  }

  // ---------- scrolling (§5.5) ----------

  offsetTopOf(el) {
    const sr = this.scroller.getBoundingClientRect();
    return el.getBoundingClientRect().top - sr.top + this.scroller.scrollTop;
  }

  scrollToY(y, smooth) {
    const top = Math.max(0, y - this.scroller.clientHeight / 3);
    if (Math.abs(this.scroller.scrollTop - top) < 2) return;
    this.scroller.scrollTo({ top, behavior: smooth ? 'smooth' : 'auto' });
  }

  elementForCue(cue) {
    const el = this.cueEls[cue];
    if (el && el.textContent) return el;
    const p = this.model.paragraphs.value.findIndex((x) => x.cueIDs.includes(cue));
    return p >= 0 ? this.paraBodies[p] : null;
  }

  scrollToCue(cue, smooth) {
    const el = this.elementForCue(cue);
    if (el) this.scrollToY(this.offsetTopOf(el), smooth);
  }

  scrollToHit(i) {
    const h = this.model.hits.value[i];
    const r = h && this.rangeFor(h);
    if (!r) return;
    const rect = r.getBoundingClientRect();
    const sr = this.scroller.getBoundingClientRect();
    this.scrollToY(rect.top - sr.top + this.scroller.scrollTop, true);
  }

  updateDirection() {
    const m = this.model;
    if (m.following.value || m.currentCue < 0) return;
    const el = this.elementForCue(m.currentCue);
    if (!el) return;
    const y = this.offsetTopOf(el) - this.scroller.scrollTop;
    const above = y < this.scroller.clientHeight / 3;
    if (m.cueAbove.value !== above) m.cueAbove.value = above;
  }

  // ---------- clicks (§5.4) ----------

  handleClick(e) {
    const down = this.down;
    this.down = null;
    if (!down || e.button !== 0) return;
    if (Math.hypot(e.clientX - down.x, e.clientY - down.y) > 4) return;
    const sel = window.getSelection();
    if (sel && !sel.isCollapsed) return;
    const ts = e.target.closest?.('[data-ts]');
    if (ts) {
      this.model.jumpToParagraph(+ts.dataset.ts);
      return;
    }
    if (!e.target.closest?.('.para-body')) return;
    const pos = document.caretRangeFromPoint?.(e.clientX, e.clientY);
    let span = e.target.closest('[data-c]');
    let offset = null;
    if (pos && pos.startContainer.nodeType === Node.TEXT_NODE) {
      const owner = pos.startContainer.parentElement?.closest('[data-c]');
      if (owner) {
        span = owner;
        if (owner.classList.contains('cue')) {
          // caret offsets sit between characters; pick the character under the pointer
          let off = pos.startOffset;
          const text = pos.startContainer.textContent;
          if (off > 0) {
            const probe = new Range();
            probe.setStart(pos.startContainer, off - 1);
            probe.setEnd(pos.startContainer, off);
            const rect = probe.getBoundingClientRect();
            if (e.clientX <= rect.right && e.clientY >= rect.top && e.clientY <= rect.bottom) off -= 1;
          }
          offset = Math.min(off, Math.max(0, text.length - 1));
        }
      }
    }
    if (!span) {
      // Blank space at the end of a paragraph: use its last cue.
      const body = e.target.closest('.para-body');
      span = body?.querySelector('.cue:last-of-type');
    }
    if (span) this.model.jumpToCue(+span.dataset.c, offset);
  }
}
