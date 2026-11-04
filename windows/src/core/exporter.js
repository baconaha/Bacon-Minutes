import { srtTimestamp, timestamp, createdDate, duration, usesHours } from './time.js';
import { L, listSeparator } from './i18n.js';
import { paragraphText, speakerName } from './paragraphs.js';

export function exportSRT(transcript) {
  return transcript.cues
    .map((c, i) => `${i + 1}\n${srtTimestamp(c.start)} --> ${srtTimestamp(c.end)}\n${speakerName(transcript, c.speakerID)}: ${c.text}\n`)
    .join('\n');
}

export function exportTXT(transcript, paragraphs, insertComma, hours) {
  return paragraphs
    .map((p) => `${speakerName(transcript, p.speakerID)}  ${timestamp(p.start, hours)}\n${paragraphText(p, transcript.cues, insertComma)}\n`)
    .join('\n');
}

export function summaryMarkdown(s, hours, level = 2) {
  const h = '#'.repeat(level);
  let out = `${h} ${L('会议纪要')}\n\n`;
  if (s.overview) out += s.overview + '\n\n';
  for (const kp of s.keyPoints) out += `- **${kp.title}**${L('：')}${kp.content}\n`;
  if (s.keyPoints.length) out += '\n';
  out += `${h}# ${L('待办')}\n\n`;
  if (!s.todos.length) out += L('本场会议无待办内容') + '\n\n';
  else out += s.todos.map((t) => `- [ ] ${t.content} · ${t.owner} · ${timestamp(t.time, hours)}`).join('\n') + '\n\n';
  out += `${h} ${L('章节纪要')}\n\n`;
  for (const c of s.chapters) out += `${h}# ${timestamp(c.time, hours)} ${c.title}\n\n${c.summary}\n\n`;
  if (s.keywords.length) out += `${h} ${L('关键词')}\n\n${s.keywords.join(listSeparator())}\n\n`;
  out += '> ' + L('智能纪要由 AI 生成，请谨慎使用') + '\n';
  return out;
}

export function exportMarkdown({ title, createdAt, duration: totalSeconds, summary, transcript, paragraphs, insertComma }) {
  const hours = usesHours(totalSeconds);
  let out = `# ${title}\n\n${createdDate(createdAt)} · ${duration(totalSeconds)}\n\n`;
  if (summary) out += `## ${L('智能纪要')}\n\n` + summaryMarkdown(summary, hours, 3) + '\n';
  if (transcript) {
    out += `## ${L('文字记录')}\n\n`;
    for (const p of paragraphs) {
      out += `**${speakerName(transcript, p.speakerID)}** \`${timestamp(p.start, hours)}\`\n\n${paragraphText(p, transcript.cues, insertComma)}\n\n`;
    }
  }
  return out;
}
