// .baconsummary import: reading files, matching them to minutes and asking when the metadata
// does not fit. The format itself is in core/summaryFile.js (same JSON as the Mac app).
import { call, minutes, detail, confirmRequest, showToast, alertError, addSummary, uuid } from './state.js';
import { decodeSummaryFile, summaryFileMismatches, summaryFromFile, mismatchText } from '../core/summaryFile.js';
import { baseName } from '../core/pairing.js';
import { L } from '../core/i18n.js';

export const APP_IDENTITY = 'Bacon Minutes 1.0.0 (Windows)';

export async function readSummaryFile(path) {
  return decodeSummaryFile(await call('fs:readText', path));
}

/** Checks the file's recording and subtitle details against the minute; asks when they differ. */
export async function confirmAndImportSummary(file, minuteID) {
  const m = minutes.value.find((x) => x.id === minuteID);
  if (!m) return;
  const open = detail.value?.minute.value.id === minuteID;
  const transcript = open ? detail.value.transcript.value : await call('lib:transcript', minuteID);
  const problems = summaryFileMismatches(file, m, transcript);
  const apply = async () => {
    await addSummary(minuteID, summaryFromFile(file, uuid()));
    showToast(open ? L('已导入纪要') : L('已将纪要导入「{0}」', m.title));
  };
  if (!problems.length) return apply();
  confirmRequest.value = {
    title: L('纪要文件与「{0}」的信息不符', m.title),
    message: problems.map((p) => '· ' + mismatchText(p)).join('\n'),
    emphasis: L('这份纪要可能不是根据这个妙记生成的。仍要导入吗？'),
    confirmTitle: L('仍要导入'),
    destructive: false,
    onConfirm: apply,
  };
}

/** Summary files dropped on the list: each goes to the minute it was made for. */
export async function importSummaryFilePaths(paths) {
  if (detail.value && paths.length) return detail.value.importSummaryFile(paths[0]);
  for (const path of paths) {
    let file;
    try {
      file = await readSummaryFile(path);
    } catch (e) {
      await alertError(L('无法导入纪要'), L('{0}：{1}', baseName(path), e.message));
      continue;
    }
    const src = file.source;
    const m = await call('lib:findBySummary', { cuesHash: src.cuesHash, cueCount: src.cueCount, mediaFileName: src.mediaFileName });
    if (m) await confirmAndImportSummary(file, m.id);
    else await call('dialog:alert', { title: L('没有找到对应的妙记'), message: L('「{0}」不属于资料库里的任何妙记。请打开要导入的妙记，再把纪要文件拖到妙记页面里。', baseName(path)) });
  }
}
