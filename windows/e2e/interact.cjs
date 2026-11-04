// Stage 2: interactions on the persisted library from stage 1.
const { _electron } = require('playwright');
const path = require('path');
const fs = require('fs');
const APP = path.resolve(__dirname, '..');
const WORK = path.join(__dirname, '.work');
const OUT = path.join(WORK, 'shots');
const DATA = path.join(WORK, 'userdata');
const results = [];
const check = (name, ok, detail = '') => { results.push(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ' — ' + detail : ''}`); };

(async () => {
  const app = await _electron.launch({
    executablePath: path.join(APP, 'node_modules/electron/dist/electron'),
    args: ['--no-sandbox', path.join(APP, 'dist/main.cjs')],
    env: { ...process.env, LOCALMINUTES_E2E: '1', LOCALMINUTES_USER_DATA: DATA, LOCALMINUTES_LANG: 'zh-CN', NODE_OPTIONS: '' },
  });
  const page = await app.firstWindow();
  const errors = [];
  page.on('console', (m) => { if (['error'].includes(m.type())) errors.push(`[${m.type()}] ${m.text()}`); });
  page.on('pageerror', (e) => errors.push(`[pageerror] ${e.message}`));
  await page.waitForSelector('.row', { timeout: 15000 });
  check('library persisted across restart', (await page.$$('.row')).length === 2);

  await page.click('.row:has-text("周会复盘")');
  await page.waitForFunction(() => window.__lm.state.detail.value?.mediaState.value === 'ready', null, { timeout: 15000 });
  await page.waitForTimeout(500);
  const D = 'window.__lm.state.detail.value';
  const ev = (expr) => page.evaluate(expr);

  // --- click a word in the transcript ---
  const target = await page.evaluate(() => {
    const span = document.querySelectorAll('.para')[6].querySelector('.cue');
    span.scrollIntoView({ block: 'center' });
    const id = +span.dataset.c;
    const cue = window.__lm.state.detail.value.transcript.value.cues[id];
    return { id, start: cue.start, end: cue.end, len: cue.text.length };
  });
  await page.waitForTimeout(300);
  const box = await page.locator(`.cue[data-c="${target.id}"]`).boundingBox();
  await page.mouse.click(box.x + 3, box.y + box.height / 2); // first character
  await page.waitForTimeout(700);
  let st = await ev(`(() => { const d = ${D}; return { t: d.video.currentTime, playing: !d.video.paused, cur: document.querySelector('.cue.cur')?.dataset.c, chars: CSS.highlights.get('lm-char')?.size } })()`);
  check('click word seeks to its cue and plays', Math.abs(st.t - target.start) < 1.2 && st.playing && +st.cur === target.id, JSON.stringify({ ...st, cueStart: target.start }));
  await page.screenshot({ path: `${OUT}/04-playing.png` });

  // --- drag selection must not jump ---
  await ev(`${D}.pause()`);
  await page.waitForTimeout(200);
  const before = await ev(`${D}.video.currentTime`);
  const b2 = await page.locator('.para >> nth=8').boundingBox();
  await page.mouse.move(b2.x + 40, b2.y + 40);
  await page.mouse.down();
  await page.mouse.move(b2.x + 200, b2.y + 45, { steps: 5 });
  await page.mouse.up();
  await page.waitForTimeout(300);
  const after = await ev(`({ t: ${D}.video.currentTime, sel: getSelection().toString() })`);
  check('drag-select keeps position and selects text', Math.abs(after.t - before) < 0.05 && after.sel.length > 2, JSON.stringify(after).slice(0, 80));

  // --- search ---
  await page.click('.tx-search input');
  await page.keyboard.type('预算');
  await page.waitForTimeout(500);
  st = await ev(`({ hits: ${D}.hits.value.length, count: document.querySelector('.tx-search .count')?.innerText, hl: CSS.highlights.get('lm-hit').size + CSS.highlights.get('lm-hit-cur').size, markers: document.querySelectorAll('.progress .marker').length })`);
  check('search highlights every hit and shows n/m', st.hits > 10 && st.hl === st.hits && st.count === `1/${st.hits}`, JSON.stringify(st));
  await page.keyboard.press('Enter');
  await page.waitForTimeout(500);
  st = await ev(`({ idx: ${D}.hitIndex.value, t: ${D}.video.currentTime, hitTime: ${D}.hits.value[1].time, paused: ${D}.video.paused })`);
  check('Enter moves to next hit and seeks video without playing', st.idx === 1 && Math.abs(st.t - st.hitTime) < 0.5 && st.paused, JSON.stringify(st));
  await page.keyboard.press('Shift+Enter');
  await page.waitForTimeout(300);
  check('Shift+Enter goes back', (await ev(`${D}.hitIndex.value`)) === 0);
  await page.mouse.move(900, 400);
  await page.screenshot({ path: `${OUT}/05-search.png` });
  await page.keyboard.press('Escape');
  await page.waitForTimeout(200);
  check('Esc clears search', (await ev(`${D}.searchQuery.value`)) === '' && (await ev(`CSS.highlights.get('lm-hit').size`)) === 0);

  // --- follow + manual scroll ---
  await page.click('.cue[data-c="300"]', { force: true }).catch(async () => { await ev(`${D}.jumpToCue(300, null)`); });
  await page.waitForTimeout(800);
  const followTop = await ev(`(() => { const s = document.querySelector('.tx-scroll'); const el = document.querySelector('.cue.cur'); return (el.getBoundingClientRect().top - s.getBoundingClientRect().top) / s.clientHeight })()`);
  check('current cue kept about 1/3 from the top', followTop > 0.2 && followTop < 0.45, followTop.toFixed(2));
  await page.mouse.move(1000, 500);
  await page.mouse.wheel(0, -3000);
  await page.waitForTimeout(600);
  st = await ev(`({ following: ${D}.following.value, btn: !!document.querySelector('.back-btn'), above: ${D}.cueAbove.value })`);
  check('manual scroll stops following and shows back button (pointing down)', !st.following && st.btn && st.above === false, JSON.stringify(st));
  await page.screenshot({ path: `${OUT}/06-backbtn.png` });
  await page.click('.back-btn');
  await page.waitForTimeout(800);
  check('back button resumes following', (await ev(`${D}.following.value`)) === true && !(await page.$('.back-btn')));
  await ev(`${D}.pause()`);

  // --- keyboard shortcuts ---
  await page.click('.speaker-pct'); // focus something non-editable
  const t1 = await ev(`${D}.video.currentTime`);
  await page.keyboard.press('ArrowRight');
  await page.waitForTimeout(300);
  const t2 = await ev(`${D}.video.currentTime`);
  check('→ skips 15 s', Math.abs(t2 - t1 - 15) < 0.5, `${t1.toFixed(1)} → ${t2.toFixed(1)}`);
  await page.keyboard.press('Space');
  await page.waitForTimeout(400);
  check('Space plays', (await ev(`!${D}.video.paused`)) === true);
  await page.keyboard.press('Space');

  // --- skip blank: leading gap 0–55 s ---
  await ev(`window.__lm.state.updateGeneral({ skipBlankEnabled: true })`);
  await ev(`${D}.seek(10)`);
  await page.waitForTimeout(400);
  await ev(`${D}.play()`);
  await page.waitForTimeout(1200);
  const tb = await ev(`${D}.video.currentTime`);
  check('skip blank jumps the 55 s leading gap', tb >= 54.9 && tb < 60, tb.toFixed(2));
  await ev(`${D}.pause()`);
  await ev(`window.__lm.state.updateGeneral({ skipBlankEnabled: false })`);

  // --- CC ---
  await ev(`window.__lm.state.updateGeneral({ ccEnabled: true })`);
  await ev(`${D}.jumpToCue(10, null)`);
  await page.waitForTimeout(600);
  await ev(`${D}.pause()`);
  const cc = await ev(`document.querySelector('.cc span')?.innerText`);
  const cue10 = await ev(`${D}.transcript.value.cues[10].text`);
  check('CC shows current cue without speaker prefix', cc === cue10, cc);
  await page.mouse.move(300, 300);
  await page.screenshot({ path: `${OUT}/07-cc.png` });
  await ev(`window.__lm.state.updateGeneral({ ccEnabled: false })`);

  // --- rate menu ---
  await page.mouse.move(300, 300);
  await page.click('.controls-row .pbtn:has-text("1x")');
  await page.click('.menu-item:has-text("1.5x")');
  check('rate 1.5x applied', (await ev(`${D}.video.playbackRate`)) === 1.5);
  await page.waitForTimeout(200);
  await page.click('.controls-row .pbtn:has-text("1.5x")');
  await page.click('.menu-item >> text="1x"');
  await page.mouse.move(300, 300);

  // --- AI summary with mock server ---
  await ev(`window.__lm.state.updateLLM({ ...window.__lm.state.llm.value, presetID: 'custom', protocol: 'openAI', baseURL: 'http://127.0.0.1:18765/v1', model: 'mock-large' })`);
  await page.click('.underline-tab:has-text("智能纪要")');
  await page.waitForTimeout(200);
  await page.screenshot({ path: `${OUT}/08-summary-ready.png` });
  await page.click('button:has-text("生成智能纪要")');
  await page.waitForTimeout(500);
  check('generating state shown', !!(await page.$('.generating')));
  await page.screenshot({ path: `${OUT}/09-generating.png` });
  await page.waitForSelector('.ai-card .ctitle', { timeout: 20000 });
  await page.waitForTimeout(300);
  st = await ev(`(() => { const s = ${D}.summary.value; return { chapters: s.chapters.map(c => c.time), first: ${D}.paragraphs.value[0].start, keywords: s.keywords, segs: document.querySelectorAll('.progress .seg').length, todos: s.todos.length } })()`);
  check('summary rendered; first chapter = first paragraph; unknown keyword dropped', st.chapters[0] === st.first && !st.keywords.includes('不存在的词') && st.keywords.length === 6, JSON.stringify(st));
  check('progress bar split into one segment per chapter', st.segs === 4, `segments=${st.segs}`);
  const calls = JSON.parse(await (await fetch('http://127.0.0.1:18765/calls')).text());
  const chat = calls.filter((c) => c.url.endsWith('/chat/completions'));
  check('HTTP 400 on response_format is retried without it', chat.length === 2 && chat[0].hasRF && !chat[1].hasRF, JSON.stringify(chat));
  await page.screenshot({ path: `${OUT}/10-summary.png` });

  // chapter click jumps and plays
  await page.click('.chapter >> nth=2 >> .ctitle');
  await page.waitForTimeout(600);
  st = await ev(`({ t: ${D}.video.currentTime, ch: ${D}.summary.value.chapters[2].time, playing: !${D}.video.paused })`);
  check('chapter title jumps and plays', Math.abs(st.t - st.ch) < 1.5 && st.playing, JSON.stringify(st));
  await ev(`${D}.pause()`);

  // hover preview over progress bar
  const pb = await page.locator('.progress').boundingBox();
  await page.mouse.move(pb.x + pb.width * 0.4, pb.y + 8);
  await page.waitForTimeout(1500);
  await page.mouse.move(pb.x + pb.width * 0.4 + 1, pb.y + 8);
  await page.waitForTimeout(400);
  st = await ev(`({ card: !!document.querySelector('.preview-card'), img: !!document.querySelector('.preview-card img'), chapter: document.querySelector('.preview-card .chapter')?.innerText })`);
  check('hover preview shows frame and chapter title', st.card && st.img && !!st.chapter, JSON.stringify(st));
  await page.screenshot({ path: `${OUT}/11-hover.png` });

  // keyword suggestions
  await page.click('.underline-tab:has-text("文字记录")');
  await page.click('.tx-search input');
  await page.waitForTimeout(200);
  check('keyword suggestions pop on focus', !!(await page.$('.keywords-pop')));
  await page.screenshot({ path: `${OUT}/12-keywords.png` });
  await page.click('.chip:has-text("排期")');
  await page.waitForTimeout(300);
  check('keyword chip searches', (await ev(`${D}.searchQuery.value`)) === '排期' && (await ev(`${D}.hits.value.length`)) > 0);
  await page.keyboard.press('Escape');

  // rename speaker -> transcript + stale banner
  await page.click('.speaker-name >> nth=0');
  await page.waitForSelector('.speaker-head input:focus');
  await page.keyboard.press('Control+a');
  await page.keyboard.type('王经理');
  await page.keyboard.press('Enter');
  await page.waitForTimeout(500);
  st = await ev(`({ names: [...document.querySelectorAll('.para-head .name')].slice(0, 3).map(e => e.innerText), stale: ${D}.stale.value })`);
  check('speaker rename updates transcript and marks summary stale', st.names.includes('王经理') && st.stale, JSON.stringify(st));
  await page.click('.underline-tab:has-text("智能纪要")');
  await page.waitForTimeout(200);
  check('stale banner shown', !!(await page.$('.banner')));
  await page.screenshot({ path: `${OUT}/13-stale.png` });

  // file info tab
  await page.click('.underline-tab:has-text("文件信息")');
  await page.waitForTimeout(200);
  await page.screenshot({ path: `${OUT}/14-fileinfo.png` });

  // back to list via Ctrl+[
  await page.click('.speaker-pct').catch(() => {});
  await page.mouse.click(640, 30);
  await page.keyboard.press('Control+BracketLeft');
  await page.waitForSelector('.list-page');
  await page.waitForTimeout(300);
  check('Ctrl+[ returns to list; 纪要 tag on row', !!(await page.$('.row:has-text("周会复盘") .tag')));

  // full-text search in list
  await page.fill('.searchbox input', '第三方接口');
  await page.waitForTimeout(700);
  check('list search matches transcript text', (await page.$$('.row')).length >= 1);
  await page.fill('.searchbox input', '');
  await page.waitForTimeout(300);

  // trash + restore
  await page.hover('.row:has-text("访谈录音")');
  await page.click('.row:has-text("访谈录音") .checkbox');
  await page.keyboard.press('Delete');
  await page.waitForSelector('.flip-card');
  check('Delete asks first, with the bold media note', (await page.textContent('.confirm-emphasis')).includes('原始媒体文件不会被删除'));
  await page.click('.btn-danger');
  await page.waitForTimeout(500);
  check('Delete moves selection to trash', (await page.$$('.row')).length === 1);
  await page.click('.nav-item:has-text("回收站")');
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${OUT}/15-trash.png` });
  await page.click('.row:has-text("访谈录音") .btn-link:has-text("恢复")');
  await page.waitForTimeout(300);
  await page.click('.nav-item:has-text("全部")');
  check('restore brings it back', (await page.$$('.row')).length === 2);

  // audio minute
  await page.click('.row:has-text("访谈录音")');
  await page.waitForFunction(() => window.__lm.state.detail.value?.mediaState.value === 'ready', null, { timeout: 15000 });
  await page.waitForTimeout(400);
  check('audio-only shows cover', !!(await page.$('.audio-cover')));
  await page.screenshot({ path: `${OUT}/16-audio.png` });

  // settings
  await page.keyboard.press('Control+Comma');
  await page.waitForSelector('.settings');
  await page.waitForTimeout(200);
  await page.click('button:has-text("测试连接")');
  await page.waitForTimeout(800);
  check('test connection succeeds', (await page.innerText('.settings')).includes('连接成功'));
  await page.click('button:has-text("获取模型列表")');
  await page.waitForTimeout(800);
  check('model list fetched', (await page.innerText('.settings')).includes('获取到 2 个模型'));
  await page.screenshot({ path: `${OUT}/17-settings.png` });
  await page.keyboard.press('Escape');

  // remember position of the video minute
  await page.keyboard.press('Control+BracketLeft');
  await page.waitForSelector('.list-page');
  const pos = await page.evaluate(() => window.__lm.state.minutes.value.find((m) => m.title === '周会复盘').lastPlaybackPosition);
  check('playback position saved', pos > 60, pos.toFixed(1));

  console.log(results.join('\n'));
  console.log('console errors:', errors.slice(0, 10));
  await app.close();
})().catch((e) => { console.log(results.join('\n')); console.error('FAILED', e); process.exit(1); });
