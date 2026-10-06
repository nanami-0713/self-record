# SelfRecord · iOS 应用整体设计

> 版本：v3（2026-10-06，按终审意见修订：净化管线定为元素级容错三步、dailySummary 补 workouts 参数、睡眠分数归属区间层、proteinHitRate 全记录日口径、宏禁令例外清单）。此前 v2 按设计评审修订（恢复 lifttime 三处数据口径、补参数注入契约、定型色板/字阶跨平台方案、新增 SwiftUI 宏禁令）。
> 输入：`docs/reference-lifttime.md`（功能蓝图与测试基线）+ `docs/reference-ely.md`（设计语言）。
> 硬约束：本机只有命令行工具（Swift 6.4 + macOS SDK，无完整 Xcode）。**一切验证以 `swift build` / `swift test` 为准**；SwiftUI / Charts 代码必须能在 macOS 下编译，iOS 独有 API 一律 `#if os(iOS)` 包裹或规避。
> 工程形态：模块化 Swift Package（`SelfRecordCore` 纯逻辑 + `SelfRecordUI` SwiftUI 界面）；iOS 应用入口与 XcodeGen 工程放 `app/`，不参与 `swift build`。

---

## 0. 本机编译环境事实（2026-10-06 实测，全文档设计决策的前提）

以下均在本机实测（命令与结果见 §13）：

1. **iOS SDK 不存在**：`xcrun --sdk iphoneos --show-sdk-path` → `error: SDK "iphoneos" cannot be located`；`xcode-select -p` = `/Library/Developer/CommandLineTools`。⇒ 一切 `#if os(iOS)` / `canImport(UIKit)` 分支**在本机从未编译过**，不只是「不能运行」。对策：iOS-only 代码薄化到独立小文件集中放置，真机首轮编译的预期爆雷点收敛到少数文件。
2. **SwiftUI 宏在本机 swift build 下不可用**：macOS 27 SDK 中 `@State` / `@Observable` 持有态 / `@ScaledMetric` 等 attribute 已宏化（`SwiftUIMacros` 模块），而 CLT 的插件目录只有 `libObservationMacros.dylib` 与 `libSwiftMacros.dylib`，无 SwiftUIMacros——实测含 `@State` 的包 `swift build` 直接失败。⇒ **SelfRecordUI 全包禁用 SwiftUI 宏**：状态管理走 `ObservableObject` + `@Published` + `@ObservedObject` / `@StateObject` / `@EnvironmentObject`（propertyWrapper，实测可编译）；字阶缩放不依赖 `@ScaledMetric`（§7.2 用系统 TextStyle 天然承载 Dynamic Type）。`@Observable`（Observation 宏）本身可编译，但 View 持有 model 需要 `@State`，一并回避。
3. **xcodebuild 需要 Xcode、xcodegen 未安装**：⇒ `app/project.yml` 的产出本机零验证，风险与对策见 §11。
4. **已实测可行的 UI 技术面**：`ObservableObject` 路径 + `import Charts`（BarMark 等）+ `sheet` / `presentationDetents` / `interactiveDismissDisabled` / `confirmationDialog` / `environmentObject`，在 `swift build`（platforms `.iOS(.v17)+.macOS(.v14)`、swift-tools 6、`-swift-version 6`）下**编译通过**（探针包 BUILD_EXIT=0，见 §13）。

---

## 1. 产品定位与总原则

SelfRecord 是一个「生活量化五件套」：**时间分配 + 睡眠 + 训练 + 饮食 + 预算**，五个域各自独立记录，靠跨域联动（练后餐预选、恢复建议读实际蛋白摄入、记餐花费自动入账、训练耗时聚合、日简报五域合一）互相喂养。

三条贯穿性原则（来自 lifttime 的灵魂，全部保留）：

1. **两击记录**：所有记录入口都是「开始 → 结束」两击，事后问卷可跳过且不惩罚（睡眠分未填项给中性分）。留存率的根基。
2. **规则引擎兜底**：一切分析先有规则版，结构即契约；AI 是可选增强，失败不影响任何核心功能（第一版不实现 AI 网络层，只保留数据接缝，见 §9）。
3. **不可信输入全过净化**：导入备份与本地读盘走同一条净化管线——字段白名单、有界、数值收敛合法域。防「恶意备份注入」。

三条 iOS 原则（lifttime 交互的重新设计，不是照搬）：

4. **Tab 导航 + 原生控件习惯**：5 Tab 底部导航；弹层用 sheet / alert / confirmationDialog；返回、滑删、长按上下文菜单按 iOS 习惯。
5. **Ely 设计语言**：暖中性色板 + 墨色反转主色 + 语义色 token，组件只写语义名不写色值字面量（详见 §7）。
6. **纯逻辑与 UI 严格分层**：所有分析/解析/统计引擎是 Foundation-only 值类型纯函数，放 `SelfRecordCore`，`swift test` 直接覆盖；视图层零业务逻辑。

---

## 2. 架构总览与依赖规则

```
┌──────────────────────────────────────────────────────────────┐
│ app/SelfRecordApp.swift（@main + TabView；不参与 swift build） │
├──────────────────────────────────────────────────────────────┤
│ SelfRecordUI（SwiftUI + Swift Charts；禁用 SwiftUI 宏，见 §0-2）│
│   DesignSystem/（Ely 令牌与组件）  today/ records/ workout/    │
│   budget/ settings/（五个界面分组，各一组并行实现）             │
│   AppModel.swift：ObservableObject 主线程状态容器（骨架产出，  │
│   各分组以 extension 分文件接线，见 §8 约定 4）                │
├──────────────────────────────────────────────────────────────┤
│ SelfRecordCore（Foundation only；不 import SwiftUI）           │
│   基础层：Model/（全部领域结构体） Storage/（DataStore+净化）   │
│           TimeKit/（DayKey/DayCalendar/格式化）                │
│   功能模块（各一目录、并行实现、互不改对方目录）：               │
│     time-tracking  sleep  workout  diet  budget  report       │
└──────────────────────────────────────────────────────────────┘
```

数据流（单向）：

```
View ──绑定──> AppModel（ObservableObject + @Published，MainActor）
                │  以值类型快照调用
                ▼
        Core 域引擎（enum 命名空间 + 纯静态函数，无状态）
                │  产出新快照 / 分析结果
                ▼
        DataStore（actor：分域 JSON 文件、原子写、防抖 flush）
```

**依赖规则**（并行开发的护栏，骨架阶段冻结）：

- 功能模块只依赖基础层（`Model/` `Storage/` `TimeKit/`）；模块之间**禁止横向调用**。
- 跨域数据通过两条合法通道解决，不许引擎互相 import：
  1. **共享模型**：`budget` 合并开销流直接读 `Model/` 里的 `DietEntry`（costYuan 字段派生 auto 开销），不调 `diet` 引擎；
  2. **参数注入**：跨域上下文全部显式出现在函数签名里，注入者由 UI / `report` 组装。两个已定型的注入契约（**骨架冻结物，结构体定义见 §4 末「跨域注入上下文」**）：
     - `RecoveryContext`（含 `bodyweightKg` / `dayIntake: DayIntake?`（proteinG、kcal、itemCount、hasPostMeal）/ `fitnessTimeMinutes`）——对应 lifttime `workout.js:331-343` 的 `dayIntakeToday{p,cal,items,hasPostMeal}` + `fitnessTimeToday`，`analysis.js:190-193/:211/:263` 消费；
     - `budget` 建议函数签名 `budgetAdvice(week:month:sumWeek:proteinEconomy:proteinHitRate:)`：`proteinHitRate: Double?` 由 `DietEngine.periodDiet`（§2.1 冻结聚合 API）产物经 UI / `report` 注入。**口径写死（B1）**：注入值 = `proteinHitDays / daysTracked`（**全记录日**达标率）——lifttime 产品代码在 budget.js:423-424 动态计算 `pd.daysTracked ? pd.proteinHitDays / pd.daysTracked : null`；`finance.test.mjs:79` 的 `proteinHitRate: 0.4` 是测试 fixture，不是产品行为。**不是**「训练日达标率」（那是 periodDiet 的另一个产物 trainingDayHitRate，报告与日简报用）。
- `report` 是唯一的聚合点：它调用五个域引擎的**只读聚合 API**，方向永远 report → 各域，反向禁止。聚合 API 签名清单见 §2.1（骨架冻结物 B）。
- 所有引擎函数显式收 `DayCalendar`（Calendar + TimeZone 封装），不隐式依赖 `TimeZone.current`——测试可锚定固定时区。

**骨架冻结物**（骨架阶段产出后即冻结，功能模块/界面工程师只读；发现缺口报修复工程师，不私改）：

- **A：基础层**——`Model/`（§4 全部结构体 + §4.1 默认数据）、`Storage/`（DataStore / BackupDocument / **BackupSanitizer：三步元素级容错管线，§4**）、`TimeKit/`；
- **B：report 所需五域只读聚合 API 签名清单**（§2.1）——report 与五域工程师并行的契约，双方都不得偏离；
- **C：AppModel 外壳与 extension 协议**（§8 约定 4）——跨域接线不落任何共享可变文件。

### 2.1 冻结物 B：report 所需五域只读聚合 API（签名清单）

区间统一用值类型 `DateSpan { var startDay: DayKey; var endDay: DayKey }`（含首尾，放 `TimeKit`）。以下签名是 report 工程师与各域工程师的共同契约；返回类型在各自模块内定义，但字段语义以 lifttime 对应函数为准（括注源）：

```swift
enum TimeEngine {
    /// 当日时间投入简报：总分钟 + Top 分类（report 日简报「时间」域）
    static func dayBrief(_ blocks: [TimeBlock], day: DayKey, categories: [TimeCategory],
                         calendar: DayCalendar) -> TimeDayBrief          // lifttime analysis.dayBrief 时间部分
    /// 区间内逐日按分类的分钟聚合（阶段报告「时间」域 + TimeView 近7/30 堆叠柱）
    static func dailyBreakdown(_ blocks: [TimeBlock], in span: DateSpan,
                               categories: [TimeCategory], calendar: DayCalendar) -> [DayKey: [String: Double]]
    /// 当日健身相关时间块合计（RecoveryContext.fitnessTimeMinutes 的来源；FITNESS_CATS 见 §3.1）
    static func fitnessMinutes(_ blocks: [TimeBlock], day: DayKey, calendar: DayCalendar) -> Double
}

enum SleepEngine {
    /// 某夜主睡眠（分段夜取最长段）+ 简报字段（时长/起止/感受/午睡标志）。
    /// ⚠ 不含睡眠分——lifttime 的 nightForDay 只取段不评分（sleepMath.js:36-41），
    /// 分数永远由 score/periodSummary 以显式锚计算（A3 口径，见下）。
    static func nightForDay(_ sessions: [SleepSession], day: DayKey, calendar: DayCalendar) -> SleepNight?
    /// 单夜睡眠分 0–100（时长 40/规律 30/感受 20/连续 10，未填项中性分）。
    /// medAnchorMinutes = 就寝规律参照锚（自 18:00 起的分钟数），nil → 330（23:30，sleepMath.js:98）。
    static func score(_ session: SleepSession, goalMinutes: Int,
                      medAnchorMinutes: Double?, calendar: DayCalendar) -> Int
    /// 区间睡眠统计：锚 = 区间内就寝锚中位数（无记录 → 330，reportBuilder.js:83-84 口径）；
    /// 产出逐夜分数序列 + avgScore + MAD + 睡眠债 + 缺记夜列表（缺夜不进均值不记债）。
    /// 所有「多夜分数」展示（SleepView 趋势、report avgScore）一律出自本函数——
    /// 同一夜在任何页面分数相同，杜绝锚漂移。
    static func periodSummary(_ sessions: [SleepSession], in span: DateSpan, goalMinutes: Int, calendar: DayCalendar) -> SleepPeriodSummary
}

enum WorkoutEngine {
    /// 区间阶段分析（频率/容量环比/部位分布/PR/streak/平衡/语气六档）
    static func analyzePeriod(_ workouts: [Workout], in span: DateSpan, calendar: DayCalendar) -> WorkoutPeriodAnalysis
}

enum DietEngine {
    /// 当日宏量汇总 + 目标 + 日建议（≤4 条）。workouts 同日训练记录——驱动
    /// ①练后 2.5h 窗口判定（nutrition.js:239-243）②训练日蛋白缺口文案
    /// ③训练日目标提升 targets(bodyweight, trained: Bool)（nutrition.js:229）。
    /// ⚠ 缺 workouts 参数则 §3.4 日建议无法实现（A2 冻结签名补全）。
    static func dailySummary(_ entries: [DietEntry], day: DayKey, workouts: [Workout],
                             bodyweightKg: Double?, calendar: DayCalendar, now: Date) -> DietDaySummary
    /// 区间饮食总结（日均宏量/蛋白达标天数/晚加餐天数/Top5 食物）。
    /// 双达标率口径并存（B1，均由本函数产出，调用方按用途取）：
    ///  • trainingDayHitRate = 训练日达标/训练日有记录数（「饮食是否支撑训练」主指标）
    ///  • proteinHitDays/daysTracked = 全记录日达标率——budgetAdvice 的
    ///    proteinHitRate 注入用这个（lifttime budget.js:423-424 动态计算，
    ///    finance.test.mjs:79 的 0.4 是测试 fixture 不是产品行为）
    static func periodDiet(_ entries: [DietEntry], workouts: [Workout], in span: DateSpan,
                           bodyweightKg: Double?, calendar: DayCalendar) -> DietPeriodSummary
    /// 当日摄入快照（RecoveryContext.dayIntake 的组装来源；woStartedAt 用于 hasPostMeal 判定）
    static func dayIntake(_ entries: [DietEntry], day: DayKey, woStartedAt: Date?, calendar: DayCalendar) -> DayIntake?
}

enum BudgetEngine {
    /// 周或月预算状态（spent/projected/剩余与拉回指引）+ 合并开销流汇总（manual + diet auto 派生）
    static func status(budgetYuan: Double?, span: DateSpan, expenses: [Expense], dietEntries: [DietEntry],
                       calendar: DayCalendar, now: Date) -> BudgetStatus?
    /// 蛋白质性价比（¥/10g + 参考成本对照）
    static func proteinEconomy(dietEntries: [DietEntry], in span: DateSpan, calendar: DayCalendar) -> ProteinEconomy?
}
```

report 的 `ReportData` 消费以上返回值聚合；`AppModel` / 各界面同样只经这份清单取数（含 RecoveryContext 组装：`DietEngine.dayIntake` + `TimeEngine.fitnessMinutes`），不越层直捣各域内部函数。

---

## 3. 模块划分

基础层（骨架阶段实现，模块工程师**不得改动**）+ 6 个功能模块（并行实现）。模块 id 即 `Sources/SelfRecordCore/<id>/` 目录名。

### 3.0 基础层（骨架阶段，不算功能模块）

| 目录 | 职责 |
|---|---|
| `Model/` | §4 全部领域结构体（Codable + Sendable 值类型），含校验 init |
| `Storage/` | `DataStore` actor（分域 JSON、原子写、防抖）、`BackupDocument`（导出/导入全量 JSON）、`BackupSanitizer`（净化管线：白名单 + 有界 + 数值收敛 + 深度限制；对应 lifttime `store.js:45-188` 的 sanitizeState） |
| `TimeKit/` | `DayKey`（yyyy-MM-dd 值类型，等价 lifttime dayKey）、`DayCalendar`（注入 Calendar/TimeZone）、时长/宏量格式化、kg↔lb 换算（内部一律存 kg） |

### 3.1 `time-tracking` 时间分配

- **目标**：单槽计时器（日常/睡眠互斥，`ActiveTimer` 落盘可崩溃恢复）；停止后选分类保存（UI 层 sheet 九宫格）；时间块的手动补记/编辑/删除校验（end>start）；按日聚合（总时长、Top 分类、跨午夜块归属）；**今日 / 近 7 天 / 近 30 天三档区间聚合**（逐日按分类分钟数，对应 lifttime time.js:31-36 的三段切换与每日堆叠柱）；分类管理语义（删除或归档分类时，其历史块归属**兜底分类**——模型上由 `TimeCategory.isFallback` 显式标识（§4），不依赖数组顺序；对应 lifttime catOf 的「找不到归最后一个」语义 store.js:221-223，但用显式标志替代隐式末位）。
- **健身相关分类集合**：`FITNESS_CATS = ["warmup", "strength", "cardio", "stretch", "shower"]`（与 lifttime workout.js:12 一致）以常量放本模块，对外提供 `TimeEngine.fitnessMinutes`（§2.1）——「今天为这次训练总共花掉 X」这条时间×训练联动的数据源。
- **依赖**：基础层。
- **lifttime 对应**：`js/time.js` + `store.js` 的 `timer/timeBlocks/categories/DEFAULT_CATEGORIES` 部分。
- **测试**：lifttime 时间模块无专属测试文件，自建用例（计时器互斥与恢复、end>start 校验、跨午夜日聚合、近 7/30 逐日聚合、分类删除归并到 isFallback、引用完整性：块的 categoryID 必须能在分类表中解析）+ 移植 `store.test.mjs` 中 timer 向后兼容断言（旧数据无 kind 归 general）。

### 3.2 `sleep` 睡眠

- **目标**：两击上床/起床 + 可跳过问卷（feel 1–5 / wakes 0–3 / latency 三档，全可空）；**手动补录/编辑（2026-10-06 增，用户验收反馈）**：`SleepEngine.makeSession/entryError/entryPreview` 带校验构造（end>start 且 1min–24h）、归属预览、补录与两击会话同形状同口径；-4h 归属规则（`sleepDayKey(end) = dayKey(end - 4h)`，醒来时刻往前推 4 小时所在日期 =「那天的昨晚」）+ `dayOverride` 手动调整；午睡识别（09:00–18:00 开始且 <3h）；睡眠分 0–100（时长 40 + 就寝规律 30 + 感受 20 + 连续 10，**未填项给中性分**：感受 13、连续 10）；bedtimeAnchor 圆刻度（自 18:00 起模 1440）+ MAD 规律性；睡眠债（只统计已记录夜，各晚 `max(0, 目标-实际)` 之和，缺记夜不进均值不记债）。
- **口径注记（移植时照抄并注释，锁定锚点）**：
  - 规律分参照锚 `medAnchor` **无记录时默认 330（23:30）**（sleepMath.js:98、:125——`n ? median(anchors) : 330`；sleep.test.mjs:73 显式传 330，测试会抓）；
  - 规律分偏差用 `abs(bedtimeAnchor − med)` **线性差而非圆刻度差**（sleepMath.js:99）——17:5x 就寝者会被误判归零，是 lifttime 已知缺陷；**照抄保锚点，代码注释标明**，圆刻度修正列为后续项（修正即改测试锚点，须显式决策）；
  - **分数层归属（A3 口径）**：`nightForDay` 只取段不评分（sleepMath.js:36-41）；单夜分数只经 `SleepEngine.score(session, goalMinutes:, medAnchorMinutes:)`（nil→330）显式计算，多夜分数一律出自 `periodSummary`（锚=区间中位或 330，reportBuilder.js:83-90 口径）——同一夜在任何页面分数相同；日简报睡眠区不显示单夜分数（时长/感受/睡眠债，lifttime report.js:172-176 同）。
- **依赖**：基础层。
- **lifttime 对应**：`js/sleepMath.js`（`sleepMath.js:12-18` 归属规则、`:95-107` 评分）。
- **测试**：移植 `sleep.test.mjs` 全部 48 项断言语义（归属 8 边界含 03:59 归前夜 / 04:00 归当天；分段夜取最长；午睡 8:59 与 18:00 整不算；睡眠分数值锚点 93/100/73/63/85/86；缺记夜语义；夜醒封顶 3 档）。

### 3.3 `workout` 训练记录与分析（合并 lifttime 的 workout + analysis）

- **目标**：内置 110+ 动作库（含别名、主/次肌群、自重/有氧/离心大标志）+ 自定义动作（查不到时引导多选肌群，匹配顺序：自定义 → 精确名 → 精确别名 → 双向包含；搜索按精确/前缀/包含打分）；逐组记录重量×次数；结束后生成**分析快照落盘**（`Workout.analysis`，历史报告不随口径升级漂移，详情页可再生成）。分析口径完整保留：
  - 容量 = 重量×次数；自重/无重量动作容量记 0 但组数次数计入，肌群分摊时 credit=1（按组计）；
  - 肌群分摊：主肌群 `1/n`、次肌群 `0.5/n`；
  - Epley e1RM = `w×(1+min(r,15)/30)`，rep 15 封顶；强度 = 每组最好 e1RM vs 历史最佳之比均值 → 高(≥95%)/中高(≥85%)/中等(≥70%)/轻；
  - PR 区分「刷新纪录」与「首次基准」（prev=0）；
  - DOMS 加权计分制（容量 vs 近 5 次均值 3/2/0/1 分、新动作比例 2/1、离心 +1、腿臀主导 +1、首次训练 +1 → ≥7 强烈 / ≥5 明显 / ≥3 中度 / 其余轻微）；
  - 恢复建议（§2 RecoveryContext 注入契约完整消费：`dayIntake.itemCount > 0` 才出「已记录 X g 还差 Y g」三分支文案、`dayIntake.hasPostMeal` 出「练后餐已经吃上了 ✓」、`fitnessTimeMinutes > 0` 出「今天为这次训练总共花掉 X」——时间×训练联动；对应 lifttime analysis.js:190-193、:211、:263）与阶段分析（7/30/90 天：频率/容量环比/部位组分布/窗口 PR 滚动 runningBest/连续 streak ≥5 提示休息/推拉腿平衡提醒/六档语气 tone）。
- **依赖**：基础层。
- **lifttime 对应**：`js/exercises.js` + `js/analysis.js`（`analysis.js:36-44` 分摊、`:113-131` PR、`:146-155` DOMS、`:282-383` 阶段分析）。
- **测试**：移植 `analysis.test.mjs` 全部 55 项断言语义（Epley 15 封顶、自重容量 0 但组数计入、分摊 share、PR 刷新 vs 首次 62×8≈78.5、强度 ratio、容量 vs 近 5 次均值、DOMS 分档（大容量腿日→明显/强烈、轻量熟悉→轻微）、推多拉少平衡提醒、streak=6 休息提醒、空窗口不崩溃、输出无 NaN）。

### 3.4 `diet` 饮食记录与解析

- **目标**：中文自然语言记餐解析（中文数字「两碗=2」、小数、**市制「两=50g」（二两白酒=100g）**、克/毫升/升、约 30 种量词（个/杯/碗/份/勺/袋/套/瓣/串/段/听…）、尾部写法「米饭300g」、顿号/逗号/分号/加号/换行分隔）；未识别进 `unmatched` 不强行估算；三层估算兜底：①内置库（320+ 项，每 100g 宏量 + 常用份单位 + **tags 标签**）与自学习库命中（**长名优先**防「酸奶」截胡「希腊酸奶」）→ ②类别猜测（8 大类正则规则 + 抠文本克数 + 类别均值表预填，每项可改可整项不计入）→ ③AI 估算（第一版后置，接口留 `estimateSource` 字段）；手估过的自动归一每 100g 进自学习库（拒绝零值，默认打 `custom` 标签）；营养目标（体重×30 kcal、蛋白 1.6–2.2 g/kg、碳水 50%、脂肪 27%；无体重给通用默认）；日建议（练后 2.5h 窗口催练后餐/打勾、训练日蛋白缺口、热量过低过高、无蔬果（!tags.veg && !tags.fruit 且 15 点后）、**晚 9 点后加餐**（`hour ≥ 21 && meal == .snack`）、junk≥3、未识别项提示，上限 4 条）；日/周/月总结（含**训练日蛋白达标率**——「饮食是否在支撑训练」的核心指标、Top5 常吃食物）；餐次推断与练后餐预选；记餐花费 `costYuan` 联动预算。
- **口径锁定（与 lifttime 一字不差，nutrition.js:5-12 MEALS）**：餐次六档 = `breakfast 早餐 / lunch 午餐 / dinner 晚餐 / snack 加餐（通用，不按时段拆分）/ preworkout 练前餐 / postworkout 练后餐`。练后餐判定（nutrition.js:239-243）：`meal == .postworkout && ts ≥ 训练开始` **或** 训练结束 ±（-10min, +2.5h）窗口内的非 preworkout 餐；未知餐次回退 `.snack`（`mealOf` 默认 MEALS[3]）。
- **tags 口径**：标签集 10 档 `protein/carb/veg/fruit/dairy/fat/junk/drink/supp/custom`（foods.js:2-3）。tags 挂在**库命中项**（`FoodMatch.tags`，来自食物库条目；`CustomFood` 默认 `[.custom]`）；手估项（`ManualFoodItem`）**无 tags**（lifttime guessFor 返回 {catKey, grams, 宏量} 无标签，nutrition.js:145-149）。日汇总的 tags 计数只聚合库命中项（nutrition.js:206-208 同口径）——手估项不参与「无蔬果/junk」判定，移植时保持一致并注释。
- **依赖**：基础层。
- **lifttime 对应**：`js/foods.js` + `js/nutrition.js`（`:24-89` 解析、`:145-149` guessFor、`:171-179` learnFood、`:239-243` 练后判定）。
- **测试**：移植 `nutrition.test.mjs` 全部 74 项断言语义（中文数字/量词/尾部克数/市制两：二两白酒=100g、两碗米饭=400g、半块巧克力=10g、米饭300g；长名优先：无糖希腊酸奶杯→希腊酸奶；unmatched；类别猜测：排骨汤/奶茶/柠檬茶/炒饭；learnFood 归一 + 拒绝零值；自定义库按克缩放不影响内置库；训练日达标率；`mealOf('preworkout')='练前餐'`、未知餐次回退加餐、postworkout 构造记录的练后餐打勾/催促文案 nutrition.test.mjs:66-70/:165-168）。

### 3.5 `budget` 预算

- **目标**：开销统一视图 = 手动 `Expense` + 记餐 `DietEntry.costYuan > 0` 派生的 auto 项（无花费不计入，派生项分类恒为 `.meals`）；自然周（周一起）/自然月预算；**节奏预测** `projected = spent / (elapsed/total)` 线性外推 + 超预算预警 + 「剩 N 天每天控制在 ¥X 内可拉回」；**计划外开销双口径**：`isOutOfPlan` 标记账照常计入周/月总账与统计，但不占周期额度（~~第一版周期=周/月，自定义周期计划后置~~ **2026-10-06 已实装自定义周期计划**：`CustomBudgetPlan` 多并存、含首尾起止、三态、双进度与拉回建议、再来一期，见 `Budget/BudgetPlans.swift`）；超支/临期/健康三档建议；**蛋白质性价比**：带花费记餐的 cost 与 protein 聚合 → ¥/10g，对照参考成本表（鸡胸 ¥0.8/10g、鸡蛋 ¥1.6、蛋白粉 ¥2.2、牛肉 ¥2.5）。
- **开销分类口径锁定（lifttime finance.js:5-13 EXP_CATS，7 档）**：`meals 记餐开销(auto) / groceries 食材采购 / takeout 外卖外食 / social 聚餐 / supplement 补剂 / fitness 健身相关 / other 其他`。**不采用通用记账分类**（购物/交通/居住…）：本应用的预算域是健身饮食向，「外卖聚餐占比」「补剂占比」两条诊断建议依赖此口径——`外卖/聚餐占比 = (takeout + social) / (meals + groceries + takeout + social) > 50%` 且 `proteinHitRate < 60%` →「钱花出去了营养没跟上」（finance.js:196-198）；`supplement / total > 30%` →「补剂是锦上添花」（finance.js:212-214）。`.meals` 档仅由记餐派生，手动记账 UI 不提供。`budgetAdvice` 的 `proteinHitRate` 为参数注入（§2，来源 `DietEngine.periodDiet`）。
- **依赖**：基础层（读 `DietEntry` 模型，**不调 diet 引擎**）。
- **lifttime 对应**：`js/finance.js`（`:43-58` allExpenses、`:148-165` 预测、`:174-218` 蛋白性价比、`:61-135` 计划层——**2026-10-06 已移植**，语义锚定 planDays/planRange/planStatus/planAdvice/再来一期）。
- **测试**：移植 `finance.test.mjs` 中周/月 + auto 派生（`byCat.meals === 23`、`cat:'takeout'`/`'groceries'` 断言）+ 节奏预测 + 计外双口径 + 三档建议文案 + 蛋白性价比（¥/10g=3.65）的断言语义（~~自定义周期计划的用例随功能后置~~ **2026-10-06 已移植 13 项计划用例**：planDays 含首尾/三态/计外不计额度/拉回建议/再来一期推演/多计划不串）。

### 3.6 `report` 报告（五域聚合）

- **目标**：日简报 = 时间投入（总时长 + Top 分类）+ 昨晚睡眠（时长/起止/感受/午睡/睡眠债）+ 当日训练摘要 + 当日饮食汇总（训练日蛋白缺口标黄）+ 当日/当周开销与预算进度，五域合一；阶段综合报告（过去一天/一周/一月/自定义 ≤366 天）：区间换算（自定义含首尾、超 366 天拒）→ 五域聚合 `ReportData` → **规则版报告立即出**（数字 + 结论、按板块分组）。报告 JSON 结构同时是未来 AI 输出契约与渲染契约（规则版结构=AI 输出契约=渲染契约，一份渲染两用；AI 版第一版不实现，见 §9）。
- **依赖**：基础层 + 五个域引擎的**只读聚合 API**（唯一允许的横向依赖方向，签名清单 §2.1 为骨架冻结物 B）。
- **lifttime 对应**：`js/reportBuilder.js` + `analysis.js` 的 `dayBrief`。
- **测试**：移植 `reportBuilder.test.mjs` 断言语义（区间换算、五域聚合数值锚点：时间 130 分/睡眠债 90 分/总账 310 含计外 250 等、规则版各板块文案锚点；**例外**：`planOverlaps[0].status.pct === 6` 等自定义周期计划锚点（reportBuilder.test.mjs:77-79）随该功能后置，第一版不移植；AI 缺 overall 抛错的用例随 AI 后置）。

### 3.7 设置与数据管理（无独立功能模块）

设置页 UI 归 `settings` 界面分组；其 Core 逻辑全部在基础层：偏好读写（`AppSettings`）、导出/导入/清空（`BackupDocument` + `BackupSanitizer`）、时间分类管理（`time-tracking` 模块的分类语义）。第一版不设 AI 配置界面（AI 后置）。

---

## 4. 数据模型（Swift 结构体）

全部放 `Sources/SelfRecordCore/Model/`。统一约定：`Codable + Sendable + Equatable` 值类型；金额单位「元」、重量一律存 kg、时长一律存秒/分钟见字段名；ID 用 `UUID`（字符串 key 除外）；所有含自由文本的字段在净化管线中截断有界。

```swift
import Foundation

// MARK: - 枚举与基础值

/// 显示单位；内部存储一律 kg（换算只在展示层）
enum WeightUnit: String, Codable, Sendable { case kilogram, pound }

enum ThemeMode: String, Codable, Sendable { case system, light, dark }

/// 图表八色（Ely HUE_NAMES）+ 1 个中性档：时间分类取色用——天然白名单，
/// 等价 lifttime safeColor 防注入的思想（不允许任意色值进数据）。
/// neutral 非 Ely 源色，取 fg_muted 同值（#605D5A/#AFADAB），供「其他」这类
/// 无倾向分类使用（9 个默认分类对 8 hue 的补位）。
enum ChartHue: String, Codable, Sendable, CaseIterable {
    case blue, teal, ochre, rose, violet, green, rust, cyan, neutral
}

/// 「yyyy-MM-dd」日键。构造侧：init? 校验格式（非法即 nil）；
/// 解码侧：init(from:) 宽松接受（净化管线在解码后的值上重跑校验，非法字段归 nil
/// 保留整条记录——见 §4 净化管线第 2 步，实测强校验 init 会把整条丢掉）。
/// 语义 = Calendar.startOfDay；跨时区运算必须经由注入的 DayCalendar。
struct DayKey: RawRepresentable, Hashable, Codable, Sendable {
    var rawValue: String
    init?(rawValue: String)
    init(_ date: Date, calendar: DayCalendar)
}

// MARK: - 设置

struct AppSettings: Codable, Sendable, Equatable {
    var unit: WeightUnit = .kilogram
    var bodyweightKg: Double?              // 净化域 0–2000
    var theme: ThemeMode = .system
    var sleepGoalMinutes: Int = 480        // 净化域 240–720
    var weeklyBudgetYuan: Double?          // 净化域 0–1e7
    var monthlyBudgetYuan: Double?
    var aiConfig = AIConfig()
}

/// AI 配置（第一版仅占位与净化校验，网络层后置）。
/// apiKey 属 Keychain，永不落盘、永不进备份（lifttime 明文教训的修正）。
struct AIConfig: Codable, Sendable, Equatable {
    var baseURLString: String?             // 净化要求 http(s)
    var model: String = "glm-5.3-flash"
    var effort: AIEffort = .max
}

enum AIEffort: String, Codable, Sendable { case low, high, max }  // lifttime 白名单三档（ai.js:6），无 medium

// MARK: - 时间分配

struct TimeCategory: Codable, Sendable, Identifiable, Equatable {
    var id: String                         // ^[A-Za-z0-9_-]{1,40}
    var label: String                      // ≤64 字符
    var hue: ChartHue
    var isArchived: Bool = false
    var isFallback: Bool = false           // 兜底分类（默认「其他」）：恰好一个、不可删，
                                           // 删除/归档其它分类时其历史块归它（§3.1）
}

/// 单槽计时器：同一时刻只允许一个进行中事项（日常/睡眠互斥）。落盘，崩溃恢复用。
struct ActiveTimer: Codable, Sendable, Equatable {
    var startedAt: Date
    var kind: TimerKind
    enum TimerKind: String, Codable, Sendable { case general, sleep }
}

/// 已完成时间段（进行中不落 TimeBlock，走 ActiveTimer）。
struct TimeBlock: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var start: Date
    var end: Date                          // 净化要求 end > start
    var categoryID: String
    var note: String?                      // ≤2000
}

// MARK: - 睡眠

struct SleepSession: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var start: Date
    var end: Date                          // 净化：end > start 且 ≤24h
    var feel: Int?                         // 1–5，可空=未填
    var wakeCount: Int?                    // 0–3
    var latency: SleepLatency?             // 入睡快慢，可空
    var note: String?
    var dayOverride: DayKey?               // 手动归属，优先于 -4h 规则
}

enum SleepLatency: String, Codable, Sendable { case fast, ok, slow }

// MARK: - 训练

/// 12 肌群 key + 5 结构组（对应 lifttime exercises.js:4-25 的口径）
enum MuscleGroup: String, Codable, Sendable, CaseIterable, Hashable {
    case chest, shoulder, triceps, back, biceps, forearm
    case quad, hamstring, glute, calf, core, full
}
enum StructuralGroup: String, Codable, Sendable, CaseIterable, Hashable {
    case push, pull, legs, core, cardio
}

struct Exercise: Codable, Sendable, Identifiable, Equatable, Hashable {
    var id: String                         // 内置动作固定 key；自定义=UUID 字符串
    var name: String
    var aliases: [String]
    var primaryMuscles: [MuscleGroup]      // 主肌群
    var secondaryMuscles: [MuscleGroup]    // 次肌群
    var isCustom: Bool
    var isBodyweight: Bool                 // 自重：容量记 0、组数计入
    var isCardio: Bool
    var isEccentricHeavy: Bool             // 离心大：DOMS +1
}

struct WorkoutSet: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var weightKg: Double                   // 0 = 自重/无重量
    var reps: Int
    var timestamp: Date
}

struct WorkoutExerciseEntry: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var exerciseID: String
    var sets: [WorkoutSet]
}

/// 进行中训练（落盘，崩溃恢复）。
struct ActiveWorkout: Codable, Sendable, Equatable {
    var id: UUID
    var startedAt: Date
    var entries: [WorkoutExerciseEntry]
    var notes: String?
}

struct Workout: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var entries: [WorkoutExerciseEntry]
    var feeling: Int?                      // 1–5
    var notes: String?
    var analysis: WorkoutAnalysisSnapshot? // 生成时冻结的快照；详情页可再生成
}

// MARK: - 训练分析快照（规则版结构 = 未来 AI 输出契约 = 渲染契约）

enum DOMSLevel: String, Codable, Sendable { case severe, noticeable, moderate, mild }
enum IntensityBand: String, Codable, Sendable { case high, moderatelyHigh, moderate, light }

struct WorkoutTotals: Codable, Sendable, Equatable {
    var setCount: Int
    var repCount: Int
    var volumeKg: Double                   // 自重动作贡献 0
}

struct PRRecord: Codable, Sendable, Equatable, Identifiable {
    var id: String { exerciseID }
    var exerciseID: String
    var bestE1RM: Double
    var isNewBaseline: Bool                // true=首次基准，false=刷新纪录
}

struct AICredit: Codable, Sendable, Equatable {  // AI 覆写标记（后置启用）
    var model: String
    var effort: AIEffort
    var generatedAt: Date
}

struct WorkoutAnalysisSnapshot: Codable, Sendable, Equatable {
    var brief: [String]                    // 简评要点
    var postFeel: [String]                 // 练后感受建议
    var nextDayText: String                // 次日预期（DOMS 文案）
    var domsLevel: DOMSLevel
    var diet: [String]                     // 恢复饮食建议（读注入的实际蛋白摄入）
    var rest: [String]
    var prs: [PRRecord]
    var muscleVolume: [MuscleGroup: Double]  // 分摊后容量
    var groupSets: [StructuralGroup: Int]
    var totals: WorkoutTotals
    var intensityBand: IntensityBand
    var volumeVsRecentAverage: Double?     // vs 近 5 次均值
    var primaryMuscles: [MuscleGroup]
    var secondaryMuscles: [MuscleGroup]
    var ai: AICredit?                      // 非 nil=AI 覆写过
}

// MARK: - 饮食

/// 餐次六档（口径 = lifttime nutrition.js:5-12 MEALS，按训练关系而非纯时段）：
/// snack 为通用加餐；「晚 9 点后加餐」判定 = hour≥21 且 meal == .snack。
/// guessMeal 依时段推断，练后 2.5h 窗口预选 .postworkout；未知餐次回退 .snack。
enum MealSlot: String, Codable, Sendable {
    case breakfast, lunch, dinner, snack, preworkout, postworkout
}

/// 食物标签（lifttime foods.js:2-3，10 档）。挂库命中项；「无蔬果」「junk≥3」
/// 等日建议靠它聚合（nutrition.js:206-208，只算 items，不含手估项）。
enum FoodTag: String, Codable, Sendable {
    case protein, carb, veg, fruit, dairy, fat, junk, drink, supp, custom
}

/// 每 100g 营养 + 常用份（自学习库存的就是这个形状）
struct Per100g: Codable, Sendable, Equatable {
    var kcal: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
    var portionGrams: Double?              // 常用份克数（如「碗」=200g）
    var portionUnit: String?               // 份单位名（个/碗/杯…）
}

/// 食物库命中项（内置库或自学习库）。tags 来自库条目（lifttime guessFor 无标签，
/// 手估项不参与 tags 聚合——口径见 §3.4）。
struct FoodMatch: Codable, Sendable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var grams: Double
    var per100g: Per100g
    var tags: [FoodTag]
}

/// 手估项：三层兜底第②层的预填，可改、可整项不计入
struct ManualFoodItem: Codable, Sendable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var grams: Double
    var per100g: Per100g
    var isExcluded: Bool                   // true = 整项不计入
    var guessCategory: String?             // 8 大类猜测的类别名
}

struct MacroTotals: Codable, Sendable, Equatable {
    var kcal: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double
}

struct DietEntry: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var date: Date
    var meal: MealSlot
    var rawText: String                    // ≤2000
    var items: [FoodMatch]                // 库命中
    var manualItems: [ManualFoodItem]     // 手估
    var unmatched: [String]               // 未识别，不计入
    var totals: MacroTotals               // 保存时缓存（items+未排除 manualItems）
    var costYuan: Double?                 // 联动预算：>0 派生 auto 开销
}

/// 自学习食物库条目（每 100g 归一 + 使用计数；learnFood 产物默认打 .custom 标签）
struct CustomFood: Codable, Sendable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var per100g: Per100g
    var tags: [FoodTag] = [.custom]
    var useCount: Int
}

// MARK: - 预算

/// 开销分类（口径 = lifttime finance.js:5-13 EXP_CATS，健身饮食向）。
/// meals 仅由记餐 cost 派生的 auto 项使用，手动记账 UI 不提供该档；
/// 「外卖聚餐占比」「补剂占比」诊断依赖本口径（§3.5）。
enum ExpenseCategory: String, Codable, Sendable, CaseIterable {
    case meals       // 记餐开销（auto 派生专用）
    case groceries   // 食材采购
    case takeout     // 外卖外食
    case social      // 聚餐
    case supplement  // 补剂
    case fitness     // 健身相关
    case other       // 其他
}

struct Expense: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var date: Date
    var amountYuan: Double                 // 净化域 0–1e7
    var category: ExpenseCategory?
    var note: String?                      // ≤2000
    var isOutOfPlan: Bool                  // 计总账、不占周期额度
}

// MARK: - 跨域注入上下文（骨架冻结物，签名见 §2）

/// workout 分析引擎的恢复建议上下文
/// （lifttime workout.js:331-343 dayIntakeToday + fitnessTimeToday；
///   analysis.js:190-193/:211/:263 消费；nil 语义走通用建议分支）
struct RecoveryContext: Codable, Sendable, Equatable {
    var bodyweightKg: Double?
    var dayIntake: DayIntake?
    var fitnessTimeMinutes: Double?
}

struct DayIntake: Codable, Sendable, Equatable {
    var proteinG: Double
    var kcal: Double
    var itemCount: Int
    var hasPostMeal: Bool                  // meal == .postworkout 且 ts ≥ 训练开始（§3.4 练后判定）
}

// MARK: - 备份（导出/导入契约）

/// 全量备份文档。apiKey 永不出现；导入时全字段过 BackupSanitizer。
struct BackupDocument: Codable, Sendable, Equatable {
    var version: String                    // "selfrecord.v1"
    var exportedAt: Date
    var settings: AppSettings
    var categories: [TimeCategory]
    var timeBlocks: [TimeBlock]
    var sleepSessions: [SleepSession]
    var workouts: [Workout]
    var customExercises: [Exercise]
    var dietEntries: [DietEntry]
    var expenses: [Expense]
    var customFoods: [CustomFood]
}
```

净化管线语义（`BackupSanitizer` 与本地读盘共用，对应 lifttime `store.js:120-188` 的 cleanRecords/cleanSleepSessions 逐条 map + filter 语义；**Swift Codable 的默认行为与该语义相反——本机实测一条非法记录（如 `meal:"brunch"` 枚举或 `dayOverride:"2026/09/06"` 斜杠日期）会使整个数组 decode 抛 `DecodingError`，好条目一并丢失**，见 §13。因此净化必须显式实现为**三步元素级容错管线**，这是 Storage 层的硬性职责，验收标准即 store.test.mjs 的「非法睡眠会话剔除剩 2 条、越界字段归 nil」）：

1. **数组级元素容错**：逐元素 decode（`JSONSerialization` 拆元素逐条 decode，或 `LossyArray<T>` 包装器），单条 decode 失败**只丢该条**，不丢整组——对应 lifttime `cleanRecords` 的 filter；
2. **字段级宽容解码**：可恢复字段的解码失败**归 nil/默认值、保留整条**——`dayOverride` 格式非法 → nil（lifttime store.js:137 同）；`latency` 非法 → nil；`meal` 非法 → `.snack`（对齐 `mealOf` 未知回退 MEALS[3] 的读取语义）；`feel` 越界 → nil。实现手段：`DayKey` 与各枚举的 `init(from:)` 宽松解码（**failable `init?(rawValue:)` 是构造侧校验入口，不承担解码拒绝**——实测强校验 init 在 Codable 合成路径会把「仅 dayOverride 非法」的会话整条丢掉，违背「字段归 null」语义）；本机实测元素级容错后非法 `meal:"brunch"` 场景 2/3 好条目全部存活，见 §13；
3. **解码后值上重跑业务校验**：`end > start` 且 ≤24h、`feel ∈ 1–5`、金额/时长收敛合法域、分类 id 白名单正则、恰一个 `isFallback`——结构性非法（时间戳无效/end≤start）**整条剔除**（lifttime cleanSleepSessions return null → filter），越界数值收敛或归 null。

其余净化域：体重 0–2000；睡眠目标 240–720；金额 0–1e7；字符串截 2000；每集合上限 100_000；解码深度上限 6；未知字段一律丢弃（Codable 天然白名单，不透传）。

**净化语义修正（不移植 lifttime 缺陷）**：lifttime 的 `sanitizeState()` 返回值**不含 customFoods**（store.js:167-188），导入备份会静默清空自学习食物库——已知缺陷。SelfRecord 的 `BackupSanitizer` 必须保留 `customFoods` 域（BackupDocument 已含），移植 store.test.mjs 用例时**不**复刻丢字段行为，并补一条「导入后 customFoods 完整保留」的正向断言。

### 4.1 默认数据（骨架冻结物 A 的一部分）

时间分类默认 9 个（清单 = lifttime store.js:15-25 `DEFAULT_CATEGORIES`，语义不变；取色从 lifttime 十色自由色值改为 ChartHue 白名单档位，分配如下。**取色口径**：用户自建分类只可在 8 个彩色档中选择，`neutral` 为兜底分类专属档，UI 不提供选择）：

| id | label | ChartHue |
|---|---|---|
| `warmup` | 热身激活 | ochre |
| `strength` | 力量训练 | rose |
| `cardio` | 有氧 | rust |
| `stretch` | 拉伸放松 | green |
| `commute` | 通勤往返 | blue |
| `meal` | 备餐加餐 | violet |
| `supplement` | 补剂 | teal |
| `shower` | 洗漱整理 | cyan |
| `other` | 其他（**isFallback = true**） | neutral |

另：`AppSettings` 各字段默认值即 §4 定义；`ChartHue.neutral` 色值 = `fg_muted` 同值（§7.1），标注为非 Ely 源色的派生档。

---

## 5. 存储方案

**选型：自研分域 JSON 文件仓库（`DataStore` actor），不用 SwiftData / Core Data。**

理由（针对本机无 Xcode 的硬约束）：

1. SwiftData 的 `@Model` 是宏展开的 class，会把存储类型渗透进领域模型（违背「结构体定义 + Foundation-only 纯引擎」），其 container 生命周期与 Swift 6 严格并发检查在纯命令行 `swift test` 路径上不可验证；而 JSON + Codable 的净化、导出、测试全部是纯 Foundation 逻辑，可 100% 在 `swift test` 覆盖。
2. lifttime 的备份契约本来就是全量 JSON；导出/导入走 `BackupDocument` 保持等价，未来迁移 SwiftData 只需替换 `DataStore` 实现，引擎与模型不动（存储被 actor 协议隔离在 Storage 层内）。
3. 相对 localStorage 单键的改进照搬「分实体存储」思路：**按域分文件**，写入粒度小、崩溃损失面小、并行模块测试互不干扰。

设计：

```
<ApplicationSupport>/SelfRecord/
  settings.json        // AppSettings
  categories.json      // [TimeCategory]
  active.json          // ActiveTimer? + ActiveWorkout?   ← 崩溃恢复态，启动即读
  time.json            // [TimeBlock]
  sleep.json           // [SleepSession]
  workouts.json        // [Workout]
  exercises.json       // [Exercise]（自定义动作）
  diet.json            // [DietEntry]
  foods.json           // [CustomFood]
  expenses.json        // [Expense]
```

- **写入**：临时文件 + `rename` 原子替换（半写文件不可能出现）；每次变更立即写一次 + 150ms 防抖合并后续写（沿用 lifttime「commit 立即写 + 防抖再写」语义（store.js:210-216，防抖 120ms，此处取 150ms 同语义近值），高频逐组记录不产生序列化风暴）。
- **读取**：启动全量载入内存值类型快照；`DataStore` 是 actor，所有读写串行化；UI 层 `AppModel`（`ObservableObject` + `@Published`，MainActor，见 §8 约定 4/5）持有快照，编辑流程 = 快照 → 引擎纯函数 → 新快照 → `DataStore` 写回 → UI 自动刷新。
- **导出**：合并各域为单个 `BackupDocument` JSON（文件名带日期），AI Key 不含。
- **导入**：50MB 上限 + 格式预检 → `BackupSanitizer` **元素级容错净化**（§4 三步管线：逐条 decode 丢坏条不丢整组、字段级宽容归 nil、值上重跑业务校验）→ 覆盖确认（confirmationDialog 双确认）→ 整体替换各域文件。一条坏记录绝不允许判整个域死刑（Swift Codable 默认整组抛错的行为已被实测否决，§13）。
- **测试**：`DataStore` 目录参数化注入临时目录；净化管线用例移植 `store.test.mjs` 15 项断言语义（AI 配置净化后不丢、**非法睡眠会话剔除后好条目存活**、越界字段归 nil 而非丢整条、旧 timer 无 kind 归 general、原型污染键在 Codable 下天然不存在——补等价断言：未知字段不透传；另补：单条坏枚举/坏 dayOverride 混入数组时好条目存活）。

---

## 6. 页面地图（Tab × 页面）

底部 `TabView` 5 个 Tab（Ely 无底部 Tab 规范，控件形态用 iOS 原生 TabView + Ely 配色；标签与图标如下）。分组 id 即 `Sources/SelfRecordUI/<id>/` 目录名。

| Tab（分组 id） | 图标（SF Symbols） | 页面 | 职责与关键交互 |
|---|---|---|---|
| **今日** `today` | `house` | `TodayView` | 日简报，五域合一：日期前后翻页（toolbar 箭头）；进行中计时器常驻状态条（点按直达对应记录页）；五张域卡片：时间投入（总时长 + Top3 分类横条）、昨晚睡眠（时长/起止/感受/近 7 晚睡眠债——**不显示单夜分数**，分数归区间层 §3.2）、当日训练摘要（有则显示 PR 与 DOMS 等级徽标）、当日饮食（宏量环 + 训练日蛋白缺口标黄）、开销（日/周预算进度条）。卡片点击跳对应 Tab；五卡之下「阶段报告」入口卡（sheet：日/周/月三档 + 自定义 ≤366 天 → 渲染 RuleReport，§3.6「规则版报告立即出」/ §9-7 不可砍项） |
| **记录** `records` | `listBullet` | 顶部 `SRSegmented` 三段：时间 / 睡眠 / 饮食 | |
| | | `TimeView` | 单槽计时器大按钮（日常/睡眠互斥，占用中禁用另一个并引导）；24h 时间轴（**自定义一维条**，Swift Charts 无此图表，Canvas 实现，睡眠段叠加深色）；**区间三档（今日/近 7 天/近 30 天，SRSegmented，对应 lifttime time.js:31-36）**：今日=分类占比环形图+当日块列表，近 7/30=逐日堆叠柱（Swift Charts，数据来自 `TimeEngine.dailyBreakdown`）；块列表支持补记（sheet 表单）、编辑、滑删 |
| | | `SleepView` | 两击上床/起床（与日常计时互斥）；起床后问卷 sheet（三题可整页跳过——跳过不惩罚）；**「＋ 补记睡眠」入口 + 补录/编辑共用 sheet（2026-10-06 增：时间对校验、可选问卷字段、归属实时预览，编辑内含删除）**；近 7 天时长条形 + 逐夜分数折线（分数与均值一律出自 `SleepEngine.periodSummary`（区间中位锚，缺省 330），锚定规则 §3.2）；列表项点开调整归属 `dayOverride`（含「恢复自动」）；睡眠债与规律性摘要卡 |
| | | `DietView` | 记餐：自然语言输入框 + 解析确认卡（命中/手估/未识别三层标记，手估项可改克数可排除）；餐次选择（自动预选）；花费输入（联动预算）；日宏量总结 + 目标达成；日/周/月切换（SRSegmented）；日建议列表 |
| **训练** `workout` | `dumbbell` | `WorkoutListView` | 历史训练列表（日期/主练/容量/PR 徽标）+「开始训练」主按钮；进行中训练存在时顶部常驻恢复条 |
| | | `ActiveWorkoutView` | 动作搜索（精确/前缀/包含打分）+ 自定义动作引导（查不到→多选肌群 sheet）；逐组快速录入（重量×次数，键盘优先，复制上一组一键）；结束→生成分析快照并落盘 |
| | | `WorkoutDetailView` | 渲染分析快照（brief/postFeel/DOMS/PR/肌群容量图/强度带）；「按当前口径再生成」按钮（历史快照不漂移，再生成显式覆盖）；阶段分析入口（7/30/90 天） |
| **预算** `budget` | `creditcard` | `BudgetView` | 周/月切换（SRSegmented）；进度条 + 节奏预测（超速预警 + 拉回指引）；开销流列表（auto 项带「自动」徽标，点击引导去 DietView 编辑源头）；记一笔（sheet：金额/分类/计划外开关）；蛋白质性价比卡（¥/10g + 参考成本表对照） |
| **设置** `settings` | `gearshape` | `SettingsView` | 体重/单位(kg-lb)/主题(跟随系统+手动覆盖)/睡眠目标/周月预算 |
| | | `CategoryManagerView` | 时间分类增删改（取色 = 8 个彩色 ChartHue 档，**不含 neutral**——neutral 为兜底分类专属，避免自建分类与「其他」撞色；天然白名单）；删除/归档时历史归入兜底分类（isFallback，不可删）的确认说明 |
| | | `DataManagementView` | 导出 JSON（文件名带日期，AI Key 剔除）/ 导入（格式预检 + 净化 + 覆盖双确认）/ 清空（双确认）；存储占用概览 |

全局交互约定（iOS 原生替代 lifttime 的 DOM 弹层）：

| lifttime 交互 | SelfRecord 实现 |
|---|---|
| 底部弹层 openSheet（sticky） | SwiftUI `sheet`（表单类）/ `presentationDetents`；防误关表单用 `interactiveDismissDisabled` |
| toast | 自研 `SRToast` overlay 栈（Ely 规格：surface 卡 + 8 圆角 + Floating 阴影、5s、最多 4 条、Undo 型带倒计时线）——用于「已保存/可撤销」轻反馈 |
| Promise 确认弹层 | `confirmationDialog` / `alert`（破坏性操作红色角色） |
| 全页 innerHTML 重渲染 | 声明式自动刷新；时钟显示用 `TimelineView` |
| 侧栏导航 | 底部 `TabView`（5 Tab，见上表） |

---

## 7. Ely → SwiftUI 设计令牌映射

### 7.1 色彩（36 token → 代码色板，不用 Asset Catalog）

**实现方式（已定型并实测）：自研跨平台动态色构造器**，不依赖 `UITraitCollection` 字样、不依赖 `@Environment` 读 token、不依赖 Asset Catalog：

```swift
extension Color {
    /// Ely 语义色构造：亮/暗双值，运行时按系统外观解析（iOS/macOS 双平台）
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark ? NSColor(dark) : NSColor(light)
        })
        #else
        self = light
        #endif
    }
    init(hex: UInt32) { /* r/g/b 各 8 bit */ }
}
```

理由：①本机只有命令行工具，SwiftPM 处理 `.xcassets` 依赖 actool，CLT-only 环境不可靠；②代码色板纯 Swift，可 `swift build`、可给色板写单元测试断言 hex；③该构造器已在 macOS SDK + Swift 6 严格模式 typecheck 通过（§13；UIKit 分支因 iOS SDK 缺失未编译过，属 §0-1 的零验证面，但 API 用法为标准形态）。高对比度档用 `@Environment(\.colorSchemeContrast)` 在组件层切换（读环境值不是宏，可用）。

命名规则：Ely token `snake_case` → SwiftUI `Color.srCamelCase`；**全量 36 token 一一映射，色值以 `reference-ely.md` §1 两张表为准**（本表只列实现要点与差异项，实现时照抄参考文档，不得凭记忆造值）：

| Ely token | SwiftUI | 亮 | 暗 | 用途 |
|---|---|---|---|---|
| `bg` | `Color.srBackground` | `#FCFAF7` | `#131110` | 页面背景（暖，非纯灰） |
| `surface` | `Color.srSurface` | `#FFFFFF` | `#1B1917` | 卡片 |
| `sunken` | `Color.srSunken` | `#F6F4F1` | `#0E0D0B` | 分段轨道/禁用输入 |
| `overlay` | `Color.srOverlay` | `#FFFFFF` | `#201F1D` | 弹层表面 |
| `hover` / `active` | `srHover` / `srActive` | `#F2F0ED` / `#E9E7E5` | `#252422` / `#2C2B29` | 按压态 |
| `border` / `border_strong` | `srBorder` / `srBorderStrong` | `#E1DFDD` / `#CCCAC8` | `#2C2B29` / `#413F3D` | 1px 边框 |
| `fg` | `srForeground` | `#181613` | `#F3F1F0` | 一级文字 |
| `fg_muted` / `fg_subtle` / `fg_disabled` | `srForegroundMuted` / `…Subtle` / `…Disabled` | `#605D5A` / `#696764` / `#ACAAA8` | `#AFADAB` / `#94928F` / `#5C5A58` | 二/三/禁用文字 |
| `accent` | `srAccent` | `#181613` | `#F3F1F0` | **主色=墨色反转**（非品牌彩色） |
| `accent_hover` / `on_accent` | `srAccentHover` / `srOnAccent` | `#302D2B` / `#FCFAF7` | `#D9D7D5` / `#131110` | 主按钮 |
| `focus` / `link` | `srFocus` / `srLink` | `#3772BB` / `#2863AB` | `#69A1E8` / `#7EB1F3` | 焦点/链接 |
| `success` / `warning` / `danger` / `info` | `srSuccess` 等 | `#267B4C` / `#A25F12` / `#BA3E38` / `#2E69B2` | `#6BBC89` / `#E8B45E` / `#E5756E` / `#77ABEC` | 语义色（唯一允许的彩色） |
| `*_subtle` ×4 | `srSuccessSubtle` 等 | `#E7F9EC` / `#FEF2DD` / `#FFEFEC` / `#EBF4FF` | `#182C1F` / `#342611` / `#3A1D1B` / `#19273A` | 横幅/图标淡底 |
| `backdrop` | `srBackdrop` | `#181613` **32% α** | `#000000` **50% α** | sheet 遮罩（hex 尾字节 0x52/0x80 即透明度，勿写成 52%/80%） |
| `glass` | `srGlass` | `#FCFAF7` 72% α | `#131110` 72% α | 毛玻璃 |
| `shadow` | `srShadowColor` | `#181613` | `#000000` | 阴影色（暗色透明度数倍于亮色） |
| `chart[8]` | `SRChartPalette.hue(_:scheme:)` | `#5182C1,#009589,#AA732B,#B8636B,#8572BB,#539156,#B66946,#138DB1` | `#79A7E2,#4EB9AD,#CD995C,#DC8A90,#A998DD,#7CB57D,#D9906F,#56B2D4` | 图表（Blue,Teal,Ochre,Rose,Violet,Green,Rust,Cyan 顺序）；时间分类取色也走它（neutral 档=fg_muted 值，§4.1） |
| `selection` | — | `#3772BB` 20% α | `#69A1E8` 30% α | **不映射**：SwiftUI 文本选区色系统接管，不可定制；不实现 |
| `tooltip_bg` / `tooltip_fg` | `srTooltipBackground` / `srTooltipForeground` | `#181613` / `#FCFAF7` | `#373533` / `#F3F1F0` | 图表长按提示（Charts 无自定义 tooltip 钩子，第一版用系统样式，token 留位） |
| `paper` / `ink` | `srPaper` / `srInk` | `#FFFFFF` / `#181613` | `#F3F1F0` / `#181613` | 打印式语义（暗色以 palette.rs:283-284 源码真实值为准；paper≠surface 暗色） |
| 色盲安全八色 | `SRChartPalette.colorBlindSafeHue(_:scheme:)` | palette.rs:151-165 | 同左 | **后置**（token 留位，第一版不实现开关） |

原则：**组件只写语义名，从不写字面色值**；彩色只出现在语义色和图表 hue——「颜色承载含义而非装饰」。

### 7.2 字体

第一版用**系统字体**（SF 天然支持 Dynamic Type 与中文），Inter 捆绑后置（§9）。Ely 的 8 档字阶**不直接搬 pt 数值**（Ely 是桌面密度：Base 13pt 在 iOS 偏小，系统 body 为 17pt），而是**映射到系统 TextStyle**——由系统承载 Dynamic Type 缩放（也规避了 `@ScaledMetric` 宏，§0-2），字重三档叠加在 TextStyle 之上：

```swift
enum SRTextSize { case xs, sm, base, md, lg, xl, xxl, display }
// .srFont(.base, .regular) == Font.system(.subheadline) 等价封装（非宏实现）
```

| Ely 档 | px（Ely） | SwiftUI TextStyle | iOS 默认 pt（近似） | 典型用途 |
|---|---|---|---|---|
| Xs | 11 | `.caption2` | 11 | 徽标、小标签 |
| Sm | 12 | `.caption` | 12 | 副文本、Tab 文字 |
| Base | 13 | `.subheadline` | 15 | 控件正文默认 |
| Md | 14 | `.callout` | 16 | 统计单位、Lg 控件正文 |
| Lg | 16 | `.body` | 17 | 对话框标题 |
| Xl | 20 | `.title3` | 20 | 大标题 |
| Xxl | 24 | `.title2` | 22→24* | **统计数值默认** |
| Display | 32 | `.largeTitle` | 34 | 展示型大数字 |

\* `.title2` 默认 22pt 略小于 Ely 24：统计数值场景可叠 `Font.system(.title2).weight(.semibold)` 或固定 24pt+`.body` 相对缩放，由设计系统阶段定一种并全库统一。字阶整体观感的**真机校准列为真机回归清单第一项**（§11）。

字重三档：按钮与选中 Tab `medium`、对话框标题与选中分段 `semibold`、其余 `regular`。等宽（数字表格）用 `.system(.body, design: .monospaced)`。Ely 的 `font_scale` 全局缩放因子**后置**（Dynamic Type 已覆盖主要无障碍场景）。

### 7.3 度量与动效令牌

```swift
enum SRSpacing { static let xs: CGFloat = 4;  static let sm: CGFloat = 8
                 static let md: CGFloat = 12; static let lg: CGFloat = 16
                 static let xl: CGFloat = 20; static let xxl: CGFloat = 24 }   // gap_1/2/3/4/5/6
enum SRRadius  { static let sm: CGFloat = 4;  static let md: CGFloat = 6
                 static let lg: CGFloat = 8;  static let xl: CGFloat = 12 }    // Sm/Md/Lg/Xl
enum SRControlHeight { static let sm: CGFloat = 28; static let md: CGFloat = 32 } // 视觉高度；
// ⚠ iOS 触控目标 ≥44pt：视觉 28/32 的控件必须用 .contentShape + 最小 hit 区撑到 44
enum SRMotion {
    static let fast: Animation = .easeOut(duration: 0.12)   // FAST 120ms，进场
    static let base: Animation = .easeInOut(duration: 0.2)  // BASE 200ms，对称过渡
    static let slow: Animation = .easeOut(duration: 0.32)   // SLOW 320ms，滑块/指示条
    static let toggle: Animation = .spring(duration: 0.2, bounce: 0.03) // 阻尼弹簧过冲 1–5%
    // @Environment(\.accessibilityReduceMotion) 命中时统一替换为 .linear(duration: 0.001) 无位移
    //（读环境值不是宏，可用；本节已 typecheck 实证，§13）
}
// 三档阴影 SRShadow.raised/.floating/.modal：亮 α.06/.08/.14，暗色整体 ×3~5（Ely tokens.rs:476-495）
// 表面四层修饰器：.srSurface(.background/.sunken/.surface/.overlay) = 底色 + 1px srBorder
```

### 7.4 组件映射（DesignSystem 目录产出，各界面只许用这些）

组件实现总约束：**DesignSystem 内禁用 SwiftUI 宏**（§0-2）——不写 `@State` / `@Bindable` / `@ScaledMetric` / `@Entry`；无状态组件用纯 `View` 结构 + 传参，需要内部动画态的用 `@ObservedObject` 包装或改为调用方持有。

| Ely 组件 | SwiftUI 实现 | 迁就 iOS 的调整 |
|---|---|---|
| Button（8 变体） | `SRButton(style: .primary/.secondary/.outline/.ghost/.subtle/.success/.danger/.link)` | 高 28/32 + hit 区 ≥44；禁用 opacity 0.45；loading 占位转圈保留 |
| Input（三态边框） | `SRField`（默认 `srBorderStrong`、聚焦 `srFocus`、失败 `srDanger`；禁用 `srSunken`；清除按钮）；数字键盘场景包 `TextField` keyboard 型 | 圆角 6、高=控件高保留 |
| Switch 32×18 | 原生 `Toggle`（`.toggleStyle(.switch)` 定制 tint=srAccent）；标签右侧 | 过冲弹簧交给系统，时长对齐 SRMotion.toggle |
| Checkbox 16px | `Toggle` checkbox 风格或自绘 `SRCheck`（半选减号态保留给列表批量选择） | — |
| Tabs（2px 下划线滑动） | 页面内页签 `SRTabs`（Ely 规格：高 28、指示条 2px、SLOW 滑动）；**顶层导航用原生 TabView 底栏**，不用下划线式 | 侧栏导航 → 底部 TabView（iOS 习惯） |
| SegmentedControl | `SRSegmented`（sunken 轨道 + surface 滑块 + Raised 阴影、选中 semibold） | 系统 `Picker.segmented` 样式不可定制到此程度，自绘 |
| Toast | `SRToast` overlay 栈（§6） | 位置改底部居中（拇指区），倒计时线保留 |
| Dialog 宽 440 | 破坏性/阻断确认 → 原生 `alert`/`confirmationDialog`；表单弹层 → `sheet`（`.presentationDetents`） | lifttime adapt 第 7 条明确换原生 |
| Statistic | `SRStatCard`（标签 Sm muted 在上、数值 Xxl、前后缀 Md 基线对齐、`contentTransition(.numericText())` 滚动）；趋势箭头 up 好=success 可配 `downIsGood` | — |
| Badge | `SRBadge`（圆角 4、字号 11；计数封顶 99+；状态点 6px） | — |
| Chart | Swift Charts 封装 `SRChartContainer`（线宽 2、1px 网格发丝线、8 hue 双模式色板、暗色自动切）；**24h 时间轴 `Timeline24View` 自定义**（Canvas 绘制一维条 + 睡眠段叠加 + 当前时刻指示线） | donut/堆叠柱/横条/折线全走 Swift Charts |
| Avatar | 不需要（单用户应用）——不实现 | — |
| 主题切换 280ms cross-fade | 不做：跟随系统由 iOS 全局处理，仅设置里手动覆盖（`preferredColorScheme`） | lifttime adapt 第 11 条 |

---

## 8. 目录布局与实现约定

```
self-record/
├── Package.swift                 # platforms: [.iOS(.v17), .macOS(.v14)]
│                                 # ⚠ 必须声明 macOS：本机 swift build 以 host macOS 构建
│                                 # targets: SelfRecordCore / SelfRecordUI / SelfRecordCoreTests
├── Sources/
│   ├── SelfRecordCore/           # Foundation only，禁止 import SwiftUI/Charts
│   │   ├── Model/                # ── 基础层（骨架阶段冻结）──
│   │   ├── Storage/              # DataStore / BackupDocument / BackupSanitizer
│   │   ├── TimeKit/              # DayKey / DayCalendar / 格式化 / kg-lb
│   │   ├── TimeTracking/         # ── 功能模块（并行实现，目录=id）──
│   │   ├── Sleep/
│   │   ├── Workout/              # 含动作库数据与分析引擎
│   │   ├── Diet/                 # 含内置食物库数据
│   │   ├── Budget/
│   │   └── Report/
│   └── SelfRecordUI/             # SwiftUI + Swift Charts；禁止业务逻辑；禁 SwiftUI 宏
│       ├── DesignSystem/         # 令牌（§7）+ SR 组件 + SRChartPalette
│       ├── AppModel.swift        # ObservableObject 主线程状态容器 + DataStore 接线
│       │                         #（骨架产出的冻结外壳：域快照 @Published + 通用读写；
│       │                         #  各分组不改此文件，用 extension 分文件，见约定 4）
│       ├── iOS/                  # iOS-only 代码集中地（触感/Keychain/HealthKit 适配，
│       │                         #  全部 #if os(iOS)，本机零编译面收敛于此）
│       ├── Today/                # ── 界面分组（并行实现，目录=id）──
│       │   └── AppModel+Today.swift   # 各分组在自己目录内给 AppModel 加 extension
│       ├── Records/              #   （AppModel+Records.swift / +Workout / +Budget / +Settings 同理）
│       ├── Workout/
│       ├── Budget/
│       └── Settings/
├── Tests/
│   └── SelfRecordCoreTests/      # Swift Testing（import Testing）
│       ├── ModelSanitizeTests.swift      # 净化（基础层）
│       ├── TimeKitTests.swift            # DayKey/DayCalendar（基础层）
│       ├── TimeTrackingTests.swift       # 各功能模块一文件
│       ├── SleepTests.swift
│       ├── WorkoutAnalysisTests.swift
│       ├── DietNutritionTests.swift
│       ├── BudgetFinanceTests.swift
│       └── ReportBuilderTests.swift
├── app/                          # 不参与 swift build（不在任何 target 内）
│   ├── SelfRecordApp.swift       # @main 入口 + 根 TabView（按 §6 接线）
│   └── project.yml               # XcodeGen：App target 引用 app/ 与本地两个
│                                 # package，iOS 17+，明暗主题，显示名 SelfRecord
├── docs/                         # 本文档 + 两份参考分析
└── reference/                    # 外部参考材料（lifttime/ ely/），.gitignore 忽略
```

实现约定（骨架阶段按此搭，模块/界面工程师按此并行）：

1. **swift-tools-version 6.0+**，严格并发检查开着过；引擎全值类型 + `Sendable`，`DataStore` actor，`AppModel` 为 `final class … : ObservableObject`、`@MainActor`。
2. 测试统一 **Swift Testing**（`@Test` / `#expect`）；测试时间锚定固定时区：`DayCalendar(timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)`，绝不依赖宿主时区（lifttime「固定 NOW + 本地构造 Date」手法的等价物，对应 adapt 第 14 条）。
3. 模块工程师只改 `Sources/SelfRecordCore/<自己的 id>/` 与 `Tests/SelfRecordCoreTests/` 自己的测试文件；界面工程师只改 `Sources/SelfRecordUI/<自己的分组 id>/`。基础层（Model/Storage/TimeKit）与 DesignSystem 由骨架/设计系统阶段产出后视为共享只读（= §2 冻结物 A/B/C），发现缺口报修复工程师，不私改。
4. **AppModel extension 协议（冻结物 C）**：`AppModel.swift` 只含 DataStore 装配、各域只读快照（`@Published`）与通用保存入口，由骨架产出后冻结；每个界面分组在**自己目录内**建 `AppModel+<分组>.swift`（extension AppModel）放自己页面的动作方法；跨域取数只经 §2.1 聚合 API 组装（如 `RecoveryContext` = `DietEngine.dayIntake` + `TimeEngine.fitnessMinutes`），不改 AppModel 本体——五个分组并行零共享可变文件。
5. **SwiftUI 宏禁令（全 UI 包，含 DesignSystem）**：禁 `@State` / `@Observable` / `@Bindable` / `@ScaledMetric` / `@Entry` 等一切 SwiftUI **宏**（§0-2 实测宏插件缺失）；状态管理 = `ObservableObject` + `@Published` + `@ObservedObject` / `@StateObject` / `@EnvironmentObject`（propertyWrapper，实测可编译）。此约定是 swift build 门控的硬性前提。**例外（View 内非宏 propertyWrapper 不在禁令内）**：`@FocusState` / `@Namespace` 等是 propertyWrapper 不是宏，View 内可用（实测编译通过）；但**焦点态不得挪进 ObservableObject**——`.focused(_:equals:)` 需要 `FocusState<Value>.Binding`，`@Published var` 的 `Binding<Field?>` 类型不匹配（实测编译失败），表单焦点管理留在 View 内用 `@FocusState`。
6. UI 包内 iOS 独有 API（UIKit 触感、HealthKit、Keychain 等）一律 `#if os(iOS)` 包裹并集中放 `Sources/SelfRecordUI/iOS/`，且必须保证缺省分支可编译；共享代码只用 SwiftUI/Charts 跨平台子集。注意：**iOS 分支本机从未编译过**（§0-1），写薄、写少。
7. 引擎无状态：每个模块的公开 API = `enum XxxEngine { static func … }` 纯函数 + 输入输出值类型；需要「历史」的函数（PR、近 5 次均值）显式收 `[Workout]` 或预聚合上下文参数，不持有存储引用。
8. 动作库（110+）与食物库（320+）数据以 Swift 静态数组源码形式放各自模块目录（`ExerciseLibrary.swift` / `FoodLibrary.swift`），不做成资源文件——可编译期检查、可测试、无 actool/资源管线依赖。

---

## 9. 范围取舍

**保留（灵魂，不可砍）**：

1. 两击记录 + 可跳过问卷不惩罚（睡眠分中性分）。
2. 睡眠 -4h 归属 + dayOverride（8 边界用例锁语义）+ 午睡识别 + 睡眠分 + MAD 规律性 + 睡眠债缺夜语义（medAnchor 默认 330 等口径细节见 §3.2）。
3. 完整训练分析口径：分摊 1/n 与 0.5/n、Epley 15 封顶、PR 刷新 vs 首次、DOMS 加权计分、恢复建议（RecoveryContext 完整契约）、7/30/90 阶段分析。
4. 中文饮食解析（含市制两=50g、长名优先）+ 三层兜底 + 自学习食物库 + 训练日蛋白达标率。**餐次六档与食物 tags 口径 = lifttime 原样**（§3.4——练后餐判定、无蔬果/junk 建议、晚加餐统计全依赖）。
5. 预算×饮食联动招牌：记餐花费 auto 入账、蛋白质性价比 ¥/10g + 参考成本表、计划外开销双口径、外卖聚餐/补剂占比诊断。**开销分类 7 档 = lifttime 原样**（§3.5——诊断口径依赖，不采用通用记账分类）。
6. 分析快照落盘（历史不漂移）+ 详情页可再生成。
7. 五域日简报 + 规则版阶段报告；**报告 JSON 结构 = 未来 AI 输出契约 = 渲染契约**（AI 接缝：`WorkoutAnalysisSnapshot.ai: AICredit?` 字段、`estimateSource` 概念已就位，接 AI 只加网络层不改模型）。
8. 不可信输入净化管线 + 导出备份剔除 Key（并修正 lifttime 净化丢 customFoods 的缺陷，§4 注记）。
9. 跨域联动六件套：练后餐预选、恢复建议读实际摄入（RecoveryContext）、训练日蛋白达标率、花费自动入账、**训练耗时聚合（fitnessMinutes）**、五域简报。

**舍弃（明确不要，带理由）**：

1. Service Worker / PWA 安装 / 检查更新整套——原生 App 由 App Store 管更新。
2. 手写 SVG 图表——Swift Charts 覆盖；仅 24h 时间轴自定义 Canvas。
3. localStorage 单键全量 JSON + innerHTML 整页重渲染 + 手动 tick 计时器——换分域 JSON + 声明式 UI + TimelineView。
4. Ely 侧栏导航、桌面悬停语义（hover 态在触摸设备无意义）、Avatar/表格等桌面组件——iOS 底部 Tab + 触控习惯。
5. AI 网络层（GLM 调用、URLSession 客户端、稳健 JSON 解析、错误分类、AI 配置界面）——第一版规则版全量兜底已可用；数据契约已留接缝，作为 v1.x 整体后置（`ai.test.mjs` 39 项断言随后移植）。
6. ~~自定义周期预算计划（planRange/planStatus、多并存、再来一期）——保留双口径语义在周/月上，自定义周期后置~~ **2026-10-06 已实装**（用户验收反馈补齐）：`BudgetPlans.swift` 计划层 + `BudgetPlansSection.swift` 页面区块，`finance.test.mjs` 计划用例已移植。遗留接缝：计划未纳入 `BackupDocument` 备份域、Report 的 planOverlaps 锚点仍后置。
7. HealthKit 睡眠自动读取——接缝已留（睡眠段可由外部喂入 `SleepEngine`），但 HealthKit 无法在本机命令行验证，第一版两击手动 + 问卷为唯一录入路径，HealthKit 导入作为 v1.x iOS-only 增强项。
8. Inter/JetBrains Mono 字体捆绑——第一版系统字体 + Dynamic Type；视觉差异主要在拉丁字形，中文界面影响小。Ely 的 `font_scale` 全局缩放因子与色盲安全八色开关同此后置（token 已留位，§7.1/§7.2）。
9. 多语言/单位本地化——第一版简体中文 UI + kg/lb 双单位显示换算（内部恒 kg）。
10. 睡眠规律分的圆刻度修正（§3.2 已知缺陷照抄保锚点）——修正即改测试锚点，v1.x 显式决策。

**克制原则**：一个可用且有灵魂的第一版 = 五域记录全通 + 全部规则引擎 + 跨域联动 + Ely 设计语言；任何「智能」能力（AI 简评/估算/报告重写）都不阻塞第一版。

---

## 10. 测试策略

- 移植 lifttime 319 项断言中第一版范围内的约 **265 项语义**：sleep 48 + workout(analysis) 55 + diet(nutrition) 74 + budget(finance) 53（自定义周期部分后置）+ report(reportBuilder) 35（计划进度 6% 等自定义周期锚点后置）+ 净化(timer 兼容等) 15 中 applicable 部分；数值锚点（睡眠分 93/100/73/63/85/86、PR 62×8≈78.5、蛋白性价比 3.65 等）原样照搬为 `#expect` 精确断言。
- `time-tracking` 无 lifttime 测试基线，自建：计时器互斥/恢复、end>start、跨午夜聚合、近 7/30 逐日聚合、分类删除归并、导入后分类引用完整性。
- 存储测试：临时目录注入，覆盖原子写、防抖合并、损坏文件（半写 JSON）启动降级、**元素级容错净化端到端**（单条坏枚举/坏 dayOverride/坏时间戳混入数组：坏条剔除/字段归 nil、好条目全部存活——§4 三步管线的验收测试）。
- 所有时间敏感用例固定 `TimeZone(secondsFromGMT: 8*3600)`；禁止 `Date()` 裸用，函数收 `now: Date` 参数。
- UI 不写单元测试（无 Xcode 无法 UI 测试），靠 `swift build` 编译门控 + Core 全覆盖保证正确性。

---

## 11. 风险与对策

| # | 风险 | 对策 |
|---|---|---|
| 1 | **iOS 分支本机零编译**（iOS SDK 不存在，§0-1 实测）——不只是不能运行，`#if os(iOS)`/`canImport(UIKit)` 内的代码从未编译过 | iOS-only 代码薄化并集中到 `Sources/SelfRecordUI/iOS/`（§8 约定 6）； UIKit API 用法保持标准形态；交付报告明示真机首轮编译预期爆雷点集中于此 |
| 2 | **SwiftUI 宏插件缺失**（§0-2 实测：含 `@State` 的包 swift build 直接失败） | 全 UI 包宏禁令（§8 约定 5），状态管理走 ObservableObject 路径（已实测可编译）；骨架阶段把「ObservableObject + Charts + sheet」端到端样例跑通供各组参照 |
| 3 | `app/project.yml`（XcodeGen）产出**本机零验证**（xcodebuild 需要 Xcode、xcodegen 未安装，§0-3 实测） | project.yml 保持最小常规配置（App target + 两个本地 package + iOS 17+）；README 写明生成与首开步骤；装配后未验证状态在交付报告中明示 |
| 4 | 字阶观感未校准（Ely 桌面密度 → iOS TextStyle 映射是我方决策，无真机验证） | §7.2 映射表固定档位全库统一；**字阶校准 = 真机回归清单第一项** |
| 5 | Swift 6 严格并发报错潮（模块工程师各自踩坑） | 架构已定型：引擎=值类型纯函数+Sendable、存储=actor、UI=ObservableObject MainActor；骨架阶段先跑通一条端到端样例供参照 |
| 6 | 并行开发破坏目录隔离 / 私改共享类型 / 共改 AppModel | 基础层 + 聚合 API 签名 + AppModel 外壳 = 三件冻结物（§2）；跨域只走「共享模型」与「参数注入」两通道；AppModel extension 分文件（§8 约定 4） |
| 7 | `[MuscleGroup: Double]` 等 Codable 字典、带校验 init 的类型在解码路径出意外 | 净化管线解码测试覆盖这些类型的非法输入（非法 dayOverride、越界 feel 等已在 store.test.mjs 语义内） |
| 8 | iOS 后台限制导致计时器「停在后台」 | 模型只存 `startedAt` 时刻不依赖后台 tick，回前台重算（lifttime 同思路，天然兼容）；界面用 TimelineView 渲染流逝时间 |
| 9 | Swift Charts 轴/交互在 macOS 预览与 iOS 实机差异 | 图表封装进 `SRChartContainer` 单点收口；24h 时间轴自绘 Canvas 减少依赖 |
| 10 | 移植数值锚点时口径漂移（分摊系数、封顶值、medAnchor 默认值、tags 聚合范围等） | 测试语义 1:1 移植并引用 lifttime 源行号注释（§3 各模块已锚定）；已知缺陷（规律分线性差、净化丢 customFoods）照抄/修正的决策已写死（§3.2/§4），不留实现期自由发挥 |

---

## 12. 实现约定（骨架阶段可在此节补充工程细节）

> 本节由「核心骨架工程师」维护，约定目录/命名/平台声明等落地细节；上文的模块与目录规则是骨架的输入。初始内容即 §8 的 8 条约定 + 目录树。
>
> **（2026-10-06 骨架已落地，以下为实装约定与环境事实，模块/界面工程师开工前必读。）**

### 12.1 构建与验证基线（本机实跑）

- `Package.swift`：swift-tools 6.0、platforms `.iOS(.v17)+.macOS(.v14)`、`swiftLanguageModes: [.v6]`；targets = SelfRecordCore / SelfRecordUI（依赖 Core）/ SelfRecordCoreTests；products = 两个 library（供 `app/project.yml` 引用）。
- 骨架自查（本机实跑，2026-10-06）：`swift build` 通过（干净全量构建亦通过）；`swift test` 30 项全过（经 `./scripts/test.sh`，见 12.4——**不要用裸 `swift test`**）。

### 12.2 目录裁决表（骨架实装）

§3 的模块 id（kebab-case）是逻辑 id；实际目录用 PascalCase（= §8 目录树口径）：

| 模块 id（§3） | Core 目录（Sources/SelfRecordCore/…） | 占位文件 |
|---|---|---|
| time-tracking | `TimeTracking/` | `TimeEngine.swift` |
| sleep | `Sleep/` | `SleepEngine.swift` |
| workout | `Workout/` | `WorkoutEngine.swift` |
| diet | `Diet/` | `DietEngine.swift` |
| budget | `Budget/` | `BudgetEngine.swift` |
| report | `Report/` | `ReportEngine.swift` |

UI（Sources/SelfRecordUI/）：`AppModel.swift`（冻结外壳）+ 分组目录 `Today/ Records/ Workout/ Budget/ Settings/`（各含 `AppModel+<分组>.swift` 占位 extension）+ `DesignSystem/`（占位，设计系统阶段产出）+ `iOS/`（iOS-only 收敛地）。

类型落位裁决（§3.0 表格与 §4「全部放 Model/」的表述差异，以 §8 目录树为准）：
- `DayKey` / `DayCalendar` / `DateSpan` / `Formatting`（时长/宏量格式化 + kg↔lb）→ `TimeKit/`；
- `BackupDocument` / `ActiveStateRecord`（active.json 落盘形状）/ `BackupSanitizer` / `DataStore` → `Storage/`；
- 其余 §4 结构体 → `Model/` 按域分文件（Basics / Settings / TimeModels / SleepModels / WorkoutModels / DietModels / BudgetModels / Contexts）。

测试（Tests/SelfRecordCoreTests/）文件归属：`TimeKitTests.swift` / `ModelSanitizeTests.swift` 归**基础层**（骨架维护，任何人不得改）；其余 6 个（TimeTrackingTests / SleepTests / WorkoutAnalysisTests / DietNutritionTests / BudgetFinanceTests / ReportBuilderTests）归各模块工程师独占。占位测试断言冻结签名桩可调用——模块工程师实现后**保留并扩充**，不得删除签名断言。

### 12.3 冻结物的实装形态

- **冻结物 A（基础层）**：`Model/` + `Storage/` + `TimeKit/` 已全量实现（§4 结构体、§4.1 默认 9 分类、三步净化管线、DataStore actor 原子写 + 150ms 防抖）。模块工程师只读；缺口报修复工程师。
- **冻结物 B（§2.1 聚合 API 签名）**：已写成**可编译的引擎桩**——各模块占位文件内的签名逐字照抄 §2.1，返回类型为空壳 struct（模块工程师填字段、替换桩体，**签名一个字符不改**）；测试占位断言桩可调用，签名漂移直接编译失败。`FITNESS_CATS` 已冻结在 `TimeTracking/TimeEngine.swift`（顶层常量）。`budgetAdvice(week:month:sumWeek:proteinEconomy:proteinHitRate:)` 的参数类型未在文档定型，以注释契约形式放 `Budget/` 占位文件，由 budget 工程师按 finance.js 定型（参数名与语义不得偏离 §2）。
- **冻结物 C（AppModel 外壳）**：`Sources/SelfRecordUI/AppModel.swift`（`@MainActor final class … ObservableObject` + `@Published` 域快照（`internal(set)`，分组 extension 可写、View 只读）+ loadAll / 每域 save / exportBackup / importBackup / eraseAll）。各分组只在自己目录的 `AppModel+<分组>.swift` 加 extension，不改本体。

### 12.4 ⚠ 本机跑测试的环境事实（统一验证必读）

与 §0-2 的 SwiftUIMacros 缺失同源（CLT 工具链插件不全），2026-10-06 骨架阶段实测发现的新事实：

1. Swift Testing 的宏插件 `libTestingMacros.dylib` 在 CLT 里位于 `usr/lib/swift/host/plugins/testing/` **子目录**，swift 编译不自动搜索 → 裸 `swift test` 报 `external macro implementation type 'TestingMacros…' could not be found`。插件本体存在，`-Xswiftc -plugin-path <该目录>` 显式补搜索路径即可。
2. ⚠ 不要用 `-load-resolved-plugin <dylib>##TestingMacros` 方案：该参数是 driver 级「已解析插件」清单，swift-driver 批量模式派生 frontend 子任务时会**丢失**（实测：增量构建首跑、`swift build` 后首跑等状态转换边界随机失败，可连续多轮）；`-plugin-path` 是插件**搜索目录**参数，随每个派生 frontend 进程继承，实测 5 类构建状态（干净全量/增量/build 后首跑/touch 后/再增量）连跑全绿。

⇒ **统一测试入口 = `./scripts/test.sh`**（内置 `-plugin-path` 参数 + 失败重试 + 清 `.build` 全量兜底；2026-10-06 实测多轮全绿，30 tests）。`swift build`（不含测试）不受影响，裸命令即可。换机器 / 安装完整 Xcode / CLT 修复后，`scripts/test.sh` 可简化回裸 `swift test`。

### 12.5 净化与解码的骨架裁决（§4 未逐条写死之处，以代码注释为准）

- 宽松 `init(from:)` 类型清单：`DayKey`（任意 String，不承担解码拒绝）、`MealSlot`→`.snack`、`WeightUnit`→`.kilogram`、`ThemeMode`→`.system`、`ChartHue`→`.neutral`、`AIEffort`→`.max`、`TimerKind`→`.general`；`SleepLatency` / `ExpenseCategory` 不写宽松 init（在 `SleepSession` / `Expense` 字段层归 nil）。
- 字段级宽容自定义 `init(from:)`（带默认值字段缺 key 归默认、可恢复字段类型错归 nil、必填失败才丢整条）：`SleepSession` / `DietEntry` / `Expense` / `AppSettings` / `AIConfig` / `TimeCategory` / `ActiveTimer` / `Exercise` / `CustomFood` / `ManualFoodItem`。
- 值上校验裁决：`bodyweightKg` / 预算字段越界 → **nil**（不 clamp，不可信值不修不造）；`sleepGoalMinutes` / `amountYuan` → clamp 到域；`TimeBlock.categoryID` 不合 `^[A-Za-z0-9_-]{1,40}$` → 整条剔除；恰一 `isFallback` 修正（无则补位 `other`，多则保首个清余）。
- 记录内嵌数组（`items` / `manualItems` / `unmatched` / `aliases` 等）的元素级递归宽容**不展开**：坏数组整组归空、整条记录保留（骨架简化，`totals` 缓存字段仍在，损失可控）。
- `BackupDocument.version` 导入时归一 `currentVersion`，未知版本串不透传。

### 12.6 其他骨架裁决

- `DayCalendar` 默认历法固定公历（`Calendar.current` 会随用户区域取到佛历/和历，日键会出非公元年）；不预设 `firstWeekday`（budget「自然周周一起」由 budget 模块自行构造注入）。
- Core 公开类型的 memberwise init 全 public（`SelfRecordUI` / app 入口跨 target 取数需要）。
- 首启 / 导入空分类文档 → `AppModel.loadAll` 播种 `TimeCategory.defaults`。
- `Formatting` 展示格式与 kg↔lb（1 lb = 0.45359237 kg 国际磅精确定义）为骨架最小实现；格式细节调整走修复工程师。
- `DataStore.save(active:)` 传 nil 也落盘（写空 `ActiveStateRecord`，清空崩溃恢复态）。

---

## 13. 本文档的验证记录（全部命令在本机实跑，2026-10-06，Swift 6.4 / swift-driver 1.168.6 / host macOS arm64）

**v1（2026-10-06 上午）**

- §4 数据模型代码块**提取为单文件并补两处桩**（`DayKey` 两个 init 的桩体、`DayCalendar` 占位——文档中的声明无函数体，原样不可编译，此为措辞修正：非「全文提取即过」），`swiftc -typecheck -swift-version 6` 通过——含 `DayKey`（failable RawRepresentable 的 Codable 合成）与 `[MuscleGroup: Double]` 字典 Codable 合成，严格并发 Sendable 检查无警告。
- §7.3 令牌代码块（import SwiftUI），`swiftc -typecheck -swift-version 6` 通过。

**v2（2026-10-06 下午，按评审意见修订时新增）**

- 环境探针（结论进 §0）：
  - `xcrun --sdk iphoneos --show-sdk-path` → `error: SDK "iphoneos" cannot be located`（iOS SDK 不存在）；
  - `xcode-select -p` → `/Library/Developer/CommandLineTools`；`xcodebuild -version` → `error: tool 'xcodebuild' requires Xcode`；`which xcodegen` → 未安装；
  - `ls /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/` → 仅 `libObservationMacros.dylib`、`libSwiftMacros.dylib`，无 SwiftUIMacros。
- **SwiftUI 宏探针**：SwiftPM 临时包（swift-tools 6.0、platforms `.iOS(.v17)+.macOS(.v14)`）含 `@State`/`@Observable` → `swift build` **失败**（`external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`）；同包改为 `ObservableObject` + `@Published` + `@ObservedObject`/`@StateObject`/`@EnvironmentObject` + `import Charts`（BarMark）+ `sheet`/`presentationDetents`/`interactiveDismissDisabled`/`confirmationDialog` → `swift build` **通过**（BUILD_EXIT=0）。⇒ §0-2 宏禁令与 §8 约定 5 的事实依据。
- **跨平台色板探针**：§7.1 的 `Color(light:dark:)` 构造器（canImport(UIKit)/canImport(AppKit) 分支）在 macOS SDK 下 `swiftc -typecheck -swift-version 6` 通过（AppKit 分支首稿 `NSColor(name: .dynamic)` 报错，修正为 `NSColor(name: nil)` 后通过——UIKit 分支因 iOS SDK 缺失未编译，见 §0-1）。
- **修订后模型代码**：§4（含 MealSlot 六档、FoodTag、FoodMatch.tags、CustomFood.tags、ExpenseCategory 七档、isFallback、RecoveryContext/DayIntake、AIEffort 三档）重新提取+同款桩，`swiftc -typecheck -swift-version 6` 通过（结果见下方当次运行记录）。
- lifttime 源码核对：评审引用的 `nutrition.js:5-12/:145-149/:206-208/:239-243`、`foods.js:1-16`、`finance.js:5-13/:192-218`、`workout.js:10-14/:326-345`、`analysis.js:188-215/:258-268`、`store.js:14-30/:219-226`、`settings.js:1-12`、`sleepMath.js:94-100/:123-127`、`ai.js:1-10`、`time.js:28-40`、`tests/{reportBuilder,finance,nutrition}.test.mjs` 相关行均已逐一打开核对，口径与本文档 §3/§4 一致。

**v3（2026-10-06 下午第二轮，按终审意见修订时新增）**

- **元素级解码实验（A1 依据）**：swift 脚本（§13 文末注明路径）实测——① `[DietEntry]` JSON 含一条 `meal:"brunch"`（非法枚举）：整组 `JSONDecoder().decode` 抛 `DecodingError`（2 条好记录一并丢失）；`[SleepSession]` 含一条 `dayOverride:"2026/09/06"`（斜杠格式）同样整组抛错。② 改为逐元素 decode（JSONSerialization 拆条 + 单条 decode，dateDecodingStrategy=.iso8601）：`meal:"brunch"` 场景 2/3 好条目存活、坏条被丢。③ `DayKey` 用强校验 `init?(rawValue:){nil}` 桩时，Codable 合成路径对非法 dayOverride **把整条 SleepSession 丢掉**（而非字段归 nil）——证明「failable 校验 init 不承担解码拒绝、净化须在值上重跑」的 §4 设计。
- **@FocusState 探针（B3 依据）**：SwiftPM 探针包内 `@FocusState`/`@Namespace` 于 View 中编译通过；`@ObservedObject` 模型上 `@Published var focusField: Field?` 接 `.focused($model.focusField, equals:)` 编译失败：`cannot convert value of type 'Binding<Field?>' to expected argument type 'FocusState<Value>.Binding'`——§8 约定 5 例外条款的依据。
- **源码核对（本轮新增）**：`nutrition.js:222-229`（dailyAdvice ctx.workoutsToday + targets(bodyweight, trained)）、`sleepMath.js:36-41`（nightForDay 只取段）、`reportBuilder.js:83-90`（区间 medAnchor→逐夜 sleepScore）、`report.js:172-176`（日简报睡眠区无单夜分数）、`budget.js:422-443`（proteinHitRate=pd.proteinHitDays/pd.daysTracked 动态计算）、`finance.test.mjs:75-79`（0.4 为 fixture）、`store.js:120-140`（cleanRecords 逐条 map+filter、cleanSleepSessions 字段收敛语义）、`store.js:15-25`（DEFAULT_CATEGORIES 行号更正）、`store.js:210-216`（防抖 120ms）——均已打开核对。

**未验证项（如实说明）**：工作区尚无 Package.swift 与任何 Swift 源码（本文档即它们的输入），`swift build`/`swift test` 的工程级运行未发生；iOS/UIKit 分支代码、`app/project.yml` 产出、UI 真机行为均零验证（§11 风险 1/3/4）。
**更新（2026-10-06 骨架阶段）**：上一段的「无 Package.swift 与源码」已过时——骨架已落地（§12），`swift build` 通过、`swift test` 30 项全过（经 `./scripts/test.sh`，环境事实见 §12.4）；iOS/UIKit 分支、`app/project.yml` 产出、UI 真机行为仍零验证（§11 风险 1/3/4）。

（完）
