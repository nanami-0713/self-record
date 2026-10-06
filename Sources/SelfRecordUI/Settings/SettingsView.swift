import SelfRecordCore
import SwiftUI

// MARK: - SettingsView（design.md §6 设置页：体重/单位/主题/睡眠目标/周月预算）
//
// 页面结构：NavigationStack + 分组卡（SRCard）；表单草稿与绑定放
// SettingsFormModel（ObservableObject，宏禁令 §8 约定 5 下页面局部状态的唯一合法形态）。
// 数据流：绑定改 AppSettings 快照 → model.applySettings 落盘（DataStore 防抖合并高频写）。

/// 设置页表单状态：体重/预算三个数字草稿 + 校验标志 + 各控件的持久化绑定。
/// 单位换算只在展示层（Formatting，design.md §4「内部恒 kg」）。
@MainActor
final class SettingsFormModel: ObservableObject {

    @Published var weightText = ""
    @Published var weeklyBudgetText = ""
    @Published var monthlyBudgetText = ""
    @Published var weightInvalid = false
    @Published var weeklyInvalid = false
    @Published var monthlyInvalid = false

    /// 从当前设置回填草稿（onAppear / 单位切换 / 导入覆盖后）。
    func sync(from settings: AppSettings) {
        weightText = settings.bodyweightKg
            .map { Self.displayNumber(Self.displayValue(kg: $0, unit: settings.unit)) } ?? ""
        weeklyBudgetText = settings.weeklyBudgetYuan.map(Self.displayNumber) ?? ""
        monthlyBudgetText = settings.monthlyBudgetYuan.map(Self.displayNumber) ?? ""
        weightInvalid = false
        weeklyInvalid = false
        monthlyInvalid = false
    }

    // MARK: 绑定（每次求值新建；setter 组新快照异步落盘，AppSettings 为 Sendable 值类型）

    /// 单位切换（kg/lb）。切换后体重草稿按新单位重排显示。
    func unitBinding(_ model: AppModel) -> Binding<SRSimpleOption> {
        Binding(
            get: { SRSimpleOption(id: model.settings.unit.rawValue) },
            set: { option in
                guard let unit = WeightUnit(rawValue: option.id),
                      unit != model.settings.unit else { return }
                var next = model.settings
                next.unit = unit
                Task { await model.applySettings(next) }
                self.sync(from: next)
            }
        )
    }

    /// 主题（跟随系统/浅色/深色）。生效点在应用根部 preferredColorScheme（§7.4「主题切换」行）。
    func themeBinding(_ model: AppModel) -> Binding<SRSimpleOption> {
        Binding(
            get: { SRSimpleOption(id: model.settings.theme.rawValue) },
            set: { option in
                guard let theme = ThemeMode(rawValue: option.id),
                      theme != model.settings.theme else { return }
                var next = model.settings
                next.theme = theme
                Task { await model.applySettings(next) }
            }
        )
    }

    /// 睡眠目标（分钟 ↔ Slider 的 Double；步进 30 分，域 = 净化界 240–720）。
    func sleepGoalBinding(_ model: AppModel) -> Binding<Double> {
        Binding(
            get: { Double(model.settings.sleepGoalMinutes) },
            set: { value in
                let minutes = Int(value.rounded())
                guard minutes != model.settings.sleepGoalMinutes else { return }
                var next = model.settings
                next.sleepGoalMinutes = min(max(minutes, SanitizeLimits.sleepGoalRange.lowerBound),
                                            SanitizeLimits.sleepGoalRange.upperBound)
                Task { await model.applySettings(next) }
            }
        )
    }

    /// 体重（按显示单位输入；空 = 未设置）。解析失败 / 越域 → 标红不写入。
    func weightTextBinding(_ model: AppModel) -> Binding<String> {
        Binding(
            get: { self.weightText },
            set: { text in
                self.weightText = text
                self.commitWeight(text, model: model)
            }
        )
    }

    func weeklyBudgetTextBinding(_ model: AppModel) -> Binding<String> {
        Binding(
            get: { self.weeklyBudgetText },
            set: { text in
                self.weeklyBudgetText = text
                self.commitBudget(text, invalid: \.weeklyInvalid, model: model) { $0.weeklyBudgetYuan = $1 }
            }
        )
    }

    func monthlyBudgetTextBinding(_ model: AppModel) -> Binding<String> {
        Binding(
            get: { self.monthlyBudgetText },
            set: { text in
                self.monthlyBudgetText = text
                self.commitBudget(text, invalid: \.monthlyInvalid, model: model) { $0.monthlyBudgetYuan = $1 }
            }
        )
    }

    // MARK: 提交

    private func commitWeight(_ text: String, model: AppModel) {
        let current = model.settings
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            weightInvalid = false
            guard current.bodyweightKg != nil else { return }
            var next = current
            next.bodyweightKg = nil
            Task { await model.applySettings(next) }
            return
        }
        guard let value = Self.parseNumber(text) else {
            weightInvalid = true
            return
        }
        let kg = current.unit == .pound ? Formatting.lbToKg(value) : value
        guard SanitizeLimits.bodyweightRange.contains(kg) else {
            weightInvalid = true
            return
        }
        weightInvalid = false
        guard current.bodyweightKg != kg else { return }
        var next = current
        next.bodyweightKg = kg
        Task { await model.applySettings(next) }
    }

    private func commitBudget(_ text: String,
                              invalid: ReferenceWritableKeyPath<SettingsFormModel, Bool>,
                              model: AppModel,
                              assign: @escaping (inout AppSettings, Double?) -> Void) {
        let current = model.settings
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = current
        if trimmed.isEmpty {
            self[keyPath: invalid] = false
            assign(&next, nil)
        } else {
            guard let value = Self.parseNumber(text),
                  SanitizeLimits.amountRange.contains(value) else {
                self[keyPath: invalid] = true
                return
            }
            self[keyPath: invalid] = false
            assign(&next, value)
        }
        guard next != current else { return }   // AppSettings: Equatable，值未变不落盘
        Task { await model.applySettings(next) }
    }

    // MARK: 数字展示（展示层换算只在 Formatting 与此处，§4「内部恒 kg」）

    /// kg → 显示单位数值。
    private static func displayValue(kg: Double, unit: WeightUnit) -> Double {
        unit == .pound ? Formatting.kgToLb(kg) : kg
    }

    /// 最多一位小数、去尾零：`72.0` → "72"，`72.5` → "72.5"。
    private static func displayNumber(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(format: "%.0f", rounded) }
        return String(format: "%.1f", rounded)
    }

    /// 宽容解析：全角句点归一为小数点。
    private static func parseNumber(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: "．", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }
}

// MARK: - 视图

public struct SettingsView: View {

    @EnvironmentObject private var model: AppModel
    @StateObject private var form = SettingsFormModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SRSpacing.xl) {
                    section("体重与单位") { bodyCard }
                    section("外观") { themeCard }
                    section("睡眠") { sleepCard }
                    section("预算") { budgetCard }
                    section("数据") { linksCard }
                }
                .padding(.horizontal, SRSpacing.lg)
                .padding(.vertical, SRSpacing.xl)
            }
            .background(Color.srBackground)
            .navigationTitle("设置")
        }
        .onAppear { form.sync(from: model.settings) }
    }

    // MARK: 分节骨架（小节标签 Sm muted + SRCard，§7.2/§7.4）

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.sm) {
            Text(title)
                .srFont(.sm, .medium)
                .foregroundStyle(Color.srForegroundMuted)
            SRCard {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 体重与单位

    private var bodyCard: some View {
        VStack(alignment: .leading, spacing: SRSpacing.md) {
            SRField(text: form.weightTextBinding(model),
                    placeholder: "如 72.5",
                    icon: "scalemass",
                    isInvalid: form.weightInvalid,
                    keyboard: .decimal)
            SRSegmented(options: [WeightUnit.kilogram.rawValue, WeightUnit.pound.rawValue]
                            .map { SRSimpleOption(id: $0) },
                        selection: form.unitBinding(model)) { option in
                option.id == WeightUnit.pound.rawValue ? "lb 磅" : "kg 公斤"
            }
            .frame(width: 200, alignment: .leading)
            fieldHint(form.weightInvalid
                      ? "请输入 0–2000 kg 范围内的数字（磅按当前单位换算）"
                      : "体重用于营养目标与训练恢复建议；内部以 kg 存储")
        }
    }

    // MARK: 外观

    private var themeCard: some View {
        SRSegmented(options: [ThemeMode.system.rawValue, ThemeMode.light.rawValue, ThemeMode.dark.rawValue]
                        .map { SRSimpleOption(id: $0) },
                    selection: form.themeBinding(model)) { option in
            switch ThemeMode(rawValue: option.id) {
            case .light: "浅色"
            case .dark: "深色"
            default: "跟随系统"
            }
        }
    }

    // MARK: 睡眠目标

    private var sleepCard: some View {
        VStack(alignment: .leading, spacing: SRSpacing.sm) {
            HStack {
                Text("每晚睡眠目标")
                    .srFont(.base)
                    .foregroundStyle(Color.srForeground)
                Spacer()
                Text(sleepGoalLabel)
                    .srFont(.md, .medium)
                    .monospacedDigit()
                    .foregroundStyle(Color.srForegroundMuted)
            }
            Slider(value: form.sleepGoalBinding(model),
                   in: Double(SanitizeLimits.sleepGoalRange.lowerBound)...Double(SanitizeLimits.sleepGoalRange.upperBound),
                   step: 30)
                .tint(Color.srAccent)
            HStack {
                Text("4 小时").srFont(.xs).foregroundStyle(Color.srForegroundSubtle)
                Spacer()
                Text("12 小时").srFont(.xs).foregroundStyle(Color.srForegroundSubtle)
            }
            fieldHint("用于睡眠分与睡眠债计算")
        }
    }

    private var sleepGoalLabel: String {
        let minutes = model.settings.sleepGoalMinutes
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    // MARK: 预算

    private var budgetCard: some View {
        VStack(alignment: .leading, spacing: SRSpacing.md) {
            budgetField(label: "周预算（自然周，周一起）",
                        text: form.weeklyBudgetTextBinding(model),
                        isInvalid: form.weeklyInvalid)
            budgetField(label: "月预算（自然月）",
                        text: form.monthlyBudgetTextBinding(model),
                        isInvalid: form.monthlyInvalid)
            fieldHint("留空表示不设预算；用于预算页进度与节奏预测")
        }
    }

    private func budgetField(label: String, text: Binding<String>, isInvalid: Bool) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            Text(label)
                .srFont(.base)
                .foregroundStyle(Color.srForeground)
            SRField(text: text,
                    placeholder: "如 300",
                    isInvalid: isInvalid,
                    keyboard: .decimal) {
                Text("¥")
                    .srFont(.md)
                    .foregroundStyle(Color.srForegroundMuted)
            }
            if isInvalid {
                Text("请输入 0–10,000,000 范围内的金额")
                    .srFont(.sm)
                    .foregroundStyle(Color.srDanger)
            }
        }
    }

    // MARK: 数据入口（跳分类管理 / 数据管理）

    private var linksCard: some View {
        VStack(spacing: 0) {
            NavigationLink {
                CategoryManagerView()
            } label: {
                linkRow(icon: "paintpalette",
                        title: "时间分类管理",
                        subtitle: "分类的增删改与取色")
            }
            .buttonStyle(.plain)
            separator
            NavigationLink {
                DataManagementView()
            } label: {
                linkRow(icon: "externaldrive",
                        title: "数据管理",
                        subtitle: "导出 / 导入 / 清空")
            }
            .buttonStyle(.plain)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.srBorder)
            .frame(height: 1)
    }

    private func linkRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: SRSpacing.md) {
            Image(systemName: icon)
                .font(.sr(.base))
                .foregroundStyle(Color.srForegroundMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .srFont(.base)
                    .foregroundStyle(Color.srForeground)
                Text(subtitle)
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.sr(.sm))
                .foregroundStyle(Color.srForegroundSubtle)
        }
        .padding(.vertical, SRSpacing.sm)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func fieldHint(_ text: String) -> some View {
        Text(text)
            .srFont(.sm)
            .foregroundStyle(Color.srForegroundMuted)
    }
}
