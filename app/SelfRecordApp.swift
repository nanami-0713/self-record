import SelfRecordCore
import SwiftUI
import SelfRecordUI

// MARK: - SelfRecordApp（design.md §8 目录树 / §6 页面地图）
//
// iOS 应用入口：@main + 根 TabView（5 Tab：今日 / 记录 / 训练 / 预算 / 设置，
// 图标与页面一一对应 §6 表格）。各页面实现在 SelfRecordUI 的五个界面分组目录，
// 本文件只做装配，不含业务逻辑。
//
// ⚠ 本文件不在任何 SwiftPM target 内（Package.swift 的 target 路径均不含 app/），
// 不参与 `swift build`——只由 app/project.yml（XcodeGen）生成的工程编译；
// Xcode 侧是完整工具链，无本机 CLT 的宏插件缺失问题（§0-2 / §12.4）。
//
// 接线说明（§6）：
// - 今日页五张域卡片的跳转闭包接到 TabView selection（today 分组不拥有顶层
//   导航，§8 约定 4）。时间/睡眠/饮食三卡都落到「记录」Tab；其顶部三段
//   （时间/睡眠/饮食）暂未外露程序控制——RecordsPageModel 是该模块内部类型，
//   入口侧只能切到 Tab 级，进入后默认停在「时间」段。
// - 主题生效点在根部 preferredColorScheme（与 SettingsView「主题」一节的
//   注释及 §7.4「主题切换」行一致：跟随系统 + 设置页手动覆盖）。
// - 状态管理沿用全工程 ObservableObject 路径（§8 约定 5），异步加载用
//   `Task { await … }`——与 SelfRecordUI 各页已在本机 swift build 验证过的
//   写法一致（如 SettingsView 的 applySettings 调用），不引入新 API 面。

@main
struct SelfRecordApp: App {

    // MARK: - 顶层 Tab 路由（§6 页面地图五个 Tab）

    enum Tab: String, Hashable {
        case today, records, workout, budget, settings
    }

    /// 根路由容器（§8 约定 5：ObservableObject + @Published，非宏路径）。
    private final class Router: ObservableObject {
        // 自动化冒烟导航钩子：启动参数 SR_TAB=<today|records|workout|budget|settings>
        // （xcrun simctl launch 传入；正式启动不含该参数，默认今日）。
        @Published var tab: Tab = {
            guard let raw = ProcessInfo.processInfo.arguments
                .first(where: { $0.hasPrefix("SR_TAB=") })?
                .dropFirst("SR_TAB=".count),
                let tab = Tab(rawValue: String(raw)) else { return .today }
            return tab
        }()
    }

    @StateObject private var router = Router()

    /// 主状态容器（冻结物 C）：`<ApplicationSupport>/SelfRecord/`（§5）。
    @StateObject private var model: AppModel

    /// 退后台立即落盘防抖窗口内的变更（DataStore.flushNow 的设计钩子，§5：
    /// 「commit 立即写 + 150ms 防抖合并」——挂起后 Task.sleep 不再触发，
    /// 不显式 flush 的话最后一笔会在进程回收时丢失）。
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // iOS 26 Liquid Glass 底部 Tab 栏不吃 TabView 的 .tint()（实测仍渲染
        // 系统蓝），经 appearance 代理注入 Ely 墨色主色（亮 #181613 / 暗 #F3F1F0）。
        UITabBar.appearance().tintColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0xF3 / 255, green: 0xF1 / 255, blue: 0xF0 / 255, alpha: 1)
                : UIColor(red: 0x18 / 255, green: 0x16 / 255, blue: 0x13 / 255, alpha: 1)
        }
        // 局部常量先持有模型（AppModel 是 class），Task 闭包捕获它而非
        // mutating self——App 结构体 init 里不能被逃逸闭包捕获。
        let model = SelfRecordApp.makeModel()
        _model = StateObject(wrappedValue: model)
        // 启动全量载入（§5：启动即读崩溃恢复态 active.json，常驻状态条依赖它）。
        Task { await model.loadAll() }
    }

    var body: some Scene {
        WindowGroup {
            rootTabs
                // WorkoutListView / SettingsView 经环境取 AppModel（二者是
                // @EnvironmentObject 形态；其余页面按参数注入，双通道并存）。
                .environmentObject(model)
                .preferredColorScheme(colorScheme)
                // inactive（拉通知中心/切走）即 flush：等 .background 可能来不及
                .onChange(of: scenePhase) { _, phase in
                    if phase == .inactive || phase == .background {
                        Task { await model.store.flushNow() }
                    }
                }
        }
    }

    // MARK: - 存储装配（默认目录 → 临时目录降级，不因磁盘异常启动崩溃）

    private static func makeModel() -> AppModel {
        do {
            return try AppModel(directory: DataStore.defaultDirectory())
        } catch {
            // ApplicationSupport 创建失败（磁盘只读/权限异常等极罕见情形）：
            // 退临时目录降级运行——数据不落正式位置，但界面可用、不崩溃。
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("SelfRecord-Fallback", isDirectory: true)
            guard let degraded = try? AppModel(directory: fallback) else {
                preconditionFailure(
                    "SelfRecord: ApplicationSupport 与临时目录均不可创建，无法初始化存储: \(error)")
            }
            return degraded
        }
    }

    // MARK: - 主题（ThemeMode → ColorScheme?；nil = 跟随系统）

    private var colorScheme: ColorScheme? {
        switch model.settings.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    // MARK: - 根 TabView（§6：Tab × 图标 × 页面）

    private var rootTabs: some View {
        TabView(selection: $router.tab) {
            TodayView(
                appModel: model,
                onOpenTime: { router.tab = .records },
                onOpenSleep: { router.tab = .records },
                onOpenDiet: { router.tab = .records },
                onOpenWorkout: { router.tab = .workout },
                onOpenBudget: { router.tab = .budget }
            )
            .tabItem { Label("今日", systemImage: "house") }
            .tag(Tab.today)

            RecordsView(model: model)
                .tabItem { Label("记录", systemImage: "list.bullet") }
                .tag(Tab.records)

            // NavigationStack：WorkoutListView 的行点击走 NavigationLink push 详情页，
            // 宿主约定（该文件头注释）要求外部提供导航容器——TabView 不自带
            // （2026-10-12 修复：此前裸挂导致详情页进不去、navigationTitle 不显示）。
            NavigationStack {
                WorkoutListView()
            }
                .tabItem { Label("训练", systemImage: "dumbbell") }
                .tag(Tab.workout)

            BudgetView(model: model)
                .tabItem { Label("预算", systemImage: "creditcard") }
                .tag(Tab.budget)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // Ely 主色 = 墨色反转（§7.1 accent），TabView 不加 tint 会落回系统蓝
        .tint(.srAccent)
    }
}
