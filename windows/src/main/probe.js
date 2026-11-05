// Main-process side of the file-check process (fsWorker.js). Every check of a linked media file
// goes through here with a deadline, so an unreachable network share can never block the main
// process. While a check on a share or drive is overdue, further checks on it answer
// "unreachable" at once instead of piling up more stuck requests.
import { utilityProcess } from 'electron';
import { volumeKey } from './volume.js';

export { volumeKey };

export const PROBE_TIMEOUT = 4000;
/** A copy that makes no progress for this long has stalled. */
const COPY_STALL = 30000;

export class FsProbe {
  constructor(script) {
    this.script = script;
    this.child = null;
    this.pending = new Map();
    this.seq = 0;
    /** volume key → time until which it counts as unreachable */
    this.stuck = new Map();
  }

  spawn() {
    return utilityProcess.fork(this.script, [], { serviceName: 'Bacon Minutes file check', stdio: 'ignore' });
  }

  ensure() {
    if (this.child) return this.child;
    const child = this.spawn();
    child.on('message', (msg) => this.onMessage(msg));
    child.on('exit', () => {
      if (this.child === child) this.child = null;
      for (const [id, entry] of this.pending) {
        if (entry.child !== child) continue;
        this.pending.delete(id);
        entry.finish({ state: 'unreachable' });
      }
    });
    this.child = child;
    return child;
  }

  isStuck(key) {
    const until = this.stuck.get(key);
    if (until == null) return false;
    if (until > Date.now()) return true;
    this.stuck.delete(key);
    return false;
  }

  /**
   * `{ state: 'found' | 'missing' | 'unreachable', size }`. `force` skips the stuck shortcut
   * (the user pressed 重新检测路径).
   */
  stat(p, { force = false, timeout = PROBE_TIMEOUT } = {}) {
    if (!p) return Promise.resolve({ state: 'missing' });
    const key = volumeKey(p);
    if (!force && this.isStuck(key)) return Promise.resolve({ state: 'unreachable' });
    return new Promise((resolve) => {
      const id = ++this.seq;
      let settled = false;
      const entry = {
        key,
        overdue: false,
        finish: (r) => {
          if (settled) return;
          settled = true;
          clearTimeout(entry.timer);
          resolve(r);
        },
      };
      this.pending.set(id, entry);
      entry.timer = setTimeout(() => {
        entry.overdue = true;
        this.stuck.set(key, Date.now() + 30000);
        entry.finish({ state: 'unreachable' });
        this.restartIfClogged();
      }, timeout);
      try {
        entry.child = this.ensure();
        entry.child.postMessage({ op: 'stat', id, path: p });
      } catch {
        this.pending.delete(id);
        entry.finish({ state: 'unreachable' });
      }
    });
  }

  onMessage(msg) {
    const entry = this.pending.get(msg.id);
    if (!entry) return;
    this.pending.delete(msg.id);
    // The share answered, however late.
    if (entry.overdue) this.stuck.delete(entry.key);
    entry.finish(msg.ok ? { state: msg.isFile ? 'found' : 'missing', size: msg.size } : { state: 'missing', code: msg.code });
  }

  /** Each stuck check holds one of the worker's threads; after a few, start a fresh worker. */
  restartIfClogged() {
    let overdue = 0;
    for (const e of this.pending.values()) if (e.overdue) overdue++;
    if (overdue >= 3 && this.child) {
      const old = this.child;
      this.child = null;
      old.kill();
    }
  }

  /** Copies in a separate worker; rejects if the source stops delivering data. */
  copy(src, dest, onProgress = () => {}) {
    return new Promise((resolve, reject) => {
      const child = this.spawn();
      let settled = false;
      let watchdog = null;
      const finish = (err, value) => {
        if (settled) return;
        settled = true;
        clearTimeout(watchdog);
        child.kill();
        if (err) reject(err);
        else resolve(value);
      };
      const arm = () => {
        clearTimeout(watchdog);
        watchdog = setTimeout(() => {
          const e = new Error('stalled');
          e.code = 'stalled';
          finish(e);
        }, COPY_STALL);
      };
      child.on('message', (msg) => {
        if (msg.progress != null) {
          arm();
          onProgress(msg.progress);
        } else if (msg.ok) {
          onProgress(1);
          finish(null, { size: msg.size });
        } else {
          const e = new Error(msg.error || 'copy failed');
          e.code = msg.code;
          finish(e);
        }
      });
      child.on('exit', () => finish(Object.assign(new Error('copy process exited'), { code: 'exited' })));
      child.on('spawn', () => {
        arm();
        child.postMessage({ op: 'copy', id: 1, src, dest });
      });
    });
  }
}
