# SelfRecord 交付报告

> 交付日期：2026-10-06 · 代码规模：Sources 下 Swift 源码约 15,600 行（Core + UI，`wc -l` 实测）· 测试：198 tests / 38 suites 全绿（本机实测，构成见 §5.1）
>
> **结论先行**：在第一版范围内（范围边界见下）功能全部落地：五个数据域（时间分配 / 睡眠 / 训练 / 饮食 / 预算）的记录与分析逻辑 + 一层跨域聚合报告，Core 逻辑经 198 项测试全绿验收，本机干净全量编译通过。**「第一版范围」的边界**：AI 能力（食物估算第三层、AI 报告）、HealthKit 睡眠自动读取、自定义周期预算计划、字体与无障碍细化、睡眠规律分圆刻度修正，共五类按设计决策显式推迟到 v1.x；PWA 底座（Service Worker 等）按设计决策显式舍弃（出处：docs/design.md §9，本次已读核实）。**最大的未验证面**：本机无 Xcode，iOS 侧从未编译、App 从未运行（量级判断见 §5.4，如实声明见 §5.2）。
>
> 验收时唯一的中等级缺口「五域阶段报告有引擎无 UI 入口」在验收后已补上入口接线（代码层，本次经源码核实；**未经运行验证**，判定依据与限制见 §1.4）；遗留问题均为文档级不一致与环境适配项，不影响 Core 测试结论。

**名词速览**（详见 §0.3 术语表）：**五域** = 时间 / 睡眠 / 训练 / 饮食 / 预算五个数据域；**报告**是在五域之上的第六个聚合模块；**净化** = 备份导入时的数据清洗管线；**lifttime** = 功能蓝图与测试基线的参考项目（一个生活量化 PWA）。

---

## 0. 怎么读这份报告：依据与材料说明

### 0.1 三层事实标注

全文每个结论按证据层级标注：

- **〔实测〕**：本报告撰写会话在本机实际执行的命令与读取（完整命令与输出见附录 A），**可由所有者原样复跑复核**；
- **〔模块自查〕**：六个模块工程师交付时的自查报告摘要——**属「待复核的声明」，不是本报告验证过的事实**；
- **〔验收〕**：独立验收轮的核查结论——同上属声明，但其中引用了源码行号，本次从中抽验了若干处（见 §5.1，抽验的四处全部吻合）。

### 0.2 「材料」是什么、在哪

〔模块自查〕与〔验收〕的内容来自**本报告撰写任务随附的交付工作流记录**（设计方案、六模块实现自查摘要、界面实现清单、验收结论与验收发现，以结构化文本形式提供）。**它们不是本仓库内的文件**——所有者在仓库里找不到、也无法自行复核其原文。因此本报告的处理原则是：凡能落到仓库内可复核的（代码行号、测试锚点、命令输出），尽量以〔实测〕重新锚定；不能落到仓库内的（如各模块自查的分工过程描述），保留标注供参考。所有者应把〔实测〕当作已验证，把〔验收〕/〔模块自查〕当作**待复核的声明**——优先复核清单见 §6.5。

### 0.3 术语表

| 术语 | 含义 |
|---|---|
| 五域 | 时间分配 / 睡眠 / 训练 / 饮食 / 预算五个数据域，各自独立记录 |
| 报告（模块） | 第六个模块：只读聚合五域数据，产出「日简报」（一天的五域合一卡片）与「阶段综合报告」（day/week/month/自定义区间） |
| lifttime | 参考项目：一个生活量化 PWA（Web 应用），是本项目的功能蓝图与**测试基线**来源——它的测试断言（如「这个场景睡眠分应为 93」）被逐条移植为 Swift 测试，用来保证数值口径一致 |
| Ely | 设计语言来源项目（Rust 桌面应用），提供色彩/字体/组件规范 |
| 净化管线 | 备份**导入**时的数据清洗：把外部 JSON 逐条容错解码——坏条目剔除、坏字段归空、好数据全部保留，防止一条坏数据让整个导入失败（对比：Swift 默认解码遇一条坏数据会整组抛错） |
| customFoods | 用户自学习的自定义食物库条目。lifttime 的净化管线会把它们丢掉（其缺陷），本版修正为保留（〔验收〕：ModelSanitizeTests.swift:169-232 有正向断言） |
| B1 口径 | 终审轮「口径纠错」清单第 B1 项：预算建议里的蛋白达标率 proteinHitRate 应为「**有饮食记录的天数中、蛋白达标的天数占比**」（动态计算），纠正了此前误读 lifttime 源码行号得出的固定值 0.4。本报告 §3.5 涉及处已〔实测〕抽验（AppModel+Budget.swift:160-168） |
| e1RM / Epley | 估算「单次能举起的最大重量」；公式 `重量 × (1 + min(次数, 15)/30)`，次数按 15 封顶（SessionAnalysis.swift:19-22，lifttime analysis.js:6-9 同口径） |
| DOMS | Delayed Onset Muscle Soreness，训练后延迟性肌肉酸痛；本版在训练结束时按加权分**预测**次日酸痛档位（见 §1.3） |
| 睡眠债 | 每晚「max(0, 目标时长 − 实际时长)」的区间累加；**没记录的夜晚不计债也不进均值**（避免漏记被当成没睡） |
| CLT | Apple Command Line Tools，本机仅有的编译环境（无完整 Xcode） |

---

## 一、做了什么

### 1.1 对照用户需求

用户需求：一款 **iOS 生活数据记录应用**，**参考 lifttime 的功能范围**，**采用 Ely 设计语言**，**不照搬**。交付结果：

| 需求 | 落地情况 |
|---|---|
| iOS 应用 | 原生 SwiftUI 应用，模块化 Swift Package（`Package.swift:14-52`：`SelfRecordCore` + `SelfRecordUI` 双 library，iOS 17+ / macOS 14+），App 入口 `app/SelfRecordApp.swift`（@main + 五 Tab，共 121 行）经 XcodeGen 工程组装（`app/project.yml`）。**注意：iOS 侧本机零编译零运行，见 §5.2/§5.4。** |
| 参考 lifttime 功能范围 | 五域 + 报告的记录与分析逻辑全量移植，数值口径以 lifttime 测试基线锚定（锚点数字的场景含义见附录 B）；「范围」的边界（AI / HealthKit / 自定义周期预算等五类后置）见开篇与 §3。 |
| Ely 设计语言 | 36 个色彩令牌逐值落地为代码色板（`Sources/SelfRecordUI/DesignSystem/SRTokens.swift`），字阶/度量/动效按 design.md §7 映射，DesignSystem 组件库收口。详见 §4。 |
| 不照搬 | 三类明确决策（design.md §9 全文本次已读核实）：① **平台形态**：舍弃 PWA / Service Worker / 检查更新（原生 App 由 App Store 管更新）、舍弃 localStorage 单键全量存储（换分域 JSON 文件）、舍弃 Ely 桌面侧栏 / hover 悬停 / Avatar / 表格组件（换 iOS 底部 Tab 与触控习惯）；② **有意收紧**：时间分类色板限 8 个彩色档 + 1 个兜底专属灰（防用户自建分类与兜底分类撞色——lifttime 无此约束）；③ **修正参考实现的已知缺陷**：净化管线改三步元素级容错（lifttime 一条坏数据整组丢）并修掉净化丢 customFoods 的缺陷（design.md §9 保留项 8）。 |

### 1.2 交付物构成

〔实测〕项目文件清单（`find` 全量，排除 .build/.git）：

- **Core 逻辑层** `Sources/SelfRecordCore/`（仅依赖 Foundation，Package.swift:26-29）：基础层（`Model/` 9 个模型文件、`Storage/` 存储与备份净化、`TimeKit/` 4 个时间工具）+ 六个功能模块（`TimeTracking/`、`Sleep/`、`Workout/` 三文件、`Diet/` 两文件、`Budget/` 两文件、`Report/` 四文件）。
- **UI 层** `Sources/SelfRecordUI/`：`DesignSystem/` 16 个令牌与组件文件 + `AppModel.swift` 与五组 extension 分文件 + Today / records / Workout / Budget / Settings 五界面分组 + `iOS/iOSAdapters.swift`（iOS-only 代码集中地，目前是仅注释的空文件——〔实测〕读取确认）。
- **App 组装** `app/SelfRecordApp.swift`（121 行）+ `app/project.yml`（不在 Package target 内，不参与 swift build——README.md:42-44）。
- **测试** `Tests/SelfRecordCoreTests/` 8 个文件，构成见 §5.1 的表。
- **文档与脚本**：`docs/design.md`（989 行设计基线）、`docs/reference-lifttime.md`、`docs/reference-ely.md`、`README.md`、`scripts/test.sh`。

### 1.3 各模块完成情况

六个功能模块 + 六个界面分组在交付材料中全部标记已完成（材料同时声明设计终审通过、构建与测试全部通过——构建与测试总数本次已〔实测〕复核，见 §5.1）。各域核心交付与行话展开（技术细节的出处标注为〔模块自查〕者未经本次复核）：

- **时间分配**：三个聚合查询（当日摘要 / 区间逐日 × 分类 / 当日健身类合计）；单槽计时器（同一时刻只允许一个计时中的事项，双向拒绝、崩溃后凭开始时刻恢复）；补记/编辑共用一套校验；分类增删改（删分类时历史记录自动迁移到兜底分类）。
- **睡眠**：两击记录（睡前一点、醒后一点）+ 可跳过问卷（不填不扣分，给中性分）；凌晨归属规则——醒来的时刻往前推 4 小时落在哪天，就算「那天的昨晚」，另有手动改归属；午睡识别（09:00–18:00 开始且短于 3 小时）；睡眠分 0–100 = **时长 40 + 就寝规律 30 + 感受 20 + 连续 10** 四部分加权（SleepEngine.swift:113，未填项给中性分）——不是「六维」，六个数字 93/100/73/63/85/86 是 lifttime 六个测试场景的期望分数（每个场景见附录 B）。
- **训练**：112 项内置动作（〔模块自查〕= lifttime 107 项全量 + 5 项补足）；逐组录入 / 复制上一组；e1RM 估算（Epley 公式、次数 15 封顶）；**容量分摊**——一个动作标记多个部位时，容量按部位数均摊（每个主部位得 1/n，次部位各得 0.5/n；自重动作容量按 0 计但组数照算，SessionAnalysis.swift:28-29）；PR 刷新与首次达成区分；**DOMS 预测**——从 1 分起按强度环比、组数、新动作占比、离心组、练腿、近期空窗逐项加分，映射到轻/中/明显/强四档次日酸痛预期（SessionAnalysis.swift:254-268）；**恢复建议三分支**——蛋白质建议按「① 当天有饮食记录 → 按实际摄入算缺口；② 无记录但填了体重 → 按每公斤 1.6–2.2g 给目标；③ 连体重都没填 → 给通用建议」三档出文案（SessionAnalysis.swift:297-306，〔实测〕读取确认）；分析快照落盘（历史详情不随口径变化漂移）；7/30/90 天阶段分析。
- **饮食**：中文自然语言记餐（「两碗米饭」→ 400g 这类解析：约 35 种量词、市制「两」=50g、长名优先匹配，〔模块自查〕等价移植 lifttime nutrition.js:24-89）；326 项内置食物库（〔模块自查〕脚本从 lifttime foods.js 逐字段无损转译，非手抄）；三层兜底——① 库匹配 → ② 匹配不上时按 8 大类猜测并预填可改可弃 → ③ AI 估算（v1.x 后置）；用户可教 App 记住新食物（自学习库）；练后 2.5 小时窗口判定；双达标率口径并存（训练日口径给报告用、全记录日口径给预算建议用，后者即术语表的 B1 口径）。
- **预算**：手动记账（七档健身向分类）+ 记餐花费自动入账（饮食页记了花费的餐，预算页自动出现一条带 auto 标记的餐饮支出）；周/月预算与节奏预测（按已过时间折算「照这个速度期末会花多少」并给拉回指引）；计划外开销双口径——**额度进度只算计划内支出，总账包含计划外**；蛋白性价比（每补 10g 蛋白花多少钱，含参考成本表）。
- **报告**：日简报（时间 + 昨晚睡眠 + 训练摘要 + 饮食汇总 + 开销进度五卡合一，按日翻页）；阶段综合报告（day/week/month/自定义 ≤366 天区间，规则版文案立即出）；报告的数据结构同时是未来 AI 版输出的契约（AI 后置，接口形状已留）。

### 1.4 验收缺口闭环情况

〔验收〕验收结论为「整体可交付度高」，列出 1 项 medium + 3 项 low。本次撰写时逐项核对现状：

| 验收发现 | 本次核实结果 |
|---|---|
| **〔medium〕五域阶段报告有引擎无 UI 入口**（验收时 grep 全 UI 目录只命中日简报，功能用户不可达） | **验收后已补上入口接线（代码层，未经运行验证）**。〔实测〕`Sources/SelfRecordUI/Today/PeriodReportSheet.swift` 已存在；`TodayView.swift:74` 的「阶段报告」卡片点击置位，`TodayView.swift:80-82` 经 `.sheet` 挂载该页；`AppModel+Today.swift:60-61` 调用 `ReportEngine.renderRuleReport(ReportEngine.periodReport(…))`。**判定依据仅是源码存在调用链**——App 本机零运行、UI 零测试（§5.2），sheet 能否正常打开、数据是否正确渲染，属首轮真机回归清单验证项（§6.1 第 2 条已显式列入）。Core 侧聚合与渲染逻辑有 31 项测试锁定（§5.1）。 |
| 〔low〕design.md §7.1 表 paper/ink 暗色列与代码不一致 | **未修**（文档级）。〔实测〕`design.md:703` 暗色列仍写「同左」（#FFFFFF/#181613），而 `SRTokens.swift:141-142` 暗色取 0xF3F1F0/0x181613（与 Ely 源码一致——代码正确、文档错）。建议回改文档，见 §6.2。 |
| 〔low〕Package.swift unsafeFlags 写死 CLT 绝对插件路径 | **在案未变**（环境适配项）。〔实测〕`Package.swift:43-48` 确认；后果是本 package 无法被其他 SwiftPM 包声明为依赖。装 Xcode 后应移除，见 §6.2。 |
| 〔low〕iOS 侧零验证 / xcodegen 未安装 | **在案**（环境硬约束）。〔实测〕`which xcodegen` 返回 not found；iOS 分支从未编译。见 §5.2/§5.4。 |

另发现两处材料未列的文档级不一致：①〔实测〕`scripts/test.sh:14` 头注释仍写「30 tests」（实际 198，注释过期，不影响行为）；②〔实测〕`ReportEngine.swift:75` 的 periodReport 文档注释写「预算：BudgetEngine.status」，而预算板块实现实际走底层只读原语（ReportEngine.swift:182-187 的函数注释解释了原因与收敛条件，详见 §5.3 第 1 条）。

---

## 二、怎么运行

### 2.1 无 Xcode（本机现状）：验证构建与测试

本机仅有 Apple Command Line Tools（Swift 6.4 / swift-driver 1.168.6，`swift --version` 〔实测〕）。可做的验证：

```bash
cd /Users/nanami/Desktop/Zcode/iOS-app/self-record
swift build          # 编译 SelfRecordCore + SelfRecordUI（host macOS 构建）
./scripts/test.sh    # 跑全部 198 项测试
```

- `swift build`：〔实测〕**干净全量构建通过**（`rm -rf .build` 后重跑，178 个构建步骤，`Build complete! (26.36秒)`）。构建时会输出一条链接警告：`ld: warning: search path '/Library/Developer/CommandLineTools/Developer/Library/Frameworks' not found`——这条警告源于本机 CLT 环境下 Package.swift 的固有行为，与本包代码无关（TimeTracking 模块工程师在自查中声明过；本次 clean 构建中实际观察到它出现在 SelfRecordUI 链接阶段）。
- `./scripts/test.sh`：〔实测〕通过，末行输出 `Test run with 198 tests in 38 suites passed`。脚本内容为 `swift test` 附加 `-Xswiftc -plugin-path` 指向 CLT 的 Swift Testing 宏插件目录（`scripts/test.sh:19-24`），并带「失败重试→清 .build 重跑」兜底（`scripts/test.sh:27-40`）。
- 裸 `swift test`：〔实测〕亦通过（198/38，末行同上）——`Package.swift:43-48` 的 unsafeFlags 声明使裸命令也能找到宏插件。README.md:16 建议优先用 `scripts/test.sh`。
- **此路径只能验证逻辑与 macOS 可编译性，无法运行 App**：iOS SDK 在本机不存在（design.md §0-1 环境事实）。

### 2.2 有 Xcode：生成工程并运行 App（本机未验证的路径）

以下步骤摘自 README.md:18-29 与 `app/project.yml` 头注释，**本机一次都没跑过**（〔实测〕xcodegen not found；〔验收〕project.yml 仅做到 YAML 解析通过）：

```bash
brew install xcodegen
cd app
xcodegen generate        # 按 app/project.yml 生成 app/SelfRecord.xcodeproj（产出不入库）
open SelfRecord.xcodeproj
```

Xcode 中选 iOS 17+ 模拟器，Cmd+R 运行。工程规格：App target 引用 `app/SelfRecordApp.swift` 与本地 package 双 library（SelfRecordCore / SelfRecordUI），部署目标 iOS 17+，明暗主题跟随系统（应用内可经设置页手动覆盖）。

---

## 三、功能覆盖对照表

lifttime 能力 → 本版状态。状态分三档：**已实现**（Core 逻辑含测试锁定；UI 部分仅有编译门控，见 §5.2 第 4 条）、**简化/改造**（有意为之，注明差异）、**后续**（v1.x，接缝已留）、**舍弃**（明确不要）。口径来源：design.md §3/§9（本次已读核实）+ 各模块自查摘要（未经本次复核的部分均已标注）。

### 3.1 时间分配

| lifttime 能力 | 本版状态 | 说明 |
|---|---|---|
| 时间块记录（计时 + 补记 + 编辑 + 删除） | 已实现 | 单槽计时器互斥、崩溃恢复只依赖开始时刻、结束早于开始拒绝；归属口径统一为开始时刻所在日（跨午夜不拆分） |
| 24h 时间轴可视化 | 已实现 | 全项目唯一自绘 Canvas（design.md §9：其余图表走 Swift Charts） |
| 今日/近 7/近 30 区间视图 | 已实现 | 今日环形图 + 块列表；近 7/30 逐日堆叠柱，无记录的日期补零 |
| 自定义分类 | 简化/改造 | 限 8 个彩色档 + 兜底专属灰不可选（防撞色——lifttime 无此约束，「不照搬」项） |
| 旧数据兼容（无类型标记的旧时间块归「一般」） | 已实现 | lifttime store 测试断言语义移植 |

### 3.2 睡眠

| lifttime 能力 | 本版状态 | 说明 |
|---|---|---|
| 两击记录 + 可跳过问卷 | 已实现 | 不填不惩罚：未填项给中性分 |
| 凌晨归属（-4h 规则）+ 手动改归属 | 已实现 | 8 个边界用例锁语义（03:59 归前夜 / 04:00 归当天等） |
| 午睡识别 | 已实现 | 09:00–18:00 开始且 <3h（09:00 整算、18:00 整不算、恰 3h 不算） |
| 睡眠分 + 规律性 MAD + 睡眠债 | 已实现 | 分数 = 时长 40 + 规律 30 + 感受 20 + 连续 10；同一夜的分数在任何页面一致（一律经区间中位锚计算，无记录时锚默认 330——即假定参照就寝 23:30，见附录 B）；缺记夜不进均值不记债 |
| 就寝规律分的「线性差」缺陷 | 后续（显式照抄） | 见下方框注 |
| HealthKit 自动读睡眠 | 后续（iOS 增强） | lifttime 无此能力；接缝已留（睡眠段可由外部喂入引擎），本机无法命令行验证故后置 |

> **框注：什么是「线性差缺陷」以及为什么「照抄」。** 就寝规律分衡量「今晚几点睡 vs 近期通常几点睡」的偏离。本版与 lifttime 都把就寝时刻换算成「自 18:00 起经过的分钟数」（如 23:30 → 330），再与近期中位锚做差。问题在于这个差是**直线相减**而不是**按 24 小时圆环**算：一个 17:50 就寝的人换算后是 1430 分钟，与锚 330 线性差高达 1100 分钟，但按圆环实际只偏离 10 分钟——这类人就寝规律分会被误判归零。这是 lifttime 的已知缺陷；如果修正算法，六个测试锚点的期望值就会变，等于口径漂移。决策（design.md §3.2 + SleepEngine.swift:16-17 源码注释双重记录）：**保持算法照抄以锁住锚点，源码注释标明缺陷与修正方向，圆刻度修正列为 v1.x 显式决策项**。

### 3.3 训练记录与分析

| lifttime 能力 | 本版状态 | 说明 |
|---|---|---|
| 动作库 + 搜索 + 自定义动作 | 已实现 | 112 项（〔模块自查〕lifttime 107 全量 + 5 补足）；精确/前缀/包含打分搜索 |
| 逐组录入 / 复制上一组 | 已实现 | 表单焦点用 @FocusState（宏禁令的文档化例外，判据见 §4） |
| e1RM / 容量分摊 | 已实现 | Epley 公式次数 15 封顶；多部位动作容量主部位各 1/n、次部位各 0.5/n；自重动作容量 0 但组数计入 |
| PR 刷新 vs 首次 / 滚动 PR / 连续训练节奏 | 已实现 | 含「连练 ≥5 天提醒休息」、推拉腿平衡 |
| DOMS 预测 / 恢复建议 | 已实现 | 加权计分四档酸痛预期（§1.3）；恢复建议三分支完整消费跨域数据（实际蛋白摄入 / 体重 / 通用） |
| 分析快照落盘 | 已实现 | 训练结束即存分析快照，历史详情不漂移；详情页可按当前口径再生成 |
| 7/30/90 天阶段分析 | 已实现 | 频率/容量环比/部位分布/PR/平衡 |

### 3.4 饮食记录与解析

| lifttime 能力 | 本版状态 | 说明 |
|---|---|---|
| 中文自然语言记餐 | 已实现 | 「二两白酒=100g、两碗米饭=400g、半块巧克力=10g」等解析语义由移植测试锁定（〔模块自查〕等价移植 nutrition.js:24-89） |
| 食物库 | 已实现 | 326 项（〔模块自查〕脚本无损转译）；自学习库拒零值 |
| 三层兜底 | 已实现 | ①内置+自学习库 → ②8 大类猜测预填（可改可排除）→ ③AI（后续） |
| 解析确认卡三层标记 | 已实现 | 命中（带食物标签）/ 手动估算 / 未识别 三种标记 |
| 宏量总结 / 训练日达标率 / 日建议 | 已实现 | 建议 ≤4 条含练后 2.5h 窗口；双达标率口径并存（§1.3） |
| AI 估算 | 后续 | v1.x 网络层整体后置，数据契约已留 |
| 餐次六档 / 食物标签十档 / 开销七档 | 已实现 | 三处口径经源码逐行核对回归 lifttime 原样（〔模块自查〕评审轮修正记录） |

### 3.5 预算

| lifttime 能力 | 本版状态 | 说明 |
|---|---|---|
| 手动记账 + 分类 | 已实现 | 七档健身饮食向（「餐饮」档为自动派生专用，手记不提供） |
| 记餐花费自动入账 | 已实现 | 饮食页记了花费的餐自动生成带 auto 标记的支出 |
| 周/月预算 + 节奏预测 | 已实现 | 按已过时间折算期末预测 + 拉回指引 |
| 计划外双口径 | 已实现 | 额度只算计划内、总账含计外 |
| 蛋白性价比 | 已实现 | ¥/10g + 参考成本表；达标率注入为 B1 口径（〔实测〕`AppModel+Budget.swift:160-168` 抽验：`Double(diet.proteinHitDays) / Double(diet.daysTracked)`，注释标明 B1） |
| 外卖聚餐/补剂占比诊断 | 已实现 | 分母分子口径同 lifttime finance.js |
| 自定义周期预算计划 | 后续 | lifttime 对应测试锚点（自定义周期计划进度 6% 等断言）随功能一起移植 |

### 3.6 报告

| lifttime 能力 | 本版状态 | 说明 |
|---|---|---|
| 五域日简报 | 已实现 | Core 含测试锁定（日简报自建用例）；UI 今日页渲染 |
| 阶段综合报告（规则版） | **已实现（分两层）** | **Core 聚合与渲染：31 项测试锁定**；**UI 入口：验收后已接线但未经运行验证**（判定依据与限制见 §1.4） |
| AI 版报告 | 后续 | 规则版数据结构 = 未来 AI 输出契约 = 渲染契约，一份渲染两用 |

### 3.7 平台与基础设施（lifttime 作为 PWA 的能力）

| lifttime 能力 | 本版状态 | 说明 |
|---|---|---|
| Service Worker / PWA 安装 / 检查更新 | 舍弃 | 原生 App 由 App Store 管更新（design.md §9 舍弃项 1） |
| localStorage 单键全量 JSON | 舍弃 | 换分域 JSON 文件存储（design.md §9 舍弃项 3） |
| 备份导出/导入 + 净化 | 已实现（并修正缺陷） | 三步元素级容错管线；修掉 lifttime 净化丢 customFoods 的缺陷 |
| Inter/JetBrains Mono 字体、全局字阶缩放、色盲八色 | 后续 | 系统字体 + Dynamic Type 先行；令牌留位（〔实测〕SRTokens.swift 高对比度与色盲安全注释段可见） |
| 多语言/单位 | 简化 | 第一版简体中文 UI + kg/lb 双单位显示换算（内部恒 kg） |

---

## 四、设计语言落地说明

Ely 是桌面向设计语言，落到 iOS 需要系统性映射而非照搬（依据 design.md §7 + 〔验收〕核查结论；色板/字阶/宏禁令三项验收轮已核对，本次抽验了色板一处）：

1. **色彩：36 个令牌全量自研色板**。不用 Asset Catalog，`Color(light:dark:)` 代码直定义（`SRTokens.swift`）。〔验收〕36 值与 reference-ely.md 逐值一致（本次仅抽验 paper/ink 两值，吻合）；DesignSystem 外零字面色值（验收轮 grep 验证）。〔实测〕抽验处：`SRTokens.swift:141-142` 暗色 0xF3F1F0/0x181613 与 Ely 源码一致——**design.md §7.1 表此处写错（design.md:703 标「同左」），代码正确**，待回改文档。
2. **字阶：映射到系统 TextStyle**。Ely 桌面密度直接搬 iOS 会偏小（〔验收〕映射与 design.md §7.2 一致）。真机校准列为回归清单第一项（design.md §11 风险 4）。
3. **度量与动效令牌化**：间距/圆角/阴影/动效统一常量，组件统一收口。
4. **组件库收口**：各界面只许用 DesignSystem 组件（design.md §7.4）——按钮 8 变体、卡片、分段选择、图表容器、24h 时间轴等 16 个文件〔实测〕在库。
5. **不照搬的桌面语义**：侧栏导航 → iOS 底部五 Tab；hover 悬停语义舍弃（触摸无意义）；Avatar/表格等桌面组件舍弃。
6. **技术红线与例外的判据（为什么禁 @State 却允许 @FocusState）**：本机 CLT 的宏插件目录里没有 SwiftUIMacros（design.md §0-2 实测：含 `@State` 的代码 swift build 直接失败），所以全 UI 包禁用 **宏**——`@State` / `@Observable` / `@ScaledMetric` 等；而 `ObservableObject` / `@Published` / `@FocusState` / `@Namespace` 是 **propertyWrapper（属性包装器），不是宏**，不依赖缺失的宏插件，实测可编译（design.md:831 约定 5 原文 + §13 探针记录：@FocusState 在 View 中编译通过，但挪进 ObservableObject 会因 Binding 类型不匹配编译失败——所以焦点态必须留在 View 内）。〔实测〕本次 grep 复核：SelfRecordUI 全目录 `@State / @Observable / @ScaledMetric / @Bindable` 命中 7 处，全部是提及禁令的注释文字，代码零违例（附录 A #12）。

---

## 五、验证情况

### 5.1 已验证（绿色面）

**本报告撰写会话实测（附录 A 有完整命令与输出）：**

| 检查 | 命令 | 结果 |
|---|---|---|
| 干净全量构建 | `rm -rf .build && swift build` | 178 步，`Build complete! (26.36秒)` |
| 全量测试（统一入口） | `./scripts/test.sh` | `Test run with 198 tests in 38 suites passed` |
| 全量测试（裸命令） | `swift test` | `Test run with 198 tests in 38 suites passed` |
| 阶段报告 UI 入口接线 | `grep -rn "PeriodReportSheet\|periodReport\|renderRuleReport" Sources/SelfRecordUI/` | 命中 TodayView.swift:81 挂载、AppModel+Today.swift:60-61 调用链 |
| iOS-only 条件编译面 | `grep -rn 'canImport(UIKit)\|os(iOS)' Sources/ app/` | 全库 5 处：SRField.swift 1、SRTokens.swift 3、iOSAdapters.swift 1（注释内） |
| xcodegen 可用性 | `which xcodegen` | not found |

**测试构成的核算（198/38 如何凑出来，〔实测〕可复核）：**

| 测试文件 | @Test 数 | @Suite 数 |
|---|---|---|
| TimeTrackingTests.swift | 32 | 9 |
| SleepTests.swift | 9 | 1 |
| WorkoutAnalysisTests.swift | 33 | 11 |
| DietNutritionTests.swift | 56 | 12 |
| BudgetFinanceTests.swift | 13 | 1 |
| ReportBuilderTests.swift | 31 | 4 |
| ModelSanitizeTests.swift | 15 | 0（文件级顶层测试） |
| TimeKitTests.swift | 9 | 0（文件级顶层测试） |
| **合计** | **198** | **38** |

`grep -o '@Test'` 逐文件计数合计 198，`@Suite` 合计 38，与 `swift test` 末行报告的 `198 tests in 38 suites` 完全一致（统计命令见附录 A #7）。**注意**：交付材料中各模块自查的数字（如「睡眠 49 断言」「时间 32 用例」）单位不统一（断言/用例/tests 混用，一个 @Test 函数内可含多条断言），**不可加总核算**，仅作参考；以本表实测口径为准。

**〔验收〕声明的抽验情况**：验收轮逐项核对过口径锚点（睡眠锚点、解析语义、预算 3.65、Epley 封顶、报告锚点、净化 customFoods、36 token 逐值、宏禁令 grep、页面地图逐项），以源码/测试行号引用记录。本次从中抽验 4 处，全部吻合：① PeriodReportSheet 调用链；② AppModel+Budget.swift:160-168 的 B1 口径；③ BudgetEngine.swift:189-191 的 status 前置；④ SRTokens.swift:141-142 暗色值。**未抽验的部分（112 动作、326 食物、35 量词、36 token 中的其余 34 值等）仍是待复核声明**，列入 §6.5 复核清单。

### 5.2 没法验证（环境硬约束，如实声明）

1. **iOS 分支零编译**：本机无 iOS SDK（design.md §0-1 实测：`xcrun --sdk iphoneos --show-sdk-path` 报错），所有 `#if os(iOS)` / `canImport(UIKit)` 包裹的代码从未编译过。涉及面见 §5.4。
2. **App 从未运行**：无 Xcode → 无模拟器 → `app/SelfRecordApp.swift` 入口、五 Tab 接线、全部交互（计时、翻页、sheet、图表触控）零运行验证。**这包括 §1.4 的阶段报告入口**——代码接线已核实，运行效果未验证。
3. **xcodegen 路径零验证**：〔实测〕xcodegen not found；〔验收〕project.yml 仅 YAML 解析通过（ruby），`xcodegen generate` 及产物工程从未生成/打开。
4. **UI 无自动化测试**：design.md §10 明确「UI 不写单元测试（无 Xcode 无法 UI 测试），靠 swift build 编译门控 + Core 全覆盖保证正确性」——即 §3 表中所有「已实现」的 UI 部分，正确性保证只有「macOS 下可编译」这一层。
5. **真机观感未校准**：字阶映射、明暗主题实机效果、图表触控交互均未见过真机。

### 5.3 已知偏差与残留问题（材料显式记录 + 本次核实）

1. **报告的预算板块绕开了 BudgetEngine.status——内部结构差异，不是用户可见的数据错误。** 背景：`status` 函数设计为「用户没设预算（或金额 ≤0）时返回空」（BudgetEngine.swift:189-191 的 guard，与 lifttime finance.js:149 同口径）；但阶段报告希望**没设预算也能显示「这段时间总共花了多少」**（lifttime 的报告测试就是无预算场景下要求总账 310、其中计划外 250）。因此报告的预算板块没有调用 status，而是直接调用同一引擎的四个公开只读函数：合并开销流 → 区间过滤 → 汇总 → 计划外提取（ReportEngine.swift:190-193，〔实测〕读取）。报告显示的数字经测试锚定正确（附录 B）。函数注释（ReportEngine.swift:182-187）写明了收敛条件：「若后续 status 改为无预算也返回汇总口径，此处应收敛回 status 单通道」。**遗留的小问题**：periodReport 的文档注释（ReportEngine.swift:75）仍写「预算：BudgetEngine.status」，与实现不一致（文档级，同 §1.4 第 ② 条）。
2. **CLT 下 Swift Testing 的一个比较怪癖（材料声明，本次未复现）**：模块工程师报告，本机 CLT 环境下用 `#expect` 比较「Optional 包装的 Double」与「整数算式的结果」时会错误地判为不相等（实测复现过）；测试代码已改为两边都用显式 Double 字面量规避。换完整 Xcode 环境后值得复查一次。
3. **Package.swift unsafeFlags**（见 §1.4）：本 package 无法被外部 SwiftPM 包声明为依赖。
4. **文档级不一致三处**：design.md:703（§7.1 表 paper/ink 暗列）、scripts/test.sh:14（头注释「30 tests」过期）、ReportEngine.swift:75（注释与实现不符）。

### 5.4 装好 Xcode 后，离「真机跑起来」还有多远（量级判断）

**实测基础**（grep 全库统计，附录 A #5）：iOS-only 条件编译点全库仅 **5 处**——SRField.swift 1 处、SRTokens.swift 3 处（UIColor 动态色构造等，〔实测〕读过 SRTokens.swift:51-63，API 用法为标准形态且构造器在 macOS 下 typecheck 过）、iOSAdapters.swift 1 处（在注释文字里）；另有 1 个从未编译的入口文件 `app/SelfRecordApp.swift`（121 行）。

**判断**（基于上述数字 + design.md §0-1 的既定对策「iOS-only 代码薄化收敛到少数文件」，非运行验证的结论）：
- **确定的工作量很小**：首轮编译需要处理的 iOS 专属代码就上述几处 + 121 行入口文件，预期是零星编译错误（API 细节级），不是大面积返工；
- **不确定的面**：SelfRecordUI 其余全部共享代码（9,217 行，〔实测〕wc 统计）在 macOS SDK 下编译通过，但**从未在 iOS SDK 下编译过**——SwiftUI/Charts 跨平台子集理论上应当一致，实际不能排除非零量的适配；
- **诚实的下限**：本 App 从未运行过，即使编译通过，首轮运行的交互问题（导航接线、sheet 行为、图表触控）数量无法预估。design.md §11 风险 1 的既定预期就是「爆雷点集中在 iOS/ 与 canImport(UIKit)」，与本统计一致。

---

## 六、后续建议

按优先级排序：

### 6.1 首轮真机回归（装好 Xcode 后第一件事，design.md §11 既定清单）

1. `brew install xcodegen && cd app && xcodegen generate`，首开工程处理编译错误——按 §5.4 的量级统计，先盯 `app/SelfRecordApp.swift`、SRTokens.swift:51-63、SRField.swift 三处；
2. 模拟器 Cmd+R 跑通五 Tab 主流程：计时器常驻条、睡眠两击+问卷、记餐解析确认、逐组训练录入、预算周月切换、日简报翻页；**并单独验证阶段报告 sheet 能打开、五个板块有数据**（§1.4 的修复只到代码接线，此处是它的运行验证）；
3. **字阶真机校准**（回归清单第一项，design.md §11 风险 4）。

### 6.2 环境适配与文档清理（装好 Xcode 后）

1. 移除 `Package.swift:43-48` 的 unsafeFlags 整段，回归 `./scripts/test.sh`（〔验收〕建议：装 Xcode 后该目录不存在、搜索路径按语义忽略，移除后需回归确认）；
2. 回改 `docs/design.md` §7.1 表 paper/ink 暗色列为 #F3F1F0/#181613（代码不动）；
3. 更新 `scripts/test.sh:14` 过期头注释（「30 tests」→ 当前 198）；
4. 修正 `ReportEngine.swift:75` 文档注释（预算域实际走底层只读原语），或按 §5.3 第 1 条的收敛条件统一回 status 单通道。

### 6.3 v1.x 功能后置清单（接缝均已留，design.md §9）

1. AI 网络层（食物估算第三层、AI 报告；lifttime ai 测试 39 项断言随后移植）；
2. HealthKit 睡眠自动读取（iOS-only 增强）；
3. 自定义周期预算计划（对应测试锚点随后）；
4. Inter 字体、全局字阶缩放、色盲八色开关（令牌留位已就位）；
5. 睡眠就寝规律分圆刻度修正（修正即改测试锚点，须显式决策，见 §3.2 框注）。

### 6.4 工程健康

1. 裁决 BudgetEngine.status 与阶段报告的收敛方向（§5.3 第 1 条，收敛条件已在代码注释中）；
2. UI 自动化测试缺口：有 Xcode 后可考虑为首屏关键路径补 UI 测试（当前为零，§5.2-4）；
3. 仓库尚无 git 版本管理（环境信息：非 git 仓库）——建议初始化入库（reference/ 忽略规则 README.md:52 已有约定）。

### 6.5 建议所有者优先复核的声明清单（〔模块自查〕/〔验收〕层，本报告未验证）

按「数字大、影响面大、复核成本低」排序：

1. **36 token 逐值一致**（〔验收〕声明全对，本次仅抽验 2 值）——对照 `docs/reference-ely.md` 与 SRTokens.swift 全量 grep，半小时内可完成；
2. **326 项食物库无损转译**——对 `FoodLibrary.swift` 抽样若干条与 lifttime foods.js 比对（需取得 lifttime 参考，见下条）；
3. **lifttime 参考的可得性**：`reference/` 目录被 .gitignore 忽略且不入库（README.md:52），当前机器上有、换机器没有——上述与 lifttime 源码的比对只能在本机做，宜尽早；
4. **112 项动作库、约 35 种量词、nutrition.js:24-89 等价移植**等数字型声明（复核方式：grep ExerciseLibrary.swift 的条目计数、读 DietEngine.swift tokenizer 段）；
5. 各模块自查声明的「swift build 通过 / 模块测试绿」已被本报告的 198/38 全量实测覆盖，无需单独复核。

---

## 附录 A：本报告撰写会话的实测记录（2026-10-06，Swift 6.4 CLT / macOS arm64）

| # | 命令 | 关键输出 |
|---|---|---|
| 1 | `rm -rf .build && swift build`（干净全量） | 178 步，`Build complete! (26.36秒)`；含一条 CLT search path 链接警告（§2.1） |
| 2 | `swift build`（增量，首轮） | `Build complete! (0.21秒)` |
| 3 | `./scripts/test.sh` | 末行 `Test run with 198 tests in 38 suites passed after 0.021 seconds.` |
| 4 | `swift test` | 末行 `Test run with 198 tests in 38 suites passed after 0.018 seconds.` |
| 5 | `grep -rn 'canImport(UIKit)\|os(iOS)' Sources/ app/` | 5 处：SRField.swift×1、SRTokens.swift×3、iOSAdapters.swift×1（注释） |
| 6 | `grep -rn "PeriodReportSheet\|periodReport\|renderRuleReport" Sources/SelfRecordUI/` | TodayView.swift:81、AppModel+Today.swift:60-61、PeriodReportSheet.swift:61 |
| 7 | 逐文件 `grep -o '@Test' / '@Suite'` 计数 | 合计 198 tests / 38 suites，与 #3/#4 一致（§5.1 表） |
| 8 | `which xcodegen` | `xcodegen not found` |
| 9 | `swift --version` | `Apple Swift version 6.4 (swiftlang-6.4.0.34.1)` |
| 10 | `find … -type f`（排除 .build/.git） | 完整文件清单（§1.2 摘要）；`wc -l` 合计 Sources 约 15,600 行；app/SelfRecordApp.swift 121 行 |
| 11 | 抽读源码 | TodayView.swift:74,80-82；AppModel+Today.swift:60-61；AppModel+Budget.swift:150-172；BudgetEngine.swift:180-200；ReportEngine.swift:70-78,182-204；SRTokens.swift:45-65,135-148；SleepEngine.swift:1-20,113-143；SessionAnalysis.swift:17-29,254-268,280-340；iOSAdapters.swift（全文）；Package.swift；scripts/test.sh；README.md；design.md §0/§3.2/§3.6/§7.1/§8/§9/§10/§11/§13；SleepTests.swift:140-168；ReportBuilderTests.swift:150-215 |
| 12 | `grep -rn '@State\b\|@Observable\|@ScaledMetric\|@Bindable' Sources/SelfRecordUI/` | 7 处命中全为注释文字，代码零违例（§4-6）；`wc -l` SelfRecordUI 合计 9,217 行 |

## 附录 B：数值锚点速查（正文黑箱数字的场景含义）

这些数字都是**移植自 lifttime 测试基线的断言期望值**，用来锁定「同样的输入必须算出同样的分数/金额」，防止移植时口径漂移。

**睡眠分（0–100 = 时长 40 + 就寝规律 30 + 感受 20 + 连续 10，SleepEngine.swift:113；锚点场景见 SleepTests.swift:145-166）：**

| 期望分 | 场景 |
|---|---|
| 93 | 睡满 8 小时、23:30 就寝（等于参照锚）、问卷全空 → 中性感受 13 + 连续 10 |
| 100 | 同上但问卷「感受」填了极好（5 分） |
| 73 | 只睡 4 小时（时长分打折） |
| 63 | 睡满 8 小时但凌晨 3 点才睡（就寝偏离参照 210 分钟，规律分归零） |
| 85 | 夜醒 2 次 + 入睡慢（连续分 10−5−3=2） |
| 86 | 夜醒 9 次（按封顶 3 档计，连续分 2.5）；亦有一次「感受差+夜醒 1 次」舍入到 86 的断言 |

**「330」是什么**：就寝规律参照锚的默认值——把就寝时刻换算成「自 18:00 起的分钟数」，330 分钟 = 23:30。区间内一条就寝记录都没有时，规律分以 23:30 为假定参照（SleepEngine.swift:114，lifttime sleepMath.js:98 同口径）。**单位是分钟，但衡量的是就寝时刻，不是睡眠时长**。

**其他锚点：**

| 锚点 | 场景含义 | 出处 |
|---|---|---|
| 时间 130 分 | 测试场景一周时间总分钟 = 90（力量训练）+ 40（其他分类） | ReportBuilderTests.swift:175-176 |
| 睡眠债 90 分 | (目标 480−实际 450) + (480−420)，两晚累计，单位分钟 | ReportBuilderTests.swift:184 |
| 训练容量 1956 kg | 60kg×16 次 + 62kg×8 次 + 100kg（自重按体重）×5 次 | ReportBuilderTests.swift:196-197 |
| 蛋白日均 70g | 测试场景一天两餐 (46+24)/1 | ReportBuilderTests.swift:202 |
| **总账 310 含计外 250** | 测试场景一周总开销 310 元 = 正常支出 60 + **计划外**体检 250；验证「总账口径包含计划外条目、计划外单独可见」 | ReportBuilderTests.swift:210-211 |
| 蛋白性价比 3.65 | 每补 10g 蛋白花费 3.65 元（测试场景的期望比值） | BudgetFinanceTests.swift（〔验收〕声明） |
| Epley 15 封顶 | e1RM = 重量×(1+min(次数,15)/30)，组次数超过 15 按 15 计 | SessionAnalysis.swift:19-22 |

---

## 验收补录（2026-10-06 · Xcode 27 安装后的 iOS 真实验收）

本机安装完整 Xcode 27.0（App Store）+ iOS 27.0 模拟器运行时后，按首轮回归清单完成验收。**结论：通过。**

### 验证矩阵

| 检查项 | 结果 |
| --- | --- |
| `xcodegen generate`（app/project.yml → .xcodeproj） | ✅ 一次通过 |
| `xcodebuild build`（iOS 模拟器目标，arm64+x86_64） | ✅（修复 2 处后） |
| `swift test`（宿主 macOS，Xcode 工具链，移除 unsafeFlags 后） | ✅ 198 测试 38 套件全绿 |
| `xcodebuild test`（iOS 27 模拟器 · iPhone 17） | ✅ 198 测试 38 套件全绿 |
| 模拟器安装 + 启动 + 进程存活（明暗切换不崩溃） | ✅ |
| 明暗双主题视觉检视（视觉模型 + 截图） | ✅ 暖白/暖黑与 Ely 色板一致（#FCFAF7/#131110 底、#1B1917 卡片） |

### 验收中发现并修复的问题（均为「从未在 iOS 编译/渲染」的欠账）

1. **SRTokens.swift 动态色构造器**（中）：`init(light: Color, dark: Color)` 的 UIKit 分支闭包返回 SwiftUI `Color` 而非 `UIColor`——iOS 无公开 Color→UIColor 转换，AppKit 分支纯属巧合可用。重构为 `init(light: UInt32, dark: UInt32)` 原始色值构造（36 处调用点同步替换），并新增 UIColor/NSColor `srHex` 便捷构造。
2. **SelfRecordApp.swift 启动 Task 捕获 mutating self**（中）：App init 里 `Task { await model.loadAll() }` 非法捕获；改为局部常量持有模型后进 Task。
3. **Tab 栏主色偏离 Ely 设计**（低）：iOS 26 Liquid Glass 底部 Tab 栏不响应 TabView `.tint()`（实测仍系统蓝），经 `UITabBar.appearance().tintColor` 注入墨色主色（亮 #181613 / 暗 #F3F1F0）后视觉复检确认生效。
4. **Package.swift 移除 `.unsafeFlags`**（低，遗留项核销）：移除后包恢复可被外部 SwiftPM 依赖；宿主与 iOS 双端测试回归全绿。
5. **design.md §7.1 表 paper/ink 暗色笔误**（低，遗留项核销）：改为 Ely 源码真实值（paper 暗 #F3F1F0），与代码三方对齐。

### 验收后仍未覆盖

- 真机（物理设备）运行与性能/能耗
- 各页面交互流程的人工逐页走查（本次为启动冒烟 + 视觉抽检，非全功能回归）
- 截图存于 `docs/screenshots/sim-light-today.png` / `sim-dark-today.png`

---

## 功能补齐记录（2026-10-06 · 用户验收反馈两项）

用户指出两处功能缺失，已实现并在 iOS 模拟器完成验证：

### 1. 睡眠手动补录
- **Core**：`SleepEngine` 新增 `makeSession`（带校验构造，end>start 且 1min–24h）/ `entryError` / `entryPreview`（归属实时预览）；补录会话与两击会话同形状，评分/聚合一视同仁。
- **UI**：睡眠区「＋ 补记睡眠」按钮 + 补录/编辑共用 sheet（默认昨晚 23:00→今早 07:00，可选问卷字段，编辑内含删除）；会话行左滑编辑。
- **测试**：新增 10 项（跨零点归属、午睡判定、边界校验、评分锚点、periodSummary 参与）。

### 2. 自定义周期预算计划
- **Core**：`CustomBudgetPlan`（多并存、含首尾起止）+ 计划引擎（`planDays/planRange/planStatus/planAdvice/renewedPlan`，语义锚定 lifttime finance.js:61-135：同天=1天、差13天=14天、计外不占额度、超节奏「每天控制在 ¥X 内」拉回、未开始不给建议）；持久化为独立 `plans.json` 域。
- **UI**：预算页「自定义周期计划」区块——计划卡（三态徽标、区间标签、**时间 vs 花销双进度条**、剩余额度、今天起日均、计外单列带徽标、拉回建议）、新建/编辑 sheet（实时「共 N 天」校验 1–365 天）、已结束「再来一期」。
- **测试**：移植 finance.test.mjs 当初跳过的自定义周期用例 + 自建共 13 项。

### 验证
- 宿主 `swift test`：**221 项 39 套件全绿**（+23）；iOS 模拟器 `xcodebuild build` + `xcodebuild test`：**221 项全绿**。
- 模拟器注入演示数据后截图核验（视觉模型复检）：预算页计划卡数值全部正确（花销 459.5/2000=23% vs 时间 42%、剩 ¥1,540.50、日均 ¥171.17、计外 ¥320 单列）；睡眠页补录按钮与昨晚会话（睡眠分 92）渲染正确。截图：`docs/screenshots/sim-budget-plans.png`、`sim-sleep-backfill.png`、`sim-today-seeded.png`。
- 附带：App 增加 `SR_TAB`/`SR_SEGMENT` 启动参数导航钩子（自动化冒烟用，正式启动不受影响）。

### 已知接缝（后续裁决）
- 计划未纳入 `BackupDocument` 备份导出/导入（备份契约为冻结物，扩展需显式决策）。
- Report 模块的 planOverlaps（报告页计划进度锚点）仍为后置。
- 演示数据仍在模拟器里，正式体验可在 设置 → 数据管理 清空。
