// Feature parity with the Mac app: folders, stats, menus, dialogs, title editing, languages.
// Uses a fresh data folder under e2e/.work for each run.
const { _electron } = require('playwright');
const path = require('path');
const fs = require('fs');
const APP = path.resolve(__dirname, '..');
const WORK = path.join(__dirname, '.work');
const RUN = String(Date.now());
const OUT = path.join(WORK, 'parity');
const DATA = path.join(WORK, 'userdata-parity-' + RUN);
fs.mkdirSync(OUT, { recursive: true });
const results = [];
const check = (name, ok, detail = '') => results.push(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ' — ' + detail : ''}`);

(async () => {
  const app = await _electron.launch({
    executablePath: path.join(APP, 'node_modules/electron/dist/electron'),
    args: ['--no-sandbox', path.join(APP, 'dist/main.cjs')],
    env: { ...process.env, LOCALMINUTES_E2E: '1', LOCALMINUTES_USER_DATA: DATA, LOCALMINUTES_LANG: process.env.LANG_UI || 'zh-CN', NODE_OPTIONS: '' },
  });
  const page = await app.firstWindow();
  const errors = [];
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  page.on('pageerror', (e) => errors.push(`[pageerror] ${e.message}`));
  const ev = (e) => page.evaluate(e);
  const shot = (n) => page.screenshot({ path: `${OUT}/${n}.png` });
  await page.waitForSelector('.list-page', { timeout: 15000 });
  check('app name in sidebar', (await page.textContent('.sidebar-head')).includes('培根妙记'));

  await ev(`window.__lm.importPaths([${JSON.stringify(path.join(WORK, 'media'))}])`);
  await page.waitForSelector('.review-row', { timeout: 10000 });
  await page.waitForFunction(() => window.__lm.state.importReview.value?.rows.value.every((r) => r.inspected), null, { timeout: 30000 });
  await page.click('.review-storage .rs-check');
  await page.click('.review-foot .btn-primary');
  await page.waitForFunction(() => document.querySelectorAll('.row').length === 2, null, { timeout: 30000 });
  await page.waitForTimeout(800);
  check('two rows imported', (await page.$$('.row')).length === 2);
  const stats = await page.textContent('.lib-stats');
  check('library stats show count, duration, size', /2 个/.test(stats) && /小时/.test(stats) && /(MB|KB|GB)/.test(stats), stats.replace(/\s+/g, ' '));
  await shot('01-list');

  // new folder with inline rename
  await page.click('.sidebar-plus');
  await page.waitForSelector('.folder-input');
  await page.fill('.folder-input', '物理课');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(200);
  check('folder created and renamed', (await page.textContent('.folder-row')).includes('物理课'));
  check('new folder is the open section', (await page.textContent('.list-title-row h1')) === '物理课');
  await shot('02-empty-folder');

  // a second folder: clicking anywhere else saves the name, like the title
  await page.click('.sidebar-plus');
  await page.waitForSelector('.folder-input');
  await page.keyboard.type('化学课');
  await page.mouse.click(700, 500);
  await page.waitForTimeout(300);
  const names = await page.$$eval('.folder-row .folder-name', (els) => els.map((e) => e.textContent));
  check('click elsewhere saves a new folder name', names.includes('化学课') && !(await page.$('.folder-input')), JSON.stringify(names));
  await page.click('.sidebar-plus');
  await page.waitForSelector('.folder-input');
  await page.keyboard.type('生物课');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(200);

  // drag from empty space below the folders up across 生物课 and 化学课 (not 物理课)
  const area = await page.locator('.folders-scroll').boundingBox();
  const chem = await page.locator('.folder-row:has-text("化学课")').boundingBox();
  const lastRow = await page.locator('.folder-row').last().boundingBox();
  await page.mouse.move(area.x + area.width - 16, lastRow.y + lastRow.height + 40);
  await page.mouse.down();
  await page.mouse.move(area.x + area.width - 40, lastRow.y + 10, { steps: 4 });
  await page.mouse.move(area.x + 30, chem.y + 8, { steps: 6 });
  await shot('02b-folder-marquee');
  const live = await page.$$eval('.folder-row.batch .folder-name', (els) => els.map((e) => e.textContent));
  check('marquee selects the folders it crosses, live', live.length === 2 && live.includes('化学课') && live.includes('生物课'), JSON.stringify(live));
  check('marquee rectangle is drawn', !!(await page.$('.marquee')));
  await page.mouse.up();
  await page.waitForTimeout(150);
  check('selection stays after release, rectangle goes', (await page.$$('.folder-row.batch')).length === 2 && !(await page.$('.marquee')));
  await page.click('.folder-row:has-text("生物课")', { button: 'right' });
  check('right-click on a selected folder offers the batch delete', !!(await page.$('.menu-item:has-text("删除 2 个文件夹")')));
  await page.keyboard.press('Escape');
  await page.waitForTimeout(200);
  await page.keyboard.press('Delete');
  await page.waitForSelector('.flip-card');
  check('Delete asks to delete both folders', (await page.textContent('.confirm-title')).includes('删除 2 个文件夹'));
  await page.waitForTimeout(400);
  await shot('02c-delete-folders-confirm');
  await page.click('.btn-danger');
  await page.waitForTimeout(500);
  const left = await page.$$eval('.folder-row .folder-name', (els) => els.map((e) => e.textContent));
  check('both selected folders deleted, the other kept', JSON.stringify(left) === JSON.stringify(['物理课']), JSON.stringify(left));

  // drag a row from 全部 onto the folder
  await page.click('.nav-item:has-text("全部")');
  await page.waitForTimeout(150);
  await page.dragAndDrop('.row:has-text("周会复盘")', '.folder-row');
  await page.waitForTimeout(400);
  const moved = await ev(`window.__lm.state.minutes.value.find((m) => m.title.includes('周会复盘')).folderID`);
  check('drag a row onto a folder files it', !!moved);
  check('folder label shown in 全部', (await page.textContent('.row:has-text("周会复盘") .row-sub')).includes('物理课'));
  await page.mouse.move(700, 500);
  await page.waitForTimeout(150);
  check('folder count updates', (await page.textContent('.folder-count')).trim() === '1');

  // hover menus flip down
  await page.hover('.sort-trigger');
  await page.waitForSelector('.menu.from-top', { timeout: 2000 });
  await page.waitForTimeout(350);
  await shot('03-sort-menu-hover');
  await page.mouse.move(600, 700);
  await page.waitForTimeout(500);
  check('hover menu closes when the pointer leaves', !(await page.$('.menu')));

  // sort by name
  await page.hover('.sort-trigger');
  await page.waitForSelector('.menu.from-top', { timeout: 2000 });
  await page.click('.menu-item:has-text("名称")');
  await page.waitForTimeout(300);
  const titles = await page.$$eval('.row .row-title', (els) => els.map((e) => e.textContent.replace(/^纪要/, '')));
  const sorted = [...titles].sort(new Intl.Collator('zh-CN', { numeric: true, sensitivity: 'base' }).compare);
  check('sort by name orders rows by title', JSON.stringify(titles) === JSON.stringify(sorted) && (await page.textContent('.sort-trigger')).includes('名称'), JSON.stringify(titles));
  await ev(`window.__lm.state.updateGeneral({ listSort: 'created' })`);
  await page.mouse.move(600, 700);
  await page.waitForTimeout(400);

  // row ··· opens on click only
  await page.hover('.row:has-text("访谈录音") .col-ops .btn-icon');
  await page.waitForTimeout(400);
  check('row ··· does not open on hover', !(await page.$('.menu')));
  await page.click('.row:has-text("访谈录音") .col-ops .btn-icon');
  await page.waitForSelector('.menu');
  await page.waitForTimeout(350);
  await shot('04-row-menu');
  await page.click('.menu-item:has-text("移到回收站")');
  await page.waitForSelector('.flip-card');
  await page.waitForTimeout(450);
  check('trash confirmation has the bold media note', (await page.textContent('.confirm-emphasis')).includes('原始媒体文件不会被删除'));
  await page.hover('.btn-danger');
  await page.waitForTimeout(200);
  await shot('05-confirm-trash');
  await page.click('.btn-cancel');
  await page.waitForTimeout(300);
  check('cancel keeps the row', (await page.$$('.row')).length === 2);

  // folder properties
  await page.hover('.folder-row');
  await page.click('.folder-row .btn-icon');
  await page.click('.menu-item:has-text("属性")');
  await page.waitForSelector('.flip-card');
  await page.waitForTimeout(450);
  check('folder properties show count', (await page.textContent('.flip-card')).includes('1 个'));
  await shot('06-folder-info');
  await page.click('.flip-card .btn-primary');
  await page.waitForTimeout(300);

  // detail page, AI summary from the mock server
  await ev(`window.__lm.state.updateLLM({ ...window.__lm.state.llm.value, presetID: 'custom', protocol: 'openAI', baseURL: 'http://127.0.0.1:18765/v1', model: 'mock-large' })`);
  await page.click('.row:has-text("周会复盘")');
  await page.waitForSelector('.detail');
  await page.waitForFunction(() => window.__lm.state.detail.value?.mediaState.value === 'ready', null, { timeout: 15000 });
  await page.waitForTimeout(800);
  check('transcript faded in after the transition', await page.$eval('.tx-scroll', (e) => e.classList.contains('revealed') && getComputedStyle(e).opacity === '1'));
  check('no loading text in the player', !(await page.$('.player-msg')));
  await ev(`window.__lm.state.detail.value.generate()`);
  await page.waitForSelector('.chapter', { timeout: 15000 });
  await page.waitForTimeout(300);
  check('no thumbs buttons', !(await page.$('.ai-card .btn-icon')));
  await page.hover('.chapter >> nth=0');
  await page.waitForTimeout(200);
  const overlap = await page.$eval('.chapter', (c) => {
    const s = c.querySelector('.csum').getBoundingClientRect();
    const b = c.querySelector('.expand')?.getBoundingClientRect();
    return b ? b.top < s.bottom - 1 : false;
  });
  check('chapter "展开" never overlaps the text', !overlap);
  await shot('07-detail-summary');

  // title: hover outline, click to edit, click elsewhere saves
  await page.hover('.title-input');
  await page.waitForTimeout(200);
  check('title shows the I-beam', (await page.$eval('.title-input', (e) => getComputedStyle(e).cursor)) === 'text');
  await page.click('.title-input');
  await page.keyboard.press('End');
  await page.keyboard.type('（改）');
  await page.waitForTimeout(100);
  await shot('08-title-editing');
  await page.mouse.click(900, 400);
  await page.waitForTimeout(400);
  check('click elsewhere saves the title', (await ev(`window.__lm.state.detail.value.minute.value.title`)).endsWith('（改）'));
  await ev(`window.__lm.state.detail.value.rightTab.value = 'transcript'`);
  await page.waitForTimeout(200);
  check('transcript sentences use the hand pointer', (await page.$eval('.para-body', (e) => getComputedStyle(e).cursor)) === 'pointer');
  check('back button uses the hand pointer', (await page.$eval('.back-button', (e) => getComputedStyle(e).cursor)) === 'pointer');

  // player menus are dark flip-ups
  await page.mouse.move(300, 400);
  await page.hover('.controls-row .pbtn:has-text("1x")');
  await page.waitForSelector('.menu.dark', { timeout: 2000 });
  await page.waitForTimeout(350);
  await shot('09-rate-menu');
  await page.mouse.move(900, 600);
  await page.waitForTimeout(400);

  // settings: language switch to English, then Japanese and Russian
  await page.click('.back-button');
  await page.waitForSelector('.list-page');
  await ev(`window.__lm.state.settingsOpen.value = 'general'`);
  await page.waitForSelector('.settings');
  await page.waitForTimeout(300);
  await shot('10-settings-general');
  await page.click('.set-row .select-field');
  await page.click('.menu-item:has-text("English")');
  await page.waitForTimeout(300);
  check('switching language updates the UI at once', (await page.textContent('.settings-head h2')) === 'Settings');
  await shot('11-settings-en');
  await page.keyboard.press('Escape');
  await page.waitForTimeout(200);
  check('English sidebar', (await page.textContent('.sidebar-head')).includes('Bacon Minutes'));
  await shot('12-list-en');
  await ev(`window.__lm.state.setUILanguage('ja')`);
  await page.waitForTimeout(200);
  await shot('13-list-ja');
  await ev(`window.__lm.state.setUILanguage('ru')`);
  await page.click('.row >> nth=0');
  await page.waitForSelector('.detail');
  await page.waitForTimeout(900);
  await shot('14-detail-ru');

  console.log(results.join('\n'));
  console.log('console errors:', errors.slice(0, 10));
  await app.close();
})().catch((e) => {
  console.log(results.join('\n'));
  console.error('FAILED', e);
  process.exit(1);
});
