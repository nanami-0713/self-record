# 练时 LiftTime（安卓/iOS PWA）功能全景分析 —— iOS 原生版参考

> 分析对象：`reference/lifttime/`（v1.6.0，零依赖纯 ES Modules PWA，数据全在 localStorage）。
> 分析方法：通读 `README.md`、`js/` 全部 20 个模块、`tests/` 全部 7 个测试文件、`index.html`、`sw.js`、`package.json`；测试套件在本机实际运行验证（`npm test`，319 项断言全部通过，见文末）。
> 目的：为 iOS 原生重写提炼**可移植的功能蓝图、数据模型与测试基线**；思路保留、实现不照搬。

---

## 1. 项目一句话概括

练时 LiftTime 是一个「生活量化五件套」记录器：**时间分配 + 睡眠 + 健身训练 + 饮食 + 预算**，五大板块各自独立记录，但通过**联动分析**（训练×饮食、预算×饮食、时间×训练）互相喂养，最终在「报告页」汇成单日简报与阶段综合报告。核心交互哲学是**两击记录**（点一下开始、点一下结束）+ **规则引擎兜底的智能简评**（AI 可选，失败自动降级）。

## 2. 技术架构概览（值得原样借鉴的结构决策）

```
index.html          应用壳（tabbar 6 tab + view 容器）
js/
  app.js            外壳：路由/主题/底部弹层(openSheet)/toast/确认弹层/SW 更新
  store.js          单一状态树 + localStorage 持久化 + 订阅刷新 + 导入净化
  util.js           纯函数工具（日期/时长/格式化/kg-lb 换算/safeColor）
  ── 纯逻辑层（无 DOM，Node 可直接单测）──
  exercises.js      动作库数据 + 名称→肌群解析
  analysis.js       训练分析引擎（单次/阶段/日简报）
  foods.js          食物库数据 + 名称查找
  nutrition.js      饮食解析（中文文本→宏量营养素）+ 日/阶段总结
  sleepMath.js      睡眠归属/午睡识别/睡眠分/统计
  finance.js        预算引擎（周月/自定义周期/计划外/蛋白质性价比）
  ai.js             GLM 接入（prompt 构建/稳健 JSON 解析/错误分类）
  reportBuilder.js  五域数据聚合 + 规则版报告 + AI 报告 prompt
  ── 视图层（每 tab 一个模块，render(root) 模式）──
  time.js workout.js diet.js budget.js report.js settings.js
  charts.js         手写 SVG 图表（donut/堆叠柱/24h时间轴/横条）
  analysisView.js   训练分析 HTML 渲染（详情页与日报共用）
tests/*.test.mjs    每引擎一份单测（自带 ok() 断言器，node 直跑）
```

关键架构决策（iOS 版应对应保留的「骨架思想」）：

1. **纯逻辑/视图严格分层**：六个引擎模块（analysis/nutrition/sleepMath/finance/ai/reportBuilder）零 DOM 依赖，测试直接 `import` 跑。iOS 对应：分析引擎写成独立 `Swift` 纯类型/纯函数层（Foundation only），不 import SwiftUI，`swift test` 直接覆盖。
2. **单一状态树 + 事务式提交**：`store.js` 的 `commit()` = 防抖持久化 + 广播订阅者刷新全页（`store.js:211-216`）。iOS 对应：单一 `AppState` ObservableObject（或 TCA 式 reducer），写盘走防抖 + 全量 JSON。
3. **不可信数据全过净化**：无论导入备份还是本地读盘，都过 `sanitizeState()`（`store.js:167-188`）——字段白名单、字符串/数组/集合有界（MAX_STR=2000、MAX_ENTRIES=100000）、原型污染键剔除、数值收敛到合法域。这是防「恶意备份注入」的安全底座，iOS 版导入 iCloud/文件备份时必须等价实现。
4. **AI 可选 + 规则兜底**：所有 AI 功能（训练简评、食物估算、综合报告）都有规则版兜底；AI 失败/超时/离线不影响核心功能（`workout.js:306-329`、`report.js:108-141`）。
5. **零第三方依赖**：图表手写 SVG，测试自带断言器。iOS 版对应：图表用 Swift Charts（系统框架），避免引第三方包。

## 3. 数据实体清单（来自 `store.js:28-43` defaults()）

| 实体 | 字段 | 说明 |
| --- | --- | --- |
| `settings` | `unit(kg/lb) bodyweight theme weeklyBudget monthlyBudget customBudgets[] aiKey aiBaseUrl aiModel aiEffort sleepGoalMin` | 全局配置；AI Key 明文存本地（导出会包含，settings.js:54 有提示） |
| `categories` | `{key,label,color}[]` | 时间分类，默认 9 个（热身/力量/有氧/拉伸/通勤/备餐/补剂/洗漱/其他），可增删（删除时历史记录归入最后一个分类） |
| `timer` | `{startedAt, kind:'general'\|'sleep'} \| null` | **单槽计时器**：同一时刻只能有一个进行中的计时（日常或睡眠互斥） |
| `timeBlocks` | `{id,start,end,cat,note}[]` | 已完成的时间段 |
| `sleepSessions` | `{id,start,end,feel(1-5),wakes(0-3),latency(fast/ok/slow),note,dayOverride?}[]` | 睡眠会话；问卷字段全部可空（不惩罚只点两下的用户） |
| `activeWorkout` | `{id,startedAt,exercises:[{name,sets:[{w,r,ts}]}],notes} \| null` | 进行中的训练（崩溃恢复用） |
| `workouts` | `{id,startedAt,endAt,exercises,feeling,notes,analysis}[]` | 完成训练；`analysis` 为生成时快照（含 AI 覆写标记 `ai:{model,effort,at}`） |
| `customExercises` | `{名称: {p:[muscleKey], s:[muscleKey]}}` | 自定义动作→肌群映射 |
| `dietEntries` | `{id,ts,meal,text,items,manualItems,unmatched,kcal,p,c,f,cost?}[]` | 饮食记录；`items`=食物库命中项，`manualItems`=手估项，`unmatched`=不计入文本，`cost` 联动预算 |
| `expenses` | `{id,ts,amount,cat,note,outOfPlan?}[]` | 手动开销；记餐花费不落这里而是从 `dietEntries.cost` 派生 |
| `customFoods` | `{名称: {k,p,c,f,g,u}}` | 自学习食物库（每 100g 营养 + 上次份量克数 + 单位），优先于内置库 |

派生关系（不落盘、实时计算）：合并开销流 = `allExpenses(expenses, dietEntries)`（`finance.js:43-58`，记餐 cost 派生为 `auto` 开销）；睡眠概要/统计全部由 `sleepMath` 现算；训练 analysis 落盘为快照但详情页可再生成（`workout.js:351-356`）。

## 4. 模块×功能矩阵

图例：● 核心 ○ 次要/联动 — 无

| 功能 | time | workout | diet | budget | report | settings | 依赖引擎 |
| --- | :-: | :-: | :-: | :-: | :-: | :-: | --- |
| 日常两击计时 | ● | — | — | — | — | — | — |
| 睡眠两击计时+问卷 | ● | — | — | — | — | — | sleepMath |
| 午睡自动识别 | ● | — | — | — | ○ | — | sleepMath.kindOf |
| 睡眠归属调整(dayOverride) | ● | — | — | — | — | — | sleepMath |
| 时间手动补记/编辑/删除 | ● | — | — | — | — | — | — |
| 24h 时间轴(含睡眠段) | ● | — | — | — | — | — | charts.timeline24 |
| 分类环形图/堆叠柱 | ● | — | ○ | ○ | ○ | — | charts |
| 自定义时间分类 | — | — | — | — | — | ● | — |
| 训练进行中逐组记录 | — | ● | — | — | — | — | exercises |
| 动作搜索+自定义动作(选肌群) | — | ● | — | — | — | — | exercises |
| 重量单位换算(kg/lb, 内部存kg) | — | ● | — | — | ○ | ● | util |
| 单次训练分析(主练/强度/PR/DOMS/恢复建议) | — | ● | — | — | ○ | — | analysis |
| AI 训练简评(可重生成) | — | ● | ○ | — | — | ● | ai + analysis |
| 阶段训练分析(7/30/90天) | — | — | — | — | ● | — | analysis.analyzePeriod |
| 中文记餐文本解析 | — | — | ● | — | — | — | nutrition + foods |
| 未识别食物类别猜测+手估 | — | — | ● | — | — | — | nutrition.guessFor |
| AI 食物估算 | — | — | ● | — | — | — | ai.aiEstimateFood |
| 自学习食物库 | — | — | ● | — | — | — | nutrition.learnFood |
| 餐次(6种)+练后餐自动预选 | — | ○ | ● | — | — | — | nutrition/diet.guessMeal |
| 日/周/月饮食总结+建议 | — | — | ● | — | ○ | — | nutrition |
| 记餐花费→预算联动 | — | — | ● | ● | — | — | finance.allExpenses |
| 周/月预算+节奏预测 | — | — | — | ● | — | — | finance.budgetStatus |
| 自定义周期计划(起止自由/多并存) | — | — | — | ● | — | — | finance.planRange/planStatus |
| 计划外开销(计总账不占额度) | — | — | — | ● | ○ | — | finance.planSpend |
| 蛋白质性价比(¥/10g) | — | — | ○ | ● | — | — | finance.proteinEconomy |
| 训练×饮食联动(练后餐提醒/蛋白缺口) | — | ○ | ● | — | ● | — | nutrition.dailyAdvice |
| 日简报(时间+睡眠+训练+饮食+预算) | ○ | — | ○ | ○ | ● | — | analysis.dayBrief + 各引擎 |
| 五域综合报告(规则+AI) | ○ | ○ | ○ | ○ | ● | — | reportBuilder |
| 数据导出/导入(JSON)+净化 | — | — | — | — | — | ● | store.sanitizeState |
| 主题(深浅色跟随系统) | — | — | — | — | — | ● | app.applyTheme |
| 离线+自动更新(SW) | — | — | — | — | — | ● | sw.js |

## 5. 分模块详解

### 5.1 store.js —— 状态与持久化

- **机制**：全量 JSON 存单一 localStorage 键 `lifttime.v1`；`commit()` 立即写一次 + 120ms 防抖再写（高频修改时减少 JSON 序列化），随后通知订阅者整页重渲染（`store.js:204-216`）。隐私模式/空间不足时静默降级为内存态并提示导出（`store.js:6-14`、`app.js:140-142`）。
- **净化（安全核心）**：`sanitizeState()` 对导入备份与本地读盘统一处理——设置逐字段校验（体重 0–2000、睡眠目标 240–720、AI baseUrl 必须 http(s)、effort 白名单）；分类 key 匹配 `^[A-Za-z0-9_-]{1,40}$` 且去重、label 截 64 字符、颜色必须十六进制（`util.safeColor`，防注入 style/SVG）；睡眠会话要求 end>start 且 ≤24h，feel/wakes/latency 收敛合法域，dayOverride 必须 YYYY-MM-DD；记录集合上限 10 万条、深净化递归深度 6、剔除 `__proto__/prototype/constructor`（`store.js:45-188`）。
- **测试基线**：`tests/store.test.mjs`（15 项）——AI 配置净化后不丢（曾因白名单缺失丢配置的回归测试）、非法睡眠会话剔除、越界字段归 null、旧数据无 kind 的 timer 向后兼容归 general。

### 5.2 time.js + sleep.js/sleepMath.js —— 时间与睡眠

- **计时器模型**：单槽 `timer`，日常/睡眠互斥；睡眠计时中日常按钮禁用并引导（`time.js:75-94`）。停止时弹底部 sheet 选分类（九宫 chips）+ 备注可选 + 丢弃。
- **睡眠归属规则（精华）**：`sleepDayKey(endTs) = dayKey(endTs - 4h)`——醒来的时刻往前推 4 小时所在的日期，即「那天的昨晚」。这让 23:40–06:52 和 00:30–08:00 都归属醒来当天（昨夜），同时 05:30 早鸟也归当天、22:00–00:30 短段仍拉回睡前那晚（`sleepMath.js:12-18`，`sleep.test.mjs:20-29` 有 8 个边界用例）。手动 `dayOverride` 优先，可一键恢复自动。
- **午睡识别**：09:00–18:00 开始且 <3h → nap，否则 night（`sleepMath.js:26-31`）；分段夜取最长段为主睡眠（`nightForDay`）。
- **睡眠分 0–100**：时长达成 40（按目标比例）+ 就寝规律 30（相对中位就寝锚点偏差，90 分钟归零）+ 起床感受 20（1–5 档映射 3–20 分）+ 夜间连续 10（夜醒每次 -2.5 封顶 3 次、入睡慢 -3）。**未填项给中性分**（感受 13、连续 10）——不惩罚只点两下的用户（`sleepMath.js:95-107`）。
- **就寝锚点**：bedtimeAnchor = 自 18:00 起的分钟数（模 1440），让 23:50 与 00:10 相邻可比（圆刻度统计的典型手法，`sleepMath.js:70-81`）；规律性用 MAD（平均绝对偏差）。
- **睡眠债**：只统计已记录的夜，各晚 `max(0, 目标-实际)` 之和；缺记的夜不记债也不进均值，但在 series 里以 null 呈现（诚实呈现数据缺口，`sleepMath.js:115-147`）。

### 5.3 workout.js + exercises.js + analysis.js —— 训练

- **动作库**：110+ 内置动作，每条 `{n名称, a别名[], p主肌群[], s次肌群[], bw自重, cardio有氧, ecc离心大}`；12 个肌群 key（chest/shoulder/triceps/back/biceps/forearm/quad/hamstring/glute/calf/core/full）归入 5 个结构组（push/pull/legs/core/cardio，`exercises.js:4-25`）。匹配顺序：自定义库 → 精确名 → 精确别名 → 包含匹配（双向，`exercises.js:152-163`）；搜索按精确/前缀/包含打分排序（`exercises.js:186-207`）。查不到的动作在添加时引导多选肌群并存入 `customExercises`。
- **容量口径**：组容量 = 重量×次数；自重/无重量动作容量记 0 但组数次数计入，肌群分摊时 credit=1（按组计，`analysis.js:36`）。主肌群按 `1/主肌群数` 系数、次肌群 `0.5/次肌群数` 分摊（`analysis.js:38-44`）。
- **强度与 PR**：Epley 估算 1RM `w×(1+min(r,15)/30)`（`analysis.js:7-9`）；每组最好 e1RM vs 历史（该动作此前所有训练的 e1RM 最大值）之比取均值 → 高(≥95%)/中高(≥85%)/中等(≥70%)/轻；PR 分「刷新纪录」与「首次基准」（prev=0）（`analysis.js:113-131`）。
- **DOMS 预估**：加权计分制——容量 vs 近 5 次均值(>1.5×加3 / >1.15×加2 / <0.7×加0 / 否则加1)、新动作比例(>50%加2 / >20%加1，新=14 天内没做过)、离心动作存在加1、腿臀主导加1、首次训练加1；总分 ≥7 强烈 / ≥5 明显 / ≥3 中度 / 其余轻微（`analysis.js:146-155`）。
- **单次简评结构**：`{brief[], postFeel[], nextDayText, domsLevel, diet[], rest[], prs[], muscles, groups, totals, intensity, ratio, volVsAvg, primary, secondary}`——**这个 JSON 结构同时是规则版输出、AI 版输出契约与渲染契约**（AI 解析成功的字段覆盖规则版字段，`workout.js:323`），一份渲染代码两用（`analysisView.js`）。
- **恢复建议联动**：读取当天实际已摄入蛋白质（`workout.js:331-336`），算出「还差多少克」；读取当天健身相关时间块（FITNESS_CATS 5 类）算「今天为训练共花掉 X」（`analysis.js:263`）。
- **阶段分析**（`analyzePeriod`，`analysis.js:282-383`）：频率/周、总容量与环比窗口对比、部位组分布、窗口内 PR（逐训练滚动更新 runningBest 区分刷新/首次）、连续训练 streak（提示 ≥5 天安排休息）、结构平衡提醒（拉<推一半→圆肩风险、腿<20%→补腿课、核心<5%、反之均衡表扬）、状态语气 tone（空窗/低频/连续疲劳/上升期/PR 期/积累期六档文案）。

### 5.4 diet.js + foods.js + nutrition.js —— 饮食

- **食物库**：320+ 项（每 100g 的 k/p/c/f + 常用份单位 u + 单份克数 g + 标签 t：protein/carb/veg/fruit/dairy/fat/junk/drink/supp），数据源标注《中国食物成分表》/USDA 近似值。查找：自定义库优先（精确→包含，长名优先防「酸奶」截胡「希腊酸奶」，`foods.js:348-367`）。
- **中文文本解析**（`parseMealText`/`parseSegment`，`nutrition.js:24-89`）：支持中文数字（两碗=2）、小数、市制单位（两=50g，「二两白酒」=100g）、克/毫升/升、约 30 种量词单位（个/杯/碗/份/勺/袋/套/瓣/串/段/听…）、尾部写法（米饭300g）、顿号/逗号/分号/加号/换行分隔。未识别的进 `unmatched` 不强行估算。
- **三层估算兜底**：①内置库精确命中；②未命中→按关键词猜 8 大类（汤/饮品/零食/主食/肉菜/素菜/混合/其他，正则规则表 `GUESS_RULES`）+ 抠文本克数 + 类别均值表（`ESTIMATE_CATS` 每 100g 数值 + 默认份克数）预填，**每项可改可整项不计入**；③配了 AI 可点「AI 估」（低思考强度求快）。手估过的自动 `learnFood` 归一每 100g 进自定义库，下次直接识别（`nutrition.js:171-179`）。
- **营养目标**：体重×30 kcal、蛋白质 1.6–2.2 g/kg、碳水 50% 热量、脂肪 27% 热量；无体重给通用默认（80–110g 蛋白 / 2000 kcal，`nutrition.js:182-194`）。
- **日建议**（`dailyAdvice`）：训练联动（练后 2.5h 窗口未吃练后餐→催、吃了→打勾 ✓；训练日蛋白缺口→下一餐补）、热量过低(<50% 且晚 9 后)提醒防节食、过高(>135%)、无蔬果（15 点后）、晚 9 点后加餐、junk≥3 项、有未识别项提示改写带数量。上限 4 条。
- **阶段总结**（`periodDiet`）：日均宏量、蛋白质达标天数、训练日达标率（**「饮食是否在支撑训练」的核心指标**）、晚加餐天数、Top5 常吃食物、按天按餐次序列。

### 5.5 budget.js + finance.js —— 预算

- **开销统一视图**：手动 `expenses` + 记餐 `dietEntries.cost>0` 派生的 auto 项合并成一条流（记餐开销在列表里显示「自动」徽标，点击引导去饮食页编辑源头，`budget.js:170-176`）。
- **双轨周期**：自然周（周一起）/自然月 + **自定义周期计划**（起止日期自由，days 自动算，可多个并存，状态分未开始/进行中/已结束，结束后一键「再来一期」= startTs 重置为今天，`budget.js:90-98`）。
- **节奏预测**：`projected = spent / (elapsed/total)`——按当前花销速度线性外推全期花费，超预算即预警；再给「剩 N 天每天控制在 ¥X 内可拉回」（`finance.js:148-165`）。
- **计划外开销**（设计亮点）：`outOfPlan` 标记的开销**照常计入周/月总账与统计**，但**不占自定义周期计划的额度**——解决「计划内的钱不想被突发消费（体检、随礼）污染进度」的真实需求。双口径并存：总账口径 `summarizeSpend(全部)`、计划进度口径 `planSpend(过滤)`（`finance.js:60-70`）。
- **蛋白质性价比**：`proteinEconomy` = 带花费的记餐的 cost 与 protein 聚合 → ¥/10g 蛋白质；对照参考成本表（鸡胸 ¥0.8/10g、鸡蛋 ¥1.6、蛋白粉 ¥2.2、牛肉 ¥2.5）；外卖聚餐占比>50% 且蛋白达标率<60% → 「钱花出去了营养没跟上」（`finance.js:174-218`）。

### 5.6 report.js + reportBuilder.js —— 报告

- **日简报**：日期前后翻页；时间投入（dayBrief：总时长 + Top 分类横条）+ 昨晚睡眠（时长/起止/感受/午睡/睡眠债）+ 当日训练卡片（含完整分析渲染）+ 当日饮食汇总（训练日蛋白缺口标黄）+ 当日/当周开销与预算进度（`report.js:143-241`）。
- **五域综合报告**：区间（过去一天/一周/一月/自定义 ≤366 天）→ `buildReportData` 聚合时间/睡眠/训练/饮食/预算 → 规则版 `renderRuleReport` 立即出（数字+结论、按板块分组）→ 有 AI Key 则后台用 GLM 重写，同一 JSON 结构直接互换渲染，失败保留规则版并 toast 原因（`report.js:108-141`）。
- **AI 契约**：`parseReportAI` 要求 overall 必填，各板块 1–6 条字符串数组；「你只能依据给出的数据下结论，数据缺失就直说缺」写进 system prompt（`reportBuilder.js:288`）——防模型编数据的意识值得继承。

### 5.7 ai.js —— GLM 接入

- 默认智谱 Coding Plan 端点 + `glm-5.3-flash` + 思考 max + 120s 超时；食物估算强制降为 low 强度求快（`ai.js:3-8,173`）。
- **稳健 JSON 解析**：剥 markdown 围栏 → 截取首个 `{` 到末个 `}` → JSON.parse → 逐字段校验（数组过滤非字符串、domsLevel 白名单四选一、空字段丢弃、全空抛错触发降级）（`ai.js:76-102`）。
- **错误分类**：AIError{kind: timeout|network|http|empty}，人话文案（401→Key 无效、429→额度/限流、network→提示 CORS 时自部署代理 `scripts/cors-proxy-worker.js`）。
- **可测试性**：fetchImpl 可注入，全部单测用 mock fetch 走通端到端（`tests/ai.test.mjs:68-100`）。

### 5.8 charts.js —— 手写 SVG 图表

donut（环形+中心标题）/ stackedBars（堆叠柱+niceMax 刻度+稀疏 x 轴标签）/ timeline24（24h 时间轴条）/ legend / hbars（横向占比条）。全部 title 提示 + aria-label。iOS 版直接用 Swift Charts 替代，但 **timeline24 这种「一天 24 小时一维条」是 Swift Charts 没有的现成图表**，需要自定义。

### 5.9 app.js / settings.js / sw.js —— 外壳与运维

- 底部弹层 openSheet（sticky 选项、点遮罩关闭）、toast、Promise 化确认弹层（`app.js:48-97`）。
- 设置页：体重/单位/主题/睡眠目标、时间分类管理（10 色调色板）、AI 配置（Key/模型/强度/接口/测试连接/清除）、导出（文件名带日期）/导入（50MB 上限、格式预检、覆盖确认）/清空（双确认）、安装指引（iOS 添加主屏幕）、检查更新（驱动 SW 做线上 sw.js 字节级比对，比版本号可靠，`settings.js:152-209`）。
- SW：应用壳预缓存清单 27 项 + 导航请求 network-first（仅规范同源 HTML 才允许污染缓存，防劫持）+ 其余 cache-first；controllerchange 自动刷新（`sw.js`）。

## 6. 值得移植到 iOS 版的测试（`reference/lifttime/tests/`）

全部 7 份测试都是「纯逻辑引擎」的单测，与 DOM 无关，**断言语义可直接翻译成 XCTest/SwiftTesting 用例**：

| 测试文件 | 规模 | 移植价值 | 关键用例（iOS 必须保住的行为） |
| --- | --- | --- | --- |
| `sleep.test.mjs` | 48 项 | ★★★ 最高 | 归属规则 8 个边界（03:59 归前夜 / 04:00 归当天）；分段夜取最长；午睡 9-18h/<3h 边界（8:59、18:00 整不算）；睡眠分各档精确数值（93/100/73/63/85/86）；缺记夜不进均值不记债；夜醒封顶 3 档 |
| `analysis.test.mjs` | 55 项 | ★★★ 最高 | Epley 15 次封顶；自重容量 0 但组数计入；肌群分摊 share；PR 刷新 vs 首次（62×8≈78.5）；强度 ratio；容量 vs 近 5 次均值；DOMS 分档（大容量腿日→明显/强烈、轻量熟悉→轻微）；推多拉少平衡提醒；streak=6 休息提醒；空窗口不崩溃；输出无 NaN |
| `nutrition.test.mjs` | 74 项 | ★★★ 最高 | 中文数字/量词/尾部克数/市制两解析（二两白酒=100g、两碗米饭=400g、半块巧克力=10g、米饭300g）；长名优先（无糖希腊酸奶杯→希腊酸奶）；未识别进 unmatched；类别猜测正则（排骨汤/奶茶/柠檬茶/炒饭）；learnFood 归一每 100g + 拒绝零值；自定义库按克缩放且不影响内置库；训练日达标率统计 |
| `finance.test.mjs` | 53 项 | ★★★ 最高 | 周(周一起)/月区间；记餐 cost 派生 auto 开销（无花费不计入）；projected 节奏预测（6.75/7 天花 495/500 → 超节奏）；planDays 含首尾（同一天=1 天）；计划三态；计外双口径（总账 400 / 计划进度 150）；超支/临期/健康三档建议文案；蛋白质 ¥/10g=3.65 |
| `ai.test.mjs` | 39 项 | ★★★ 最高 | 配置默认值；prompt 含实际数据（动作/容量/PR/当日摄入）；围栏/前后废话 JSON 截取；非法 domsLevel 丢弃；全空抛错；mock fetch 端到端；401→Key 无效；CORS→代理指引；食物估算强制 low |
| `reportBuilder.test.mjs` | 35 项 | ★★☆ | 区间换算（自定义含首尾、超 366 天拒）；五域聚合数值精确（时间 130 分/睡眠债 90 分/计划进度 6%）；规则版各板块文案锚点；AI 报告缺 overall 抛错 |
| `store.test.mjs` | 15 项 | ★★☆ | 净化不丢 AI 配置（回归）；非法睡眠会话剔除；越界字段归 null；旧 timer 无 kind 向后兼容 |

合计 319 项断言，本机 `npm test` 实跑全部通过（55+74+53+39+48+35+15；README:119 的「304 项」为未计 store 净化 15 项的旧口径）。

## 7. iOS 版应保留的核心思路（keep）

1. **两击记录的交互哲学**：所有记录入口都是「开始→结束」两击 + 事后可选补问卷；问卷不填不惩罚（睡眠分中性分设计）。这是留存率的根基。
2. **单槽计时器 + kind 区分**：同一时刻只有一个进行中事项（日常/睡眠互斥），状态落盘可崩溃恢复（timer 持久化在 state 里）。
3. **纯逻辑引擎与 UI 分离 + 引擎全覆盖单测**：六个引擎（analysis/nutrition/sleep/finance/ai/report）零 UI 依赖、319 项断言——iOS 版把引擎写成 Foundation-only 的 Swift 模块，测试语义 1:1 翻译。
4. **睡眠归属 -4h 规则 + dayOverride**：跨零点归属的正确解法，边界行为已有 8 用例锁定，直接照抄语义。
5. **未填项中性分**的评分设计（不惩罚极简用户）。
6. **容量/Epley/PR/DOMS 的完整训练分析口径**：主肌群 1/n、次肌群 0.5/n 分摊；PR 区分刷新与首次基准；DOMS 加权计分制。这些口径是整个训练简评的可信度来源，测试已锁数值。
7. **中文饮食文本解析 + 三层估算兜底 + 自学习食物库**：这是与 MyFitnessPal 类产品的差异化核心；量词表、两=50g 市制、长名优先匹配都要保留。
8. **计划外开销双口径**：计总账、不占周期计划额度——真实记账场景的刚需。
9. **蛋白质性价比（¥/10g）与参考成本表**：预算×饮食联动的招牌功能。
10. **AI 可选 + 规则兜底 + 字段级覆写**：规则版结构 = AI 输出契约 = 渲染契约，一份渲染两用；AI 稳健 JSON 解析（围栏剥离、字段白名单、全空抛错降级）。
11. **不可信输入全过净化**：导入备份与本地数据同一条净化管线，字段白名单 + 有界 + 原型污染防护（iOS 对应：Codable 手写解码器 + 长度/域校验，不信任任何来源的 JSON）。
12. **分析快照落盘**（workout.analysis）：生成时冻结，历史报告不随口径升级漂移；同时详情页可按新口径再生成。
13. **联动而非孤岛**：五板块互相喂养（练后餐预选、恢复建议读实际摄入、训练日蛋白达标率、记餐花费自动入账、日简报五域合一）——联动是产品灵魂，iOS 信息架构必须保持跨模块读写同一数据层。

## 8. iOS 版应调整或舍弃的部分（adapt）

1. **舍弃 localStorage 单键全量 JSON**：换成 SwiftData/Core Data（或 GRDB）分实体存储；全量 JSON 在记录到 10 万条级会序列化卡顿，且无增量迁移能力。防抖 commit 思想保留（context 自动保存即可）。导出/导入仍走全量 JSON 文件以兼容备份习惯。
2. **舍弃 Service Worker / PWA 安装 / 检查更新整套**：原生 App 由 App Store 管更新；sw.js、manifest、安装指引、「检查更新」按钮全部不需要。
3. **舍弃手写 SVG 图表**：Swift Charts 原生覆盖 donut/堆叠柱/横条；仅 timeline24（24h 一维时间轴）需要自定义 Canvas/Chart plot 视图。
4. **睡眠应接 HealthKit**：README Roadmap 里「Apple Health 导入」本来就是未竟心愿。iOS 版睡眠记录应优先从 HealthKit 读取（自动睡眠段），两击手动记录作为兜底与补记；feel/wakes/latency 问卷保留（HealthKit 没有）。训练同理可读 Apple Fitness/体能数据，但自重量×次数记录保留为主。
5. **AI Key 存储升级 Keychain**：浏览器只能 localStorage 明文（已有导出含 Key 的提示），iOS 必须用 Keychain，且导出备份默认剔除 Key。
6. **AI 网络层换 URLSession**：无 CORS 问题（浏览器特有），`scripts/cors-proxy-worker.js` 整个不需要；AbortController→URLSession timeout；fetchImpl 注入→protocol mock。
7. **底部弹层/ toast/确认框换 SwiftUI 原生**：sheet、alert、confirmationDialog 一一对应；「sticky 防误关」对应 .presentationBackgroundInteraction / interactiveDismissDisabled。
8. **单位与本地化**：kg/lb 换算「内部一律存 kg、显示换算」（util.js:84-92）保留；但日期处理应换 Calendar/DateComponents，dayKey 的本地时区语义用 Calendar.startOfDay(for:) 等价实现（注意测试锚点也要固定 TimeZone）。
9. **整页 innerHTML 重渲染**：换 SwiftUI 声明式后自然消失；「数据变→订阅刷新」对应 @Observable/Combine，无需手动 tick 计时器（TimelineView 或 Timer.publish 驱动时钟显示）。
10. **预算板块可考虑弱化或延后**：iOS 用户若有「钱包/账单」类 App 习惯，预算是五域中使用频率最低的；但「记餐花费自动入账 + 蛋白质性价比」联动独特，建议保留精简版（周/月 + 记餐联动），自定义周期计划可后置。
11. **主题切换**：跟随系统由 iOS 自动处理，仅保留手动覆盖选项；safeColor 白名单思想保留（自定义分类颜色限制在预设调色板内，天然安全）。
12. **uid()（时间戳+随机）**：换 UUID；store 净化中「补 id」逻辑保留但用 UUID 字符串校验。
13. **测试基础设施**：自带 ok() 断言器换 Swift Testing（@Test/#expect）；固定 NOW 时间锚 + 本地时区构造 Date 的手法照搬（注意测试时固定 TimeZone.current 或显式传 Calendar）。

## 9. 验证记录

- 命令：`cd /Users/nanami/Desktop/Zcode/iOS-app/self-record/reference/lifttime && npm test`
- 结果：7 个测试文件全部通过——
  `analysis: 55 通过, 0 失败`、`nutrition: 74 通过, 0 失败`、`finance: 53 通过, 0 失败`、`ai: 39 通过, 0 失败`、`睡眠引擎: 48 项通过, 0 项失败`、`综合报告生成器: 35 项通过, 0 项失败`、`状态净化: 15 项通过, 0 项失败`。
- 本机无完整 Xcode（仅命令行工具），本次分析为纯 JS 项目阅读与运行，未涉及 swift build / swift test（工作区尚无 Swift 包）。
