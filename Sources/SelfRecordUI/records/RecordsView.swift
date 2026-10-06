import Charts
import SelfRecordCore
import SwiftUI

// MARK: - RecordsView（design.md §6「记录」Tab）
//
// 顶部 SRSegmented 三段：时间 / 睡眠 / 饮食（§6 页面地图）。
// 各页实现在本目录 TimeView.swift / SleepView.swift / DietView.swift。

/// 顶层三段。
enum RecordsSegment: String, CaseIterable, Identifiable {
    case time, sleep, diet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .time: return "时间"
        case .sleep: return "睡眠"
        case .diet: return "饮食"
        }
    }
}

/// 容器页面态（SwiftUI 宏禁令 §8 约定 5：ObservableObject 路径）。
/// 非 @MainActor：仅由主线程 View 持有驱动（@StateObject / @ObservedObject）。
final class RecordsPageModel: ObservableObject {
    // 自动化冒烟导航钩子：启动参数 SR_SEGMENT=<time|sleep|diet>（同 SelfRecordApp 的 SR_TAB）。
    @Published var segment: RecordsSegment = {
        guard let raw = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("SR_SEGMENT=") })?
            .dropFirst("SR_SEGMENT=".count),
            let segment = RecordsSegment(rawValue: String(raw)) else { return .time }
        return segment
    }()
}

public struct RecordsView: View {

    @ObservedObject public var model: AppModel
    @StateObject private var page = RecordsPageModel()

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: SRSpacing.md) {
            SRSegmented(options: RecordsSegment.allCases, selection: $page.segment) { $0.label }
                .padding(.horizontal, SRSpacing.lg)
                .padding(.top, SRSpacing.sm)
            switch page.segment {
            case .time: TimeView(model: model)
            case .sleep: SleepView(model: model)
            case .diet: DietView(model: model)
            }
        }
        .background(Color.srBackground)
    }
}

// MARK: - 分组内共享的展示辅助（纯值 → 展示串，无业务规则）

enum RecordsFmt {

    /// 时刻 → "HH:mm"。
    static func hm(_ date: Date, calendar: DayCalendar) -> String {
        String(format: "%02d:%02d", calendar.hour(of: date), calendar.minute(of: date))
    }

    /// DayKey → 短日标（图表 x 轴 / 列表行）："2026-10-06" → "10-06"。
    static func dayLabel(_ day: DayKey) -> String {
        String(day.rawValue.dropFirst(5))
    }

    /// DayKey → 中文月日（补录/编辑 sheet 的归属预览文案用）："2026-10-05" → "10月5日"。
    static func monthDayLabel(_ day: DayKey) -> String {
        let parts = day.rawValue.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let dom = Int(parts[2])
        else { return day.rawValue }
        return "\(month)月\(dom)日"
    }

    /// 克数 → 输入框友好串（整数值不带小数点）。
    static func gramsText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// FoodTag → 中文标签（lifttime foods.js tags 的展示名）。
    static func foodTagLabel(_ tag: FoodTag) -> String {
        switch tag {
        case .protein: return "蛋白质"
        case .carb: return "碳水"
        case .veg: return "蔬菜"
        case .fruit: return "水果"
        case .dairy: return "乳制品"
        case .fat: return "脂肪"
        case .junk: return "高油糖"
        case .drink: return "饮品"
        case .supp: return "补剂"
        case .custom: return "自定义"
        }
    }
}

// MARK: - List 行样式（分组内统一）

extension View {

    /// 记录页 List 行统一：透明底、隐藏分隔线、统一 insets（卡片自带视觉边界）。
    func srRecordsRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(
                EdgeInsets(top: SRSpacing.xs, leading: SRSpacing.lg,
                           bottom: SRSpacing.xs, trailing: SRSpacing.lg)
            )
    }

    /// 空态提示文案。
    func srRecordsEmptyHint(_ text: String) -> some View {
        Text(text)
            .srFont(.sm)
            .foregroundStyle(Color.srForegroundMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 卡片内小节标题（Sm muted，与 DesignSystem 层级一致）。
struct RecordsSectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .srFont(.sm, .medium)
            .foregroundStyle(Color.srForegroundMuted)
    }
}

// MARK: - 图表 x 轴挂法（分组内）

extension View {
    /// x 轴类目标签。DesignSystem 的 `srYAxisGrid()` / `srXAxisCategories()` 都是
    /// `Chart` 扩展且返回 `some View`，两个不能链式叠加——SRChart.swift 注释
    /// （"x 轴需要同款时调用方再挂 `.chartXAxis`"）认可调用方自挂；`chartXAxis`
    /// 本身是 View 修饰器，故这里以 View 扩展落地，样式逐项取自设计系统
    /// （`.sr(.sm)` 字阶 + fg_muted，与 srXAxisCategories 同规格）。
    func srRecordsXAxis() -> some View {
        chartXAxis {
            AxisMarks { _ in
                AxisValueLabel()
                    .font(.sr(.sm))
                    .foregroundStyle(Color.srForegroundMuted)
            }
        }
    }
}
