// Which share or drive a path is on (kept apart from probe.js so tests can load it without Electron).

/** `\\server\share`, `X:` or the first folder of a POSIX path. */
export function volumeKey(p) {
  const s = String(p || '');
  const m = /^(\\\\[^\\/]+[\\/][^\\/]+)/.exec(s) || /^([a-zA-Z]:)/.exec(s) || /^(\/[^/]+)/.exec(s);
  return (m ? m[1] : s).toLowerCase();
}

