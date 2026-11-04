import random, sys
random.seed(7)
out, total, n = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
phrases = ["我们先看一下第一季度的预算", "这个排期可能需要再调整", "好", "OK，对", "嗯", "下周前把方案发给大家",
           "客户那边对交付时间比较关心", "我觉得可以先做一个小范围试点", "预算里面人力成本占了大头",
           "那测试资源怎么安排", "回去把这几道题做了", "API 的调用量上个月涨了不少", "这块由张三负责跟进",
           "我们再确认一下上线时间", "数据看板需要加两个指标", "对，就是这个意思", "那就这么定了",
           "我补充一点", "风险主要在第三方接口", "排期表我会更新到共享文档里"]
def ts(t):
    ms = int(round(t*1000)); h=ms//3600000; m=(ms%3600000)//60000; s=(ms%60000)//1000
    return f"{h:02d}:{m:02d}:{s:02d},{ms%1000:03d}"
t = 55.0
lines = []
step = (total - 60) / n
sp = 1
for i in range(n):
    if random.random() < 0.35: sp = 2 if sp == 1 else 1
    text = random.choice(phrases)
    dur = max(0.04, step * random.uniform(0.6, 1.1)) if text not in ("好", "嗯") else random.choice([0.04, 0.3, 0.6])
    start = t - (0.3 if random.random() < 0.02 and i else 0)   # occasional overlap
    lines.append(f"{i+1}\n{ts(start)} --> {ts(start+dur)}\n说话人 {sp}: {text}\n")
    t += step * random.uniform(0.85, 1.15)
    if random.random() < 0.01: t += 6  # occasional long gap
open(out, "w", encoding="utf-8").write("\n".join(lines))
print("cues", n, "last", ts(t))
