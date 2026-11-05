// Round 7: straight-line marquee, import review (copy vs link), storage labels, missing media
// with 重新检测路径, an unreachable share that must not freeze the app, import into the app,
// delete wording, deleting folders with their minutes, background summaries, starred models,
// summary versions and .baconsummary export/import.
const { _electron } = require('playwright');
const path = require('path');
const fs = require('fs');
const { execFileSync } = require('child_process');
const APP = path.resolve(__dirname, '..');
const WORK = path.join(__dirname, '.work');
const OUT = path.join(WORK, 'round7');
const DATA = path.join(WORK, 'userdata-round7');
const SRC = path.join(WORK, 'r7', 'IB Physics');
const SRC2 = path.join(WORK, 'r7', 'linked');
const HANG = path.join(WORK, 'r7', 'nas');
const SAVED = path.join(OUT, 'saved');
for (const d of [OUT, DATA, path.join(WORK, 'r7')]) fs.rmSync(d, { recursive: true, force: true });
for (const d of [OUT, SRC, SRC2, HANG, SAVED]) fs.mkdirSync(d, { recursive: true });

const results = [];
const check = (name, ok, detail = '') => results.push(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ' — ' + detail : ''}`);

function video(file, seconds, color) {
  execFileSync('ffmpeg', ['-loglevel', 'error', '-y', '-f', 'lavfi', '-i', `testsrc2=size=320x180:rate=10,hue=h=${color}`, '-f', 'lavfi', '-i', 'sine=frequency=330:sample_rate=22050',
    '-t', String(seconds), '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '24k', '-movflags', '+faststart', file]);
}
const srt = (file, seconds, count, tag) => execFileSync('python3', [path.join(__dirname, 'gen_srt.py'), file, String(seconds), String(count)]) && tag;

video(path.join(SRC, 'Lecture 1 Kinematics.mp4'), 40, 0);
srt(path.join(SRC, 'Lecture 1 Kinematics.srt'), 40, 12);
video(path.join(SRC, 'Lecture 2 Dynamics.mp4'), 30, 120);
srt(path.join(SRC, '第二讲字幕.srt'), 30, 10);
fs.writeFileSync(path.join(SRC, 'Lecture 1 raw.mkv'), 'not really a video');
fs.writeFileSync(path.join(SRC, 'Lecture 1.ass'), '[Script Info]');
video(path.join(SRC2, 'Seminar.mp4'), 25, 240);
srt(path.join(SRC2, 'Seminar.srt'), 25, 8);
fs.copyFileSync(path.join(SRC2, 'Seminar.mp4'), path.join(HANG, 'lost.mp4'));

(async () => {
  const app = await _electron.launch({
    executablePath: path.join(APP, 'node_modules/electron/dist/electron'),
    args: ['--no-sandbox', path.join(APP, 'dist/main.cjs')],
    env: { ...process.env, LOCALMINUTES_E2E: '1', LOCALMINUTES_USER_DATA: DATA, LOCALMINUTES_LANG: 'zh-CN', BACON_TEST_HANG_DIR: HANG, BACON_E2E_SAVE_DIR: SAVED, NODE_OPTIONS: '' },
  });
  const page = await app.firstWindow();
  const errors = [];
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  page.on('pageerror', (e) => errors.push(`[pageerror] ${e.message}`));
  const ev = (e) => page.evaluate(e);
  const shot = (n) => page.screenshot({ path: `${OUT}/${n}.png` });
  const toast = () => page.$eval('.toast', (e) => e.innerText).catch(() => '');
  const minuteBy = (title) => ev(`window.__lm.state.minutes.value.find((m) => m.title.includes(${JSON.stringify(title)}))`);
  const waitIdle = () => page.waitForFunction(() => !window.__lm.state.confirmRequest.value && !document.querySelector('.flip-backdrop'), null, { timeout: 5000 });
  await page.waitForSelector('.list-page', { timeout: 15000 });

  // ---------- 1. straight vertical drag in the folder sidebar ----------
  for (const name of ['甲', '乙', '丙']) {
    await page.click('.sidebar-plus');
    await page.waitForSelector('.folder-input');
    await page.keyboard.type(name);
    await page.keyboard.press('Enter');
    await page.waitForTimeout(150);
  }
  const area = await page.locator('.folders-scroll').boundingBox();
  const rowsBox = await page.$$eval('.folder-row', (els) => els.map((e) => e.getBoundingClientRect()).map((r) => ({ y: r.y, h: r.height })));
  const x = area.x + area.width - 30;
  await page.mouse.move(x, rowsBox[2].y + rowsBox[2].h + 30);
  await page.mouse.down();
  await page.mouse.move(x, rowsBox[1].y + 6, { steps: 8 });
  const box = await page.$eval('.marquee', (e) => ({ w: e.getBoundingClientRect().width, h: e.getBoundingClientRect().height })).catch(() => null);
  const live = await page.$$eval('.folder-row.batch .folder-name', (els) => els.map((e) => e.textContent));
  await shot('01-vertical-marquee');
  check('a straight vertical drag draws a visible box', !!box && box.w >= 2 && box.h > 20, JSON.stringify(box));
  check('…and selects the folders it crosses', live.length === 2 && live.includes('乙') && live.includes('丙'), JSON.stringify(live));
  await page.mouse.up();
  // a straight horizontal drag in the empty space below the folders
  await page.mouse.click(area.x + 10, area.y + area.height - 10);
  const y = rowsBox[2].y + rowsBox[2].h + 24;
  await page.mouse.move(area.x + area.width - 10, y);
  await page.mouse.down();
  await page.mouse.move(area.x + 30, y, { steps: 6 });
  const hbox = await page.$eval('.marquee', (e) => e.getBoundingClientRect().height).catch(() => 0);
  await page.mouse.up();
  await page.waitForTimeout(100);
  check('a straight horizontal drag draws a visible (≥ 2 px) box too', hbox >= 2, `h=${hbox}`);
  await page.keyboard.press('Escape');
  await ev(`window.__lm.state.section.value = 'all'`);

  // ---------- 2. import review dialog ----------
  await ev(`window.__lm.importPaths([${JSON.stringify(SRC)}])`);
  await page.waitForSelector('.review-row', { timeout: 10000 });
  await page.waitForFunction(() => window.__lm.state.importReview.value?.rows.value.every((r) => r.inspected), null, { timeout: 30000 });
  await page.waitForTimeout(400);
  await shot('02-import-review');
  const rows = await page.$$eval('.review-row', (els) => els.map((e) => ({ name: e.querySelector('.rr-name').textContent, sub: e.querySelector('.rr-pick-text').textContent, guessed: !!e.querySelector('.rr-guess'), img: !!e.querySelector('.rr-thumb img'), meta: e.querySelector('.rr-meta').textContent })));
  check('one row per video, paired by name', rows.length === 2 && rows[0].name.includes('Lecture 1') && rows[0].sub === 'Lecture 1 Kinematics.srt', JSON.stringify(rows));
  check('the only other SRT is suggested for the second video and marked as a guess', rows[1].sub === '第二讲字幕.srt' && rows[1].guessed);
  check('thumbnails, duration and size in each row', rows.every((r) => r.img && /秒/.test(r.meta) && /(KB|MB)/.test(r.meta)), rows.map((r) => r.meta).join(' | '));
  const notes = await page.$$eval('.review-note', (els) => els.map((e) => e.textContent).join(' | '));
  check('unsupported files are listed as skipped', notes.includes('已跳过 2 个不支持的文件') && notes.includes('raw.mkv'), notes);
  check('default: copy into the app, with the total size', (await page.textContent('.review-storage')).includes('默认把源文件复制一份保存到应用内（共'));
  await page.click('.review-storage .rs-check');
  await page.waitForTimeout(200);
  check('link option shows the warning about moved files', (await page.textContent('.rs-warn')).includes('重新检测路径'));
  await shot('03-import-review-link');
  await page.click('.review-storage .rs-check');
  await page.click('.review-row:nth-child(2) .rr-pick');
  await page.waitForSelector('.menu');
  await page.waitForTimeout(300);
  await shot('04-subtitle-picker');
  await page.click('.menu-item:has-text("第二讲字幕.srt")');
  await page.waitForTimeout(150);
  check('picking a subtitle clears the guess mark', !(await page.$('.rr-guess')));
  await page.click('.review-foot .btn-primary');
  await page.waitForFunction(() => document.querySelectorAll('.row').length === 2, null, { timeout: 30000 });
  await page.waitForTimeout(300);
  check('both imported', (await toast()).includes('已导入 2 个妙记'), await toast());
  const l1 = await minuteBy('Lecture 1');
  const copy = path.join(DATA, 'minutes', l1.id, 'media', 'Lecture 1 Kinematics.mp4');
  check('copied into the app by default', l1.storage === 'imported' && fs.existsSync(copy) && l1.mediaPath === copy, l1.mediaPath);
  check('list rows say 应用内', (await page.textContent('.row:has-text("Lecture 1") .row-sub')).includes('应用内'));

  // ---------- 3. linked import, then the file moves away and back ----------
  await ev(`window.__lm.importPaths([${JSON.stringify(path.join(SRC2, 'Seminar.mp4'))}, ${JSON.stringify(path.join(SRC2, 'Seminar.srt'))}])`);
  await page.waitForSelector('.review-row', { timeout: 10000 });
  await page.waitForFunction(() => window.__lm.state.importReview.value?.rows.value.every((r) => r.inspected), null, { timeout: 30000 });
  await page.click('.review-storage .rs-check');
  await page.click('.review-foot .btn-primary');
  await page.waitForFunction(() => document.querySelectorAll('.row').length === 3, null, { timeout: 30000 });
  const sem = await minuteBy('Seminar');
  check('link-only import keeps the original path', sem.storage === 'linked' && sem.mediaPath === path.join(SRC2, 'Seminar.mp4'));
  check('linked rows say 链接', (await page.textContent('.row:has-text("Seminar") .row-sub')).includes('链接'));
  await shot('05-list-storage-labels');

  fs.renameSync(path.join(SRC2, 'Seminar.mp4'), path.join(SRC2, 'Seminar (moved).mp4'));
  await page.click('.row:has-text("Seminar")');
  await page.waitForSelector('.player-msg.missing', { timeout: 10000 });
  await page.waitForTimeout(300);
  check('moved file: 原路径已找不到文件 with the old path', (await page.textContent('.player-msg .title')) === '原路径已找不到文件' && (await page.textContent('.player-msg .path .value')).includes('Seminar.mp4'));
  check('the link tag is in the title bar', (await page.textContent('.topbar-title')).includes('链接'));
  await shot('06-missing-linked');
  await page.click('.player-msg .btn-primary');
  await page.waitForFunction(() => window.__lm.state.detail.value.recheckFailed.value, null, { timeout: 8000 });
  check('re-detect while still moved: says it is still not found', (await page.textContent('.player-msg .sub.failed')).includes('仍未找到文件'));
  await shot('07-recheck-still-missing');
  fs.renameSync(path.join(SRC2, 'Seminar (moved).mp4'), path.join(SRC2, 'Seminar.mp4'));
  await page.click('.player-msg .btn-primary');
  await page.waitForFunction(() => window.__lm.state.detail.value.mediaState.value === 'ready', null, { timeout: 10000 });
  check('moved back + 重新检测路径: plays again', true);
  check('toast 已重新找到源文件', (await toast()).includes('已重新找到源文件'));
  await page.waitForTimeout(500);
  await shot('08-recheck-found');

  // the link tag menu
  await page.click('.storage-badge');
  await page.waitForSelector('.menu');
  await page.waitForTimeout(300);
  const tagMenu = await page.textContent('.menu');
  check('link tag menu shows the path and 将源文件导入应用', tagMenu.includes('Seminar.mp4') && tagMenu.includes('将源文件导入应用'));
  await shot('09-link-tag-menu');
  await page.keyboard.press('Escape');
  await ev('window.__lm.state.goBack()');
  await page.waitForTimeout(300);

  // ---------- 4. a NAS that went away must not freeze anything ----------
  const created = await ev(`window.__lm.state.call('lib:create', { mediaPath: ${JSON.stringify(path.join(SRC2, 'Seminar.mp4'))}, title: 'NAS 录制', duration: 25, isAudioOnly: false, storage: 'linked' }, null)`);
  const nas = await ev(`window.__lm.state.call('lib:patch', ${JSON.stringify(created.id)}, { mediaPath: ${JSON.stringify(path.join(HANG, 'lost.mp4'))}, mediaFileName: 'lost.mp4' })`);
  await ev(`window.__lm.state.upsertMinute(${JSON.stringify(nas)})`);
  await page.waitForTimeout(200);
  const t0 = Date.now();
  await page.click('.row:has-text("NAS 录制")');
  await page.waitForSelector('.topbar', { timeout: 3000 });
  const opened = Date.now() - t0;
  // While the check is stuck, the window and the main process keep answering.
  const r0 = Date.now();
  await ev(`window.__lm.state.call('lib:list').then((l) => l.length)`);
  const ipc = Date.now() - r0;
  await page.click('.tab:has-text("文字记录"), .underline-tab:has-text("文字记录")').catch(() => {});
  await page.waitForFunction(() => window.__lm.state.detail.value?.mediaState.value === 'unreachable', null, { timeout: 8000 });
  const settled = Date.now() - t0;
  check('opening a minute on an unreachable share shows the page at once', opened < 1500, `${opened} ms`);
  check('the main process keeps answering meanwhile', ipc < 500, `${ipc} ms`);
  check('after the time limit it says the location is unreachable', settled < 7000 && (await page.textContent('.player-msg .title')) === '无法访问源文件所在位置', `${settled} ms`);
  await shot('10-unreachable');
  await page.click('.player-msg .btn-primary');
  const r1 = Date.now();
  await ev('1 + 1');
  const pong = Date.now() - r1;
  await page.waitForFunction(() => window.__lm.state.detail.value.recheckFailed.value, null, { timeout: 8000 });
  check('re-detect on the dead share: UI stays responsive, then says still unreachable', pong < 300 && (await page.textContent('.player-msg .sub.failed')).includes('仍然无法访问'), `${pong} ms`);
  await ev('window.__lm.state.goBack()');
  await page.waitForTimeout(200);
  const t1 = Date.now();
  await page.click('.row:has-text("NAS 录制")');
  await page.waitForFunction(() => window.__lm.state.detail.value?.mediaState.value === 'unreachable', null, { timeout: 8000 });
  check('reopening while the share is still stuck answers at once', Date.now() - t1 < 1500, `${Date.now() - t1} ms`);
  await ev('window.__lm.state.goBack()');
  await page.waitForTimeout(200);

  // ---------- 5. import a linked minute into the app ----------
  await page.click('.row:has-text("Seminar") .col-ops .btn-icon');
  await page.waitForSelector('.menu');
  await page.click('.menu-item:has-text("将源文件导入应用")');
  await page.waitForSelector('.flip-card');
  await page.waitForTimeout(450);
  check('import-into-app asks first, with a blue (non-destructive) button', !!(await page.$('.confirm-mark.info')) && !!(await page.$('.flip-card .btn-primary')) && (await page.textContent('.confirm-emphasis')).includes('不能再改回链接路径'));
  await shot('11-import-into-app-confirm');
  await page.click('.flip-card .btn-primary');
  await page.waitForFunction(() => window.__lm.state.minutes.value.find((m) => m.title.includes('Seminar'))?.storage === 'imported', null, { timeout: 15000 });
  const sem2 = await minuteBy('Seminar');
  check('copied into the app; the label changes to 应用内', fs.existsSync(path.join(DATA, 'minutes', sem2.id, 'media', 'Seminar.mp4')) && (await page.textContent('.row:has-text("Seminar") .row-sub')).includes('应用内'));
  check('the original file is left alone', fs.existsSync(path.join(SRC2, 'Seminar.mp4')));
  await waitIdle().catch(() => {});

  // ---------- 6. delete wording follows where the media lives ----------
  await ev(`window.__lm.state.requestMoveToTrash([${JSON.stringify(sem2.id)}])`);
  await page.waitForSelector('.confirm-emphasis');
  check('trash: in-app media is deleted with the minute later', (await page.textContent('.confirm-emphasis')).includes('在回收站彻底删除时会一起删除'));
  await page.click('.btn-cancel');
  await waitIdle();
  await ev(`window.__lm.state.requestMoveToTrash([${JSON.stringify(sem2.id)}, ${JSON.stringify(nas.id)}])`);
  await page.waitForSelector('.confirm-emphasis');
  check('mixed selection names both cases', /其中 1 个.*另外 1 个只链接了路径/.test(await page.textContent('.confirm-emphasis')));
  await page.waitForTimeout(450);
  await shot('12-trash-mixed');
  await page.click('.btn-cancel');
  await waitIdle();

  // ---------- 7. delete a folder together with its minutes ----------
  const folderID = await ev(`window.__lm.state.folders.value.find((f) => f.name === '甲').id`);
  await ev(`window.__lm.state.moveMinutes([${JSON.stringify(nas.id)}], ${JSON.stringify(folderID)})`);
  await page.waitForTimeout(200);
  await ev(`window.__lm.state.requestDeleteFolder(${JSON.stringify(folderID)})`);
  await page.waitForSelector('.confirm-check');
  await page.click('.confirm-check');
  await page.waitForTimeout(450);
  check('the checkbox turns the button into 下一步', (await page.textContent('.flip-card .btn-danger')).trim() === '下一步');
  await shot('13-delete-folder-checkbox');
  await page.click('.flip-card .btn-danger');
  await page.waitForFunction(() => (window.__lm.state.confirmRequest.value?.title || '').includes('并将其中 1 个妙记移到回收站'), null, { timeout: 5000 });
  await page.waitForTimeout(450);
  check('second step is the delete-minute confirmation', (await page.textContent('.confirm-emphasis')).includes('原始媒体文件不会被删除'));
  await shot('14-delete-folder-second-step');
  await page.click('.flip-card .btn-danger');
  await page.waitForTimeout(800);
  const gone = await ev(`!window.__lm.state.folders.value.some((f) => f.name === '甲') && !!window.__lm.state.minutes.value.find((m) => m.id === ${JSON.stringify(nas.id)}).deletedAt`);
  check('folder deleted and its minute moved to the trash', gone);

  // ---------- 8. summaries keep generating in the background ----------
  await ev(`window.__lm.state.updateLLM({ ...window.__lm.state.llm.value, presetID: 'custom', protocol: 'openAI', baseURL: 'http://127.0.0.1:18765/v1', model: 'mock-slow' })`);
  await page.click('.row:has-text("Lecture 2")');
  await page.waitForSelector('.topbar');
  await ev(`window.__lm.state.detail.value.rightTab.value = 'summary'`);
  await page.waitForSelector('.placeholder .btn-primary, .empty .btn-primary', { timeout: 5000 }).catch(() => {});
  await page.click('button:has-text("生成智能纪要")');
  await page.waitForTimeout(600);
  await ev('window.__lm.state.goBack()');
  await page.waitForSelector('.row:has-text("Lecture 2") .gen-tag', { timeout: 3000 });
  check('back on the list, the row shows 纪要生成中', true);
  await shot('15-generating-in-background');
  await page.waitForFunction(() => (document.querySelector('.toast')?.innerText || '').includes('的智能纪要已生成'), null, { timeout: 15000 });
  check('a toast says the summary is ready', (await toast()).includes('「Lecture 2 Dynamics」的智能纪要已生成'), await toast());
  check('the row now has the 纪要 tag', !(await page.$('.row:has-text("Lecture 2") .gen-tag')) && (await page.textContent('.row:has-text("Lecture 2") .row-title')).includes('纪要'));
  await page.click('.row:has-text("Lecture 2")');
  await page.waitForSelector('.topbar');
  await ev(`window.__lm.state.detail.value.rightTab.value = 'summary'`);
  await page.waitForSelector('.sum-toolbar', { timeout: 5000 });
  check('reopened: the finished summary is there', (await page.textContent('.sum-toolbar')).includes('mock-slow'));

  // ---------- 9. starred models ----------
  await ev(`window.__lm.state.settingsOpen.value = 'api'`);
  await page.waitForSelector('button:has-text("获取模型列表")');
  await page.click('button:has-text("获取模型列表")');
  await page.waitForSelector('.chevron-btn', { timeout: 5000 });
  await page.click('.chevron-btn');
  await page.waitForSelector('.menu .mi-star');
  await page.click('.menu-item:has-text("mock-large") .mi-star');
  await page.waitForTimeout(200);
  check('the star turns on and the menu stays open', !!(await page.$('.menu-item:has-text("mock-large") .mi-star.on')));
  await shot('16-star-in-model-list');
  await page.keyboard.press('Escape');
  await page.waitForTimeout(200);
  check('starred model listed under 收藏的模型', (await page.textContent('.fav-list')).includes('mock-large'));
  await shot('17-favorites-section');
  await page.keyboard.press('Escape');
  await page.waitForTimeout(300);

  // ---------- 10. a second version with the starred model ----------
  await page.click('.model-pick');
  await page.waitForSelector('.menu');
  await page.waitForTimeout(300);
  await shot('18-model-picker');
  await page.click('.menu-item:has-text("mock-large")');
  await page.click('.sum-toolbar button:has-text("重新生成")');
  await page.waitForFunction(() => window.__lm.state.detail.value.summaries.value.length === 2, null, { timeout: 15000 });
  await page.waitForTimeout(400);
  check('two versions, the new one shown', (await page.textContent('.vp-badge')).includes('版本 2/2') && (await page.textContent('.version-pick')).includes('mock-large'));
  await page.click('.version-pick');
  await page.waitForSelector('.menu');
  await page.waitForTimeout(300);
  await shot('19-version-picker');
  await page.click('.menu-item:has-text("mock-slow")');
  await page.waitForTimeout(300);
  check('switching back shows the first version', (await page.textContent('.version-pick')).includes('mock-slow') && (await page.textContent('.vp-badge')).includes('版本 1/2'));
  const persisted = await ev(`window.__lm.state.call('lib:get', window.__lm.state.detail.value.minute.value.id).then((m) => m.activeSummaryID === window.__lm.state.detail.value.summary.value.id)`);
  check('the chosen version is remembered', persisted);

  // ---------- 11. export a summary file ----------
  await page.click('.sum-toolbar .btn-icon');
  await page.waitForSelector('.menu');
  await page.click('.menu-item:has-text("导出纪要文件")');
  await page.waitForTimeout(500);
  const saved = fs.readdirSync(SAVED).find((f) => f.endsWith('.baconsummary'));
  const file = saved && JSON.parse(fs.readFileSync(path.join(SAVED, saved), 'utf8'));
  check('exported .baconsummary with source, model and parameters', !!file && file.format === 'bacon-minutes-summary' && file.generation.model === 'mock-slow' && /^[0-9a-f]{16}$/.test(file.source.cuesHash) && file.source.mediaFileName === 'Lecture 2 Dynamics.mp4' && file.generation.parameters.promptVersion === 2, saved);

  // ---------- 12. import it into another minute: metadata mismatch ----------
  await ev('window.__lm.state.goBack()');
  await page.waitForTimeout(300);
  await page.click('.row:has-text("Lecture 1")');
  await page.waitForSelector('.topbar');
  await ev(`window.__lm.importPaths([${JSON.stringify(path.join(SAVED, saved || 'x'))}])`);
  await page.waitForSelector('.confirm-title', { timeout: 5000 });
  await page.waitForTimeout(450);
  const msg = await page.textContent('.confirm-message');
  check('mismatch dialog lists what differs', (await page.textContent('.confirm-title')).includes('信息不符') && msg.includes('字幕内容不同') && msg.includes('媒体文件不同'), msg.replace(/\n/g, ' / '));
  await shot('20-import-mismatch');
  await page.click('.flip-card .btn-primary');
  await page.waitForFunction(() => window.__lm.state.detail.value.summaries.value.length === 1, null, { timeout: 5000 });
  check('仍要导入 adds it as a version', (await toast()).includes('已导入纪要'));
  await ev('window.__lm.state.goBack()');
  await page.waitForTimeout(300);

  // dropped on the list: goes to the minute it came from, no questions
  await ev(`window.__lm.importPaths([${JSON.stringify(path.join(SAVED, saved || 'x'))}])`);
  await page.waitForFunction(() => (document.querySelector('.toast')?.innerText || '').includes('已将纪要导入'), null, { timeout: 5000 });
  check('on the list, the file finds its own minute by its subtitles', (await toast()).includes('「Lecture 2 Dynamics」'));
  const versions = await ev(`window.__lm.state.call('lib:summaries', ${JSON.stringify((await minuteBy('Lecture 2')).id)}).then((l) => l.length)`);
  check('…as a third version', versions === 3, String(versions));

  // ---------- 13. delete permanently removes the in-app copy ----------
  await ev(`window.__lm.state.moveToTrash([${JSON.stringify(sem2.id)}])`);
  await ev(`window.__lm.state.deleteForever([${JSON.stringify(sem2.id)}])`);
  await page.waitForSelector('.confirm-emphasis');
  check('delete forever: in-app media goes too', (await page.textContent('.confirm-emphasis')).includes('会和妙记一起删除'));
  await page.click('.flip-card .btn-danger');
  await page.waitForTimeout(600);
  check('the copy is gone, the original stays', !fs.existsSync(path.join(DATA, 'minutes', sem2.id)) && fs.existsSync(path.join(SRC2, 'Seminar.mp4')));

  check('no console errors', errors.length === 0, errors.slice(0, 5).join(' | '));
  await app.close();
  console.log(results.join('\n'));
  const failed = results.filter((r) => r.startsWith('FAIL')).length;
  console.log(`${results.length - failed}/${results.length} passed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.log(results.join('\n'));
  console.error('FAILED', e);
  process.exit(1);
});
