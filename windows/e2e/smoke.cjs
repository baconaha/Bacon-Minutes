// Stage 1: launch, import, open detail, screenshots.
const { _electron } = require('playwright');
const path = require('path');
const fs = require('fs');
const APP = path.resolve(__dirname, '..');
const WORK = path.join(__dirname, '.work');
const OUT = process.env.OUT || path.join(WORK, 'shots');
const DATA = process.env.DATA || path.join(WORK, 'userdata');
fs.rmSync(DATA, { recursive: true, force: true }); // fresh library for each full run
fs.mkdirSync(OUT, { recursive: true });

(async () => {
  const app = await _electron.launch({
    executablePath: path.join(APP, 'node_modules/electron/dist/electron'),
    args: ['--no-sandbox', path.join(APP, 'dist/main.cjs')],
    env: { ...process.env, LOCALMINUTES_E2E: '1', LOCALMINUTES_USER_DATA: DATA, LOCALMINUTES_LANG: 'zh-CN', NODE_OPTIONS: '' },
  });
  const page = await app.firstWindow();
  const errors = [];
  page.on('console', (m) => { if (['error', 'warning'].includes(m.type())) errors.push(`[${m.type()}] ${m.text()}`); });
  page.on('pageerror', (e) => errors.push(`[pageerror] ${e.message}`));
  app.process().stdout.on('data', (d) => process.stdout.write('[main] ' + d));
  app.process().stderr.on('data', (d) => { const s = String(d); if (!/dbus|Fontconfig|openssl-ca|GLib|libva|viz_main|gpu/i.test(s)) process.stdout.write('[main-err] ' + s); });
  await page.setViewportSize?.({ width: 1280, height: 820 }).catch(() => {});
  await page.waitForSelector('.list-page', { timeout: 15000 });
  await page.waitForTimeout(500);
  await page.screenshot({ path: `${OUT}/01-empty.png` });

  const media = path.join(WORK, 'media');
  const t0 = Date.now();
  await page.evaluate((p) => window.__lm.importPaths([p]), media);
  console.log('import took', Date.now() - t0, 'ms');
  await page.waitForTimeout(800);
  const rows = await page.$$eval('.row', (els) => els.map((e) => e.innerText.replace(/\n+/g, ' | ')));
  console.log('rows:', rows);
  const toast = await page.$eval('.toast', (e) => e.innerText).catch(() => null);
  console.log('toast:', toast);
  await page.screenshot({ path: `${OUT}/02-list.png` });

  // open the video minute
  await page.click('.row:has-text("周会复盘")');
  await page.waitForSelector('.para', { timeout: 15000 });
  await page.waitForFunction(() => window.__lm.state.detail.value?.mediaState.value === 'ready', null, { timeout: 15000 });
  await page.waitForTimeout(600);
  const info = await page.evaluate(() => {
    const d = window.__lm.state.detail.value;
    return { paras: document.querySelectorAll('.para').length, cues: document.querySelectorAll('.cue').length, duration: d.totalDuration, state: d.mediaState.value, title: d.minute.value.title };
  });
  console.log('detail:', info);
  await page.screenshot({ path: `${OUT}/03-detail.png` });
  console.log('console errors:', errors.slice(0, 20));
  await app.close();
})().catch((e) => { console.error('FAILED', e); process.exit(1); });
