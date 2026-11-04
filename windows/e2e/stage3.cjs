const { _electron } = require('playwright');
const path = require('path');
const fs = require('fs');
const APP = path.resolve(__dirname, '..');
const WORK = path.join(__dirname, '.work');
const OUT = path.join(WORK, 'shots');
const DATA = path.join(WORK, 'userdata');
const results = [];
const check = (name, ok, detail = '') => results.push(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ' — ' + detail : ''}`);
const theme = process.env.THEME || 'light';

(async () => {
  const app = await _electron.launch({
    executablePath: path.join(APP, 'node_modules/electron/dist/electron'),
    args: ['--no-sandbox', path.join(APP, 'dist/main.cjs')],
    env: { ...process.env, LOCALMINUTES_E2E: '1', LOCALMINUTES_USER_DATA: DATA, LOCALMINUTES_LANG: 'zh-CN', LOCALMINUTES_THEME: theme, NODE_OPTIONS: '' },
  });
  const page = await app.firstWindow();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  await page.waitForSelector('.row', { timeout: 15000 });
  const D = 'window.__lm.state.detail.value';
  const ev = (e) => page.evaluate(e);

  if (theme === 'dark') {
    await page.emulateMedia({ colorScheme: 'dark' });
    await page.waitForTimeout(200);
    await page.screenshot({ path: `${OUT}/20-dark-list.png` });
    await page.click('.row:has-text("周会复盘")');
    await page.waitForFunction(() => window.__lm.state.detail.value?.mediaState.value === 'ready');
    await ev(`${D}.jumpToCue(40, 3)`);
    await page.waitForTimeout(900);
    await ev(`${D}.pause()`);
    await page.click('.underline-tab:has-text("智能纪要")');
    await page.mouse.move(300, 300);
    await page.screenshot({ path: `${OUT}/21-dark-detail.png` });
    await page.click('.underline-tab:has-text("文字记录")');
    await page.screenshot({ path: `${OUT}/22-dark-transcript.png` });
    console.log('errors:', errors);
    await app.close();
    return;
  }

  // import dialog look
  await page.keyboard.press('Control+o');
  await page.waitForSelector('.modal');
  await page.screenshot({ path: `${OUT}/18-import-dialog.png` });
  await page.keyboard.press('Escape');

  // progress segments
  await page.click('.row:has-text("周会复盘")');
  await page.waitForFunction(() => window.__lm.state.detail.value?.mediaState.value === 'ready');
  await page.waitForTimeout(300);
  check('progress bar has one segment per chapter', (await page.$$('.progress .seg')).length === 4);
  check('resumes from saved position', (await ev(`${D}.video.currentTime`)) > 60);

  // per-character highlight on the longest cue
  const id = await ev(`(() => { const cs = ${D}.transcript.value.cues; let best = 0; cs.forEach((c, i) => { if (c.end - c.start > cs[best].end - cs[best].start) best = i; }); return best; })()`);
  await ev(`${D}.jumpToCue(${id}, null)`);
  await page.waitForTimeout(1500);
  const st = await ev(`({ chars: CSS.highlights.get('lm-char').size, cur: +document.querySelector('.cue.cur')?.dataset.c, t: ${D}.video.currentTime })`);
  check('per-character highlight advances inside a long cue', st.chars === 1 && st.cur === id, JSON.stringify(st));
  const charText = await ev(`[...CSS.highlights.get('lm-char')][0].toString()`);
  check('highlighted character is one character', [...charText].length === 1, charText);
  await ev(`${D}.pause()`);

  // click jumps to estimated character time
  const cue = await ev(`${D}.transcript.value.cues[${id}]`);
  const span = page.locator(`.cue[data-c="${id}"]`);
  await span.scrollIntoViewIfNeeded();
  const box = await span.boundingBox();
  await page.mouse.click(box.x + box.width * 0.7, box.y + 10);
  await page.waitForTimeout(500);
  const t = await ev(`${D}.video.currentTime`);
  check('click inside a long cue seeks past its start (per-char estimate)', t > cue.start + 0.2 && t < cue.end, `${cue.start.toFixed(2)} < ${t.toFixed(2)} < ${cue.end.toFixed(2)}`);
  await ev(`${D}.pause()`);
  await page.keyboard.press('Control+BracketLeft');
  await page.waitForSelector('.list-page');

  // missing media
  const m4a = path.join(WORK, 'media', '访谈录音.m4a');
  fs.renameSync(m4a, m4a + '.bak');
  try {
    await page.click('.row:has-text("访谈录音")');
    await page.waitForTimeout(800);
    check('missing media shows relocate prompt and tag', (await page.innerText('.player')).includes('找不到媒体文件') && (await page.innerText('.topbar')).includes('媒体缺失'));
    check('transcript still usable with media missing', (await page.$$('.para')).length > 5);
    await page.screenshot({ path: `${OUT}/19-missing.png` });
  } finally {
    fs.renameSync(m4a + '.bak', m4a);
  }
  await page.keyboard.press('Control+BracketLeft');

  // rename from list context menu
  await page.waitForSelector('.list-page');
  await page.click('.row:has-text("访谈录音")', { button: 'right' });
  await page.click('.menu-item:has-text("重命名")');
  await page.fill('.modal input', '客户访谈');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(300);
  check('rename via context menu', !!(await page.$('.row:has-text("客户访谈")')));

  console.log(results.join('\n'));
  console.log('errors:', errors);
  await app.close();
})().catch((e) => {
  console.log(results.join('\n'));
  console.error('FAILED', e);
  process.exit(1);
});
