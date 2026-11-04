// Text helpers shared by main and renderer. Offsets are UTF-16 code units, like DOM ranges.

export function isCJK(ch) {
  if (!ch) return false;
  const c = ch.codePointAt(0);
  return (
    (c >= 0x2e80 && c <= 0x2fdf) ||
    (c >= 0x3000 && c <= 0x303f) ||
    (c >= 0x3040 && c <= 0x30ff) ||
    (c >= 0x3100 && c <= 0x31ff) ||
    (c >= 0x3400 && c <= 0x4dbf) ||
    (c >= 0x4e00 && c <= 0x9fff) ||
    (c >= 0xac00 && c <= 0xd7af) ||
    (c >= 0xf900 && c <= 0xfaff) ||
    (c >= 0xfe30 && c <= 0xfe4f) ||
    (c >= 0xff00 && c <= 0xffef) ||
    (c >= 0x20000 && c <= 0x2fa1f)
  );
}

const PUNCT = /[\p{P}…~～、·]/u;

export function isPunct(ch) {
  return !!ch && PUNCT.test(ch);
}

export function lastChar(s) {
  if (!s) return '';
  const chars = Array.from(s);
  return chars[chars.length - 1];
}

export function firstChar(s) {
  if (!s) return '';
  return String.fromCodePoint(s.codePointAt(0));
}

/** Joins two fragments: CJK on either side joins directly, otherwise with a space. */
export function joinFragment(a, b) {
  if (!a) return b;
  if (!b) return a;
  if (isCJK(lastChar(a)) || isCJK(firstChar(b))) return a + b;
  return a + ' ' + b;
}

function foldCode(c) {
  if (c >= 0xff01 && c <= 0xff5e) c -= 0xfee0; // full-width ASCII
  else if (c === 0x3000) c = 0x20; // ideographic space
  if (c >= 0x41 && c <= 0x5a) c += 0x20; // A-Z
  else if (c >= 0xc0 && c <= 0xde && c !== 0xd7) c += 0x20; // Latin-1 capitals
  return c;
}

/** Width- and case-folded copy of `s` with exactly the same length. */
export function fold(s) {
  const out = new Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = String.fromCharCode(foldCode(s.charCodeAt(i)));
  return out.join('');
}

/** Start offsets of non-overlapping occurrences of an already folded needle. */
export function occurrences(needleFolded, hayFolded) {
  const out = [];
  if (!needleFolded) return out;
  let i = hayFolded.indexOf(needleFolded);
  while (i !== -1) {
    out.push(i);
    i = hayFolded.indexOf(needleFolded, i + needleFolded.length);
  }
  return out;
}

export function containsFolded(hayFolded, needle) {
  const n = fold(needle.trim());
  return n.length > 0 && hayFolded.includes(n);
}

/** Stable 64-bit FNV-1a hex digest over UTF-8 bytes. */
export function fnv1a(str) {
  let h = 0xcbf29ce484222325n;
  const prime = 0x100000001b3n;
  const bytes = new TextEncoder().encode(str);
  for (const b of bytes) {
    h ^= BigInt(b);
    h = (h * prime) & 0xffffffffffffffffn;
  }
  return h.toString(16).padStart(16, '0');
}

export function escapeHTML(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}
