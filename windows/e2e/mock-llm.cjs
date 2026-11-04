const http = require('http');
const calls = [];
const summary = {
  overview: '本次会议讨论了第一季度预算、项目排期与测试资源安排，并确认了上线前的风险与分工。',
  key_points: [
    { title: '预算分配', content: '人力成本在第一季度预算中占比最高，需要在试点阶段控制投入。' },
    { title: '排期调整', content: '客户关心交付时间，排期表将更新到共享文档，必要时再调整。' },
    { title: '风险控制', content: '主要风险在第三方接口，需要提前准备测试资源与回退方案。' },
    { title: '数据看板', content: '数据看板需要新增两个指标，用于跟踪 API 调用量变化。' },
  ],
  todos: [
    { content: '下周前把方案发给大家', owner: '说话人 1', time: '00:03:10' },
    { content: '更新共享文档中的排期表', owner: '未指定', time: '00:41:02' },
  ],
  chapters: [
    { time: '00:00:55', title: '开场与第一季度预算回顾', summary: '会议开始后先回顾了第一季度预算的整体情况，确认人力成本占比最高，并讨论了是否先做小范围试点来控制投入。' },
    { time: '00:18:20', title: '项目排期与交付时间', summary: '围绕客户关心的交付时间讨论排期，认为需要再确认上线时间，排期表会同步到共享文档中。' },
    { time: '00:45:00', title: '测试资源与第三方接口风险', summary: '讨论了测试资源安排，指出第三方接口是主要风险点，需要提前准备方案。' },
    { time: '01:10:30', title: '数据看板与后续分工', summary: '确定数据看板新增两个指标，并明确后续由张三负责跟进相关事项。' },
  ],
  keywords: ['预算', '排期', '测试资源', '第三方接口', '数据看板', '上线时间', '不存在的词'],
};
http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const json = body ? JSON.parse(body) : {};
    calls.push({ url: req.url, hasRF: !!json.response_format });
    res.setHeader('content-type', 'application/json');
    if (req.url === '/calls') return res.end(JSON.stringify(calls));
    if (req.url.endsWith('/models')) return res.end(JSON.stringify({ data: [{ id: 'mock-large' }, { id: 'mock-small' }] }));
    if (json.response_format) {
      res.statusCode = 400;
      return res.end(JSON.stringify({ error: { message: "Unsupported parameter: 'response_format'" } }));
    }
    const isTest = (json.messages || []).some((m) => m.content === 'Reply with OK.');
    setTimeout(() => {
      res.end(JSON.stringify({ choices: [{ message: { content: isTest ? 'OK' : '<think>先想一想</think>' + JSON.stringify(summary) }, finish_reason: 'stop' }] }));
    }, isTest ? 50 : 1500);
  });
}).listen(18765, '127.0.0.1', () => console.log('mock llm on 18765'));
