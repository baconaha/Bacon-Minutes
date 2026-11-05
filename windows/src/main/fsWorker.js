// Runs in an Electron utility process. File checks and copies of linked media happen here:
// on a network share that has gone away (a NAS after leaving the network) such calls can stall
// for a minute or more, and in the main process that froze the whole app.
import fs from 'node:fs';
import path from 'node:path';

const port = process.parentPort;
// End-to-end tests: paths under this folder never answer, like a dead share.
const HANG = process.env.BACON_TEST_HANG_DIR || '';
const hangs = (p) => HANG && p.startsWith(HANG);

port.on('message', (e) => {
  const msg = e.data;
  if (msg.op === 'stat') stat(msg);
  else if (msg.op === 'copy') copy(msg);
});

async function stat({ id, path: p }) {
  if (hangs(p)) return;
  try {
    const st = await fs.promises.stat(p);
    port.postMessage({ id, ok: true, isFile: st.isFile(), size: st.size });
  } catch (err) {
    port.postMessage({ id, ok: false, code: err.code || 'ERR' });
  }
}

async function copy({ id, src, dest }) {
  const part = dest + '.part';
  try {
    if (hangs(src)) return;
    const st = await fs.promises.stat(src);
    await fs.promises.mkdir(path.dirname(dest), { recursive: true });
    await new Promise((resolve, reject) => {
      const rs = fs.createReadStream(src, { highWaterMark: 4 << 20 });
      const ws = fs.createWriteStream(part);
      let done = 0;
      let last = 0;
      rs.on('data', (chunk) => {
        done += chunk.length;
        const now = Date.now();
        if (now - last > 150) {
          last = now;
          port.postMessage({ id, progress: st.size > 0 ? Math.min(0.99, done / st.size) : 0 });
        }
      });
      rs.on('error', reject);
      ws.on('error', reject);
      ws.on('finish', resolve);
      rs.pipe(ws);
    });
    await fs.promises.rm(dest, { force: true });
    await fs.promises.rename(part, dest);
    port.postMessage({ id, ok: true, size: st.size });
  } catch (err) {
    await fs.promises.rm(part, { force: true }).catch(() => {});
    port.postMessage({ id, ok: false, error: err.message, code: err.code || 'ERR' });
  }
}
