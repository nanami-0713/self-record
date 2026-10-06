# Ely GPUI 组件库 · 设计系统分析（供 iOS 版参考）

> 分析对象：`reference/ely/`（Ely-GPUI-Components）。所有色值、尺寸、时长均直接取自源码，标注 `path:line`。
> 本文档只做事实提炼与 SwiftUI 映射建议，不含任何运行验证；本文没有产出 Swift 代码，故 `swift build` / `swift test` 无从执行（未运行）。

## 0. 设计立场（README:4）

- "The palette is warm and quiet. **Color carries meaning, not decoration.**"（配色暖而安静，颜色承载含义而非装饰）
- 每个组件明暗双主题齐备；主题切换是**整张调色板逐帧 cross-fade 280ms**（`src/theme/mod.rs:201-226`，每 8ms 一帧，`ease_in_out_cubic`）。
- 组件只读语义色 token，从不写字面色值："Components read these, never literals"（`src/theme/palette.rs:97`）。

## 1. 调色板结构

`Palette` 共 **36 个语义色 + 8 个图表色 + 16 个 ANSI 色 + 13 个语法色**（`src/theme/tests.rs:54,69`）。本节列出对 iOS 版最关键的部分，全部为源码真实 hex（`src/theme/palette.rs:176-244` 亮色、`:247-315` 暗色）。

### 1.1 亮色主题（`Palette::light`）

| Token | Hex | 用途 |
|---|---|---|
| `bg` | `#FCFAF7` | 页面背景（暖白，非纯白） |
| `surface` | `#FFFFFF` | 卡片/输入框表面 |
| `sunken` | `#F6F4F1` | 凹陷区域（分段控件轨道、禁用输入框、Well） |
| `overlay` | `#FFFFFF` | 弹层表面（对话框卡片） |
| `hover` | `#F2F0ED` | 悬停 |
| `active` | `#E9E7E5` | 按下 |
| `border` | `#E1DFDD` | 常规边框 |
| `border_strong` | `#CCCAC8` | 输入框/勾选框边框 |
| `fg` | `#181613` | 一级文字（暖黑墨色） |
| `fg_muted` | `#605D5A` | 二级文字（muted） |
| `fg_subtle` | `#696764` | 三级/辅助文字 |
| `fg_disabled` | `#ACAAA8` | 禁用文字 |
| `accent` | `#181613` | **主色＝墨色本身**（不是彩色品牌色） |
| `accent_hover` | `#302D2B` | 主色悬停 |
| `on_accent` | `#FCFAF7` | 主色之上的文字 |
| `focus` | `#3772BB` | 焦点环/聚焦输入框边框 |
| `link` | `#2863AB` | 链接 |
| `selection` | `#3772BB33`（20% α）| 文本选区 |
| `success` | `#267B4C` | 成功 |
| `warning` | `#A25F12` | 警告 |
| `danger` | `#BA3E38` | 危险 |
| `info` | `#2E69B2` | 信息 |
| `success_subtle` | `#E7F9EC` | 成功淡底（横幅/图标底） |
| `warning_subtle` | `#FEF2DD` | 警告淡底 |
| `danger_subtle` | `#FFEFEC` | 危险淡底 |
| `info_subtle` | `#EBF4FF` | 信息淡底 |
| `backdrop` | `#18161352`（32% α）| 对话框遮罩 |
| `glass` | `#FCFAF7B8`（72% α）| 毛玻璃底 |
| `shadow` | `#181613` | 阴影色（暖黑） |
| `tooltip_bg` / `tooltip_fg` | `#181613` / `#FCFAF7` | 工具提示（墨色反转） |
| `paper` / `ink` | `#FFFFFF` / `#181613` | 纸/墨（打印式语义） |

### 1.2 暗色主题（`Palette::dark`）

| Token | Hex | 用途 |
|---|---|---|
| `bg` | `#131110` | 页面背景（暖近黑） |
| `surface` | `#1B1917` | 卡片表面 |
| `sunken` | `#0E0D0B` | 凹陷区域（比背景更深） |
| `overlay` | `#201F1D` | 弹层表面 |
| `hover` | `#252422` | 悬停 |
| `active` | `#2C2B29` | 按下 |
| `border` | `#2C2B29` | 常规边框（与 active 同值） |
| `border_strong` | `#413F3D` | 强边框 |
| `fg` | `#F3F1F0` | 一级文字 |
| `fg_muted` | `#AFADAB` | 二级文字 |
| `fg_subtle` | `#94928F` | 三级文字 |
| `fg_disabled` | `#5C5A58` | 禁用文字 |
| `accent` | `#F3F1F0` | **主色＝亮色前景的反转** |
| `accent_hover` | `#D9D7D5` | 主色悬停 |
| `on_accent` | `#131110` | 主色之上的文字 |
| `focus` | `#69A1E8` | 焦点 |
| `link` | `#7EB1F3` | 链接 |
| `selection` | `#69A1E84D`（30% α）| 选区 |
| `success` | `#6BBC89` | 成功 |
| `warning` | `#E8B45E` | 警告 |
| `danger` | `#E5756E` | 危险 |
| `info` | `#77ABEC` | 信息 |
| `success_subtle` | `#182C1F` | 成功淡底（暗色下是"深色化"而非淡化） |
| `warning_subtle` | `#342611` | 警告淡底 |
| `danger_subtle` | `#3A1D1B` | 危险淡底 |
| `info_subtle` | `#19273A` | 信息淡底 |
| `backdrop` | `#00000080`（50% α）| 遮罩 |
| `glass` | `#131110B8`（72% α）| 毛玻璃 |
| `shadow` | `#000000` | 阴影色 |
| `tooltip_bg` / `tooltip_fg` | `#373533` / `#F3F1F0` | 工具提示 |

**要点**：全部中性色都带暖棕偏色（亮色偏米、暗色偏褐），没有纯灰；主色是"墨色反转"而非品牌彩色 —— 这是"安静"的来源。语义色双模式下都保证可辨识，暗色下把亮度抬起来。

### 1.3 高对比度变体（`palette.rs:237-243, 308-314`）

亮色：`fg_muted #44423F`、`fg_subtle #575552`、`border #A6A4A2`、`border_strong #82807D`，`glass` 改为不透明 `bg`。
暗色：`fg_muted #CFCDCB`、`fg_subtle #AFADAB`、`border #6A6966`、`border_strong #858380`。
测试断言：高对比度下亮色 border 变暗、暗色 border 变亮（`palette.rs:352-357`），glass 失去透明（`tests.rs:80-92`）。

### 1.4 图表色板（8 hue，`palette.rs:151-165, 214-216, 285-287`）

顺序命名：Blue, Teal, Ochre, Rose, Violet, Green, Rust, Cyan（`HUE_NAMES`）。

| Hue | 亮色 | 暗色 | 色盲安全·亮 | 色盲安全·暗 |
|---|---|---|---|---|
| Blue | `#5182C1` | `#79A7E2` | `#0240B1` | `#3471E3` |
| Teal | `#009589` | `#4EB9AD` | `#08A399` | `#57B6B2` |
| Ochre | `#AA732B` | `#CD995C` | `#CD8017` | `#F6A537` |
| Rose | `#B8636B` | `#DC8A90` | `#844954` | `#DE545A` |
| Violet | `#8572BB` | `#A998DD` | `#A276E3` | `#695A91` |
| Green | `#539156` | `#7CB57D` | `#184606` | `#C4ECB7` |
| Rust | `#B66946` | `#D9906F` | `#B84F10` | `#A93D0E` |
| Cyan | `#138DB1` | `#56B2D4` | `#20789D` | `#52DAFE` |

常规图表色在各自模式的页面上对比度 ≥3:1 且三色觉异常下互相可分；另有专门的色盲安全八色（`color_blind_chart`，`Theme::set_color_blind_safe` 开关，`mod.rs:156-160`）。

### 1.5 语义色到图标的固定映射（`src/primitives/severity.rs:16-42`）

`Info → info / Success → circle-check / Warning → triangle-alert / Danger → circle-alert`；每个 Severity 同时给出实色 `color()` 与"安静底" `subtle()`。iOS 版建议同样成对提供 `xx` 与 `xxSubtle`。

## 2. 排版

- **字体**：正文/界面 = **Inter**（Regular / Medium / SemiBold / Italic，`assets/fonts/`），等宽 = **JetBrains Mono**（Regular / Medium），另捆绑 **IBM Plex Sans Regular**（`assets/fonts/ibm-plex-sans/`）。默认注册于 `Theme::init`：`font_family: "Inter"`、`mono_family: "JetBrains Mono"`（`src/theme/mod.rs:109-110`）。
- **字号阶梯**（`src/theme/tokens.rs:452-464`，1rem = 16px，整体可由 `font_scale` 缩放）：

| TextSize | px | 典型用途（源码佐证） |
|---|---|---|
| `Xs` | 11 | 徽标、小标签（badge.rs:118）、导航分组标题（nav.rs:205） |
| `Sm` | 12 | 选项卡文字（tabs.rs:185）、Toast 正文、列表副文本 |
| `Base` | 13 | **控件正文默认**（按钮 Md、输入框 Md、开关标签 switch.rs:132） |
| `Md` | 14 | Lg 控件正文、统计单位（stat.rs:133） |
| `Lg` | 16 | 对话框标题（dialog.rs:130） |
| `Xl` | 20 | 大标题 |
| `Xxl` | 24 | 统计数值默认（stat.rs:93） |
| `Display` | 32 | 展示型大数字/封面 |

- **字重**：源码只用到 `NORMAL / MEDIUM / SEMIBOLD` 三档。按钮 = MEDIUM（button.rs:275）；选项卡选中 MEDIUM、未选 NORMAL（tabs.rs:186-189）；分段选中 SEMIBOLD、未选 MEDIUM（segmented.rs:156-160）；对话框标题 SEMIBOLD（dialog.rs:131）。
- 数字排版组件齐全：`AnimatedNumber`（数值滚动）、`RelativeTime`、`NumberText/CurrencyText/PercentText/FileSizeText/DurationText`（`gpui-components.md:58-70`，实现在 `src/typography/format.rs`、`rolling.rs`）。

## 3. 尺寸与形状令牌（`src/theme/tokens.rs`）

- **控件**：高 24/28/32（Sm/Md/Lg）± 密度 −4/0/+4（`:83-108`）；水平内边距 8/12/16 ± 密度 ±2。
- **图标**：12/14/16/20/24/32（Xs–Xxl，`:121-131`）。
- **头像**：20/24/32/40/56（`:111-119`）。
- **圆角阶梯**：**Sm 4 / Md 6 / Lg 8 / Xl 12**（`:466-474`），整体可由 `radius_scale` 缩放。
- **海拔阴影**（`:476-495`，色 = `shadow` token）：

| 级别 | 亮色 | 暗色 |
|---|---|---|
| Raised | y1 blur2 α.06 | y1 blur2 α.40 |
| Floating | y1 b2 α.04 + y6 b16 α.08 | y2 b4 α.30 + y8 b24 α.45 |
| Modal | y2 b4 α.04 + y16 b40 α.14 | y4 b8 α.30 + y20 b48 α.55 |

暗色阴影更重、更弥散 —— 暗色下靠阴影分层比亮色吃力，所以透明度整体翻数倍。

- **其他关键尺寸**：对话框卡片宽 440（`:273-275`）、Toast 栈宽 360（`:277-280`）、Sheet 380（`:146-148`）、侧栏 240 / 收起 56（`:141-143`）、导航栏 Rail 48（`:243-245`）、表格行高 28/36/44（`:308-314`）、容器最大宽 640/960/1200（`:133-139`）、勾选框 16（`:400-403`）、开关轨道 **32×18**（`:416-418`）、滑杆轨道 4 / 滑块 16（`:420-426`）、进度条粗 2 / 进度环 48（`:191-198`）、FAB 56（`:186-189`）、状态点/单选点 6（`:405-412`）、Tab 指示条 **2**（`:252-255`）、迷你图 64×18（`:317-319`）、内容器宽 640/960/1200、散文最大宽 320、列表最高 280 后滚动。
- **图表尺寸**（`src/theme/chart.rs:30-43`）：整高 280、值域 gutter 48、类目脚 28、安全 inset 8、类目标签最小间距 64、线宽 **2**、气泡最大半径 24、K 线单元 8、饼图指针悬停外抬 6、网格线 1px。

## 4. 动效（`src/motion/curve.rs`）

- **时长**：`FAST 120ms` / `BASE 200ms` / `SLOW 320ms` / `THEME 280ms`（`:7-10`）；小进场位移 `NUDGE 4px`（`:13`）。
- **缓动**：进场用 `ease_out_cubic`，对称过渡用 `ease_in_out_cubic`，开关拇指/滑块用**带过冲的阻尼弹簧**（damping 0.75，峰值 1.01–1.05，`:15-16, 44-51`，测试 `:66-72`）。
- **无障碍**：`reduced_motion` 时一切时长压为 **1ms**（`:19-25`），主题淡变也停（`theme/mod.rs:140-147` 有 `set_mode_now` 直切）。
- 典型应用：Tab 指示条 SLOW 滑动 + 拉伸（tabs.rs:128,141-151）；面板交叉淡入 BASE + ease_out（tabs.rs:261-267）；对话框进场 BASE + ease_out + 4px 上浮，全屏版上浮 16px（dialog.rs:239-254）；Toast 进场 SLOW ease_out、退场 BASE ease_in_out 且**高度折叠+淡出**（toast.rs:361-379）；开关拇指弹簧过冲（switch.rs:103-117）。

## 5. 关键组件规格（对 iOS 版最有用的 13 个）

以下每条都出自源码对应行；间距用 gpui 的 tailwind 记法（`gap_1`=4、`gap_1p5`=6、`gap_2`=8、`gap_3`=12、`gap_4`=16、`gap_5`=20、`p_3`=12、`p_6`=24）。

1. **Button**（`src/buttons/button.rs`）：8 个变体 `Primary/Secondary/Outline/Ghost/Subtle/Success/Danger/Link`（`:17-29`）。色板映射（`:39-99`）：Primary = accent 底 + on_accent 字 + 无边框，hover 用 accent_hover；Secondary = surface 底 + border 边 + hover/active 底；Outline = 透明底 + border_strong；Ghost = 透明底仅 hover 出底色；Subtle = hover 色作底；Success/Danger = 语义色底 + on_accent 字，hover 向 fg 混 14%。结构：高=控件高度、内边距=控件内边距、圆角 Md 6、1px 边框、字重 MEDIUM、图标与文字 gap 6（`:255-276`）。状态：禁用 = 整体 opacity 0.45 + `cursor_not_allowed`（`:294-299`）；loading = 内容隐形占位、同宽居中转圈且拦截点击（`:280-292, 305-308`）；快捷键提示在按钮内、55% 透明度（`:245-253`）。Link 变体悬停下划线（`:310-313`）。
2. **Input**（`src/forms/input.rs`）：1px 边框三态 —— 默认 `border_strong`、聚焦 `focus`、校验失败 `danger`（`:84-90`）；底色 surface、禁用改 sunken（`:107-111`）；圆角 Md 6、高 = 控件高度、内边距 = 控件内边距（`:96-104`）；前缀/后缀插槽 + 有内容时出现清除按钮（`:131-141`）。`PasswordInput` = Lock 前缀 + Eye/EyeOff 切换后缀（`:168-201`）。
3. **Switch**（`src/forms/switch.rs`）：轨道 32×18 圆角全圆、内边距 2（`:65, 83-98`）；关 = `border_strong` 底 + `fg_muted` 拇指，开 = `accent` 底 + `on_accent` 拇指（`:67-73`）；拇指正圆、高撑满轨道、带 Raised 阴影（`:74-82`）；切换时**弹簧过冲滑动 + 底色/拇指色交叉混合**（`:103-117`）；禁用 opacity 0.5（`:98`）；标签在右侧、`Role::Switch` + `aria_toggled`（`:120-127`）。
4. **Checkbox**（`src/forms/check.rs`）：16px 方框、圆角 Sm 4、1px 边框（`:55-70`）；选中 = accent 底 + on_accent 勾图标（IconName::Check, Xs 号）；**半选态 `Mixed` 用减号图标**（`:28-42`）；选中瞬间底色从 surface→accent 过渡动画（`:66-68`）；禁用 opacity 0.5；聚焦时边框变 focus 色。
5. **Tabs**（`src/navigation/tabs.rs`）：**2px accent 下划线指示条**，选中切换时滑动 + 拉伸（glide，SLOW 320ms，`:128-153`）；条目高 28、内边距 px_3(12)、圆角 Md、文字 Sm、选中 MEDIUM + `fg`、未选 `fg_muted`、悬停变 `fg`（`:159-194`）；顶部/底部/左侧三种摆放，条带以 1px `border` 分隔（`:232-236`）；面板切换 BASE 交叉淡入（`:260-267`）；支持右键菜单回调与方向键/Home/End 导航（`:204-211, 237-256`）。
6. **SegmentedControl**（`src/buttons/segmented.rs`）：外层轨道 = `sunken` 底 + 1px border + 圆角 Lg 8 + p_0p5(2)（`:207-218`）；滑块 = `surface` 底 + 1px border + 圆角 Md + Raised 阴影，选中切换时 SLOW 滑动+拉伸（`:105-130`）；选中文字 SEMIBOLD + `fg`，未选 MEDIUM + `fg_muted`（`:137, 156-160`）；窄时标签省略、更窄时横向滚动并自动滚出聚焦段（`:20` 注释、`:77-99`）。
7. **Toast**（`src/feedback/toast.rs`）：卡片 = `surface` 底 + 1px border + 圆角 Lg 8 + Floating 阴影 + p_3(12)（`:278-288`）；结构 = Severity 图标 + 标题(MEDIUM/fg) + 正文(fg_muted) + 可选 Undo/动作按钮(Sm) + Ghost 关闭钮（`:290-333`）；栈宽 360（tokens.rs:277-280）、默认停留 **5s**、最多 **4** 条、超出踢掉最旧（`:19-22, 119-124`）；指针悬停在栈上时**计时暂停**（`:160-177`）；Undo 型底部有 2px 倒计时线（`:382-407`）；进场 SLOW ease_out，退场 BASE 高度折叠 + 淡出（`:361-379`）。
8. **Dialog**（`src/overlays/dialog.rs`）：卡片宽 440、圆角 **Xl 12**、`overlay` 底 + 1px border + Modal 阴影 + p_6(24)（`:227-234`）；标题 Lg SEMIBOLD + 副题 Sm fg_muted（`:130-142`）；动作区右对齐、按钮间 gap 8（`:148-155`）；进场 BASE ease_out：淡入 + 4px 上浮（`:239-254`）；Esc 关闭、Enter 触发主字段、FocusScope 焦点陷阱（`:255-276`）；全屏变体：bg 全屏 + 顶栏（标题 + Ghost 关闭钮）+ 底部动作条，各以 1px border 分隔（`:165-209`）。
9. **Statistic / TrendIndicator**（`src/data_display/stat.rs`）：标签 Sm fg_muted 在上；数值默认 **Xxl(24)** 且用 `AnimatedNumber` 滚动到新值；前缀/后缀（货币符/单位）Md fg_muted 与数值基线对齐（`:126-151`）；趋势 = TrendingUp/Down/Minus 图标 + 百分比，**好方向 = success、坏方向 = danger、不动 = fg_muted**，成本类可设 `down_is_good`（`:13-15, 44-67`）。
10. **Badge / CountBadge / DotBadge**（`src/data_display/badge.rs`）：徽标圆角 Sm 4、字号 Xs 11（`:116-118`）；计数徽标全圆、封顶显示 99+（`:153, 178-187`）；状态点 6px 全圆（`:204-208`）。
11. **Avatar**（`src/data_display/avatar.rs`）：五档 20/24/32/40/56；**默认圆形，团队/应用用圆角方（Radius Md）**（`:106-111, 141-163`）；无图回退首字母，字号随档位 Xs/Sm/Md/Lg（`:150-153`）；在线状态点外描一圈 `bg` 色使其独立于底图（badge.rs:247-251）。
12. **侧栏导航 NavItem/NavGroup**（`src/navigation/nav.rs`）：条目高 28、圆角 Md、文字 Sm、px_2（`:82-86, 121`）；选中 = `hover` 底 + MEDIUM + 左缘 **2px accent 圆头条**（`:94-102`）；悬停底色 + 文字变 fg（`:105`）；分组标题 Xs 号、高 24（`:200-205`）；侧栏宽 240 / 收起 56（tokens.rs:141-143）。
13. **图表**（`src/charts/` + `theme/chart.rs`）：色板见 §1.4；线宽 2、网格/坐标轴 1px 发丝线；整高 280 含图例与轴；饼图悬停切片外抬 6px；`ChartSizes`（`chart.rs:7-27`）集中管理所有度量。iOS 版做记录类 App 的趋势图时，直接取 8 hue 的亮/暗两套即可保证双模式可读。

## 6. 组件清单的广度（`gpui-components.md`）

该文件是 44 章的**完整规划清单**（基础原语 → 排版 → 布局 → 窗口外壳 → 按钮 → 表单 → 导航 → 菜单 → 浮层 → 反馈 → 加载动效 → 数据展示 → 列表树 → 表格 → 图表 → 金融 → IDE → 终端 → Git → 调试 → 文档富文本 → 协作 → AI 对话 → Agent → 生成式 → 媒体 → 文件 → IM → 邮件 → 日历 → 项目管理 → 画布 → 数据库 → 监控 → 设置 → 账户 → 引导 → 交互原语 → 主题 → i18n/a11y → 地图 → 杂项 → 工具 → 渲染表面）。`TASKS.md` 显示 T00–T50+ 各章已基本完成（全部 `[x]`，`TASKS.md:19-40`），`src/` 下 44 个模块目录与之一一对应。**注意：清单里还有大量条目属于规划命名而非独立实现**（如金融 K 线、AI Agent 面板等在其专章模块内），引用具体组件时应以 `src/` 实际文件为准。

## 7. 设计原则 → SwiftUI 映射

1. **语义色先行**：36 个 Palette token 落成 `Color` 扩展（如 `Color.elyBg` / `.elyAccent`…），组件代码只写语义名。明暗两套 hex 放 Asset Catalog 的 Any/Dark Appearance，或用 `@Environment(\.colorScheme)` 切换；高对比度变体对应 `@Environment(\.colorSchemeContrast)` 增加 `highContrast` 档。
2. **暖中性 + 墨色主色**：背景永远不是纯白/纯黑（#FCFAF7 / #131110）；主按钮 = `fg ↔ on_accent` 的墨色反转（亮色模式黑底米字、暗色模式米底黑字）。SwiftUI 里 `Button` 的 primary 样式直接绑 `elyAccent`/`elyOnAccent`，不引入品牌彩色。颜色只在 success/warning/danger/info 和图表 hue 上出现 —— "颜色承载含义"。
3. **令牌化度量**：控件高度 24/28/32、圆角 4/6/8/12、图标 12–32、字阶 11–32 全部走常量表（一个 `enum ElySize` + `@ScaledMetric` 实现等效 font_scale，并支持 Dynamic Type）。
4. **动效有固定节奏**：120/200/320ms 三档 + `easeOut(cubic)` 进场、对称过渡 `easeInOut`、开关/滑块用 SwiftUI `.spring(duration: 0.2, bounce: 0.02)` 近似源码的阻尼弹簧（过冲 1–5%）；`@Environment(\.accessibilityReduceMotion)` 命中时退化为 1ms/无位移。
5. **分层靠表面而非线**：同一平面用 bg→surface→sunken→overlay 四层表面 + 1px 边框 + 三档阴影（暗色阴影更重）；iOS 端 dialog 用 `overlay` 底色 + 12pt 圆角 + Modal 阴影，Toast 用 surface + 8pt 圆角 + Floating 阴影，可分别映射 `CN1` 风格的自定义卡片而非系统 alert。
6. **无障碍内建**：每个交互件带 Role/aria（GPUI 侧）→ SwiftUI 侧对应 `accessibilityLabel/addTraits`；图表提供色盲安全八色备选；焦点色 `focus` 专色（#3772BB / #69A1E8）用于键盘/焦点环，不与品牌色混用。

## 8. 源码引用索引

| 主题 | 文件 |
|---|---|
| 调色板（全部 hex） | `reference/ely/src/theme/palette.rs:176-315` |
| 尺寸/圆角/阴影令牌 | `reference/ely/src/theme/tokens.rs:83-495` |
| 主题机制（cross-fade、高对比、色盲） | `reference/ely/src/theme/mod.rs:97-227` |
| 图表度量 | `reference/ely/src/theme/chart.rs` |
| 动效时长/缓动/弹簧 | `reference/ely/src/motion/curve.rs:7-51` |
| 按钮 | `reference/ely/src/buttons/button.rs` |
| 输入框 | `reference/ely/src/forms/input.rs` |
| 开关 / 勾选框 | `reference/ely/src/forms/switch.rs`、`check.rs` |
| 选项卡 / 分段控件 | `reference/ely/src/navigation/tabs.rs`、`src/buttons/segmented.rs` |
| Toast / 对话框 | `reference/ely/src/feedback/toast.rs`、`src/overlays/dialog.rs` |
| 统计/徽标/头像 | `reference/ely/src/data_display/stat.rs`、`badge.rs`、`avatar.rs` |
| 语义映射 | `reference/ely/src/primitives/severity.rs` |
| 字体资产 | `reference/ely/assets/fonts/` |
| 组件清单（规划） | `reference/ely/gpui-components.md` |
