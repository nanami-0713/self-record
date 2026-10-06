import SelfRecordCore
import SwiftUI

// MARK: - DietView（design.md §6「记录 · DietView」）
//
// 自然语言记餐（DietEngine.parseMealText：中文数字/市制两/量词/尾部克数）→
// 解析确认卡三层标记（库命中含 tags / 手估可改克数可排除 / 未识别不计入）→
// 餐次选择（guessMeal 自动预选）+ 花费输入（costYuan >0 联动预算）→
// 日宏量总结 + 目标达成（dailySummary）+ 日/周/月切换（periodDiet）+ 日建议列表。
//
// 口径注记（§3.4）：tags 只挂库命中项；手估项无 tags、不参与「无蔬果/junk」判定；
// 被排除的手估行存回 unmatched（未识别，不计入）。

/// 日/周/月三档。
enum DietRangeTab: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        }
    }

    var days: Int? {
        switch self {
        case .day: return nil
        case .week: return 7
        case .month: return 30
        }
    }
}

/// 手估行（三层兜底第②层的预填，可改克数、可整项不计入）。
/// 不计入的行保存时回到 unmatched（未识别语义），name 即原始未识别文本。
struct DietManualRow: Identifiable {
    let id: UUID
    let name: String
    var gramsText: String
    let per100g: Per100g
    let guessCategoryKey: String
    var isCounted: Bool

    init(id: UUID = UUID(), item: ManualFoodItem) {
        self.id = item.id
        self.name = item.name
        self.gramsText = RecordsFmt.gramsText(item.grams)
        self.per100g = item.per100g
        self.guessCategoryKey = item.guessCategory ?? "other"
        self.isCounted = true
    }

    var grams: Double { Double(gramsText) ?? 0 }

    var categoryLabel: String { DietEngine.estimateCategory(for: guessCategoryKey).label }

    var manualItem: ManualFoodItem {
        ManualFoodItem(id: id, name: name, grams: grams, per100g: per100g,
                       isExcluded: false, guessCategory: guessCategoryKey)
    }
}

/// DietView 页面态（SwiftUI 宏禁令 §8 约定 5：ObservableObject 路径）。
final class DietRecordsModel: ObservableObject {

    @Published var range: DietRangeTab = .day
    @Published var rawText = ""
    @Published var showsConfirm = false
    @Published var mealRaw = MealSlot.snack.rawValue
    @Published var costText = ""
    @Published var parsedItems: [FoodMatch] = []
    @Published var rows: [DietManualRow] = []

    /// 引擎解析出的命中项合计（不需要驱动 UI，不入 @Published）。
    var parsedTotals = MacroTotals()
    var draftRawText = ""

    /// 餐次六档（lifttime nutrition.js:5-12 MEALS 顺序；MealSlot 无 CaseIterable）。
    static let mealOptionKeys = ["breakfast", "lunch", "dinner", "snack", "preworkout", "postworkout"]

    var meal: MealSlot { MealSlot(rawValue: mealRaw) ?? .snack }

    var countedRows: [DietManualRow] { rows.filter(\.isCounted) }
    var excludedRows: [DietManualRow] { rows.filter { !$0.isCounted } }

    var countedManualItems: [ManualFoodItem] { countedRows.map(\.manualItem) }
    var excludedNames: [String] { excludedRows.map(\.name) }

    /// 解析并预填确认卡（引擎：parseMealText + guessFor + guessMeal 自动预选餐次）。
    func beginParse(customFoods: [CustomFood], calendar: DayCalendar,
                    workouts: [Workout], entries: [DietEntry], now: Date) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let parsed = DietEngine.parseMealText(text, customFoods: customFoods)
        draftRawText = text
        parsedItems = parsed.items
        parsedTotals = parsed.totals
        rows = parsed.unmatched.map { DietManualRow(item: DietEngine.guessFor($0)) }
        mealRaw = DietEngine.guessMeal(now: now, calendar: calendar,
                                       workouts: workouts, entries: entries).rawValue
        costText = ""
        showsConfirm = true
    }

    /// 关闭确认卡（保留原文便于改写重试）。
    func closeConfirm() {
        showsConfirm = false
        parsedItems = []
        rows = []
        parsedTotals = MacroTotals()
        draftRawText = ""
        costText = ""
    }

    /// 保存成功后的完整清理。
    func resetAfterSave() {
        closeConfirm()
        rawText = ""
    }

    /// 未识别行改回手估计入。
    func recallRow(id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].isCounted = true
    }
}

struct DietView: View {

    @ObservedObject var model: AppModel
    @StateObject private var page = DietRecordsModel()

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        List {
            Section {
                entryCard
                    .srRecordsRow()
            }
            Section {
                summarySection
                    .srRecordsRow()
            }
            Section {
                Text("今日记录").srFont(.lg, .semibold)
                    .srRecordsRow()
                ForEach(todayEntries) { entry in
                    entryRow(entry)
                        .srRecordsRow()
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                model.deleteDietEntry(id: entry.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                model.deleteDietEntry(id: entry.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSeparator(.hidden)
        .scrollContentBackground(.hidden)
        .background(Color.srBackground)
        .sheet(isPresented: $page.showsConfirm) {
            DietConfirmSheet(model: model, page: page)
        }
    }

    // MARK: - 记餐卡（自然语言输入）

    private var entryCard: some View {
        SRCard(elevation: .raised) {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                Text("记一餐").srFont(.lg, .semibold)
                TextEditor(text: $page.rawText)
                    .srFont(.base)
                    .padding(SRSpacing.sm)
                    .background(Color.srSurface)
                    .clipShape(RoundedRectangle(cornerRadius: SRRadius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: SRRadius.md, style: .continuous)
                            .stroke(Color.srBorderStrong, lineWidth: 1)
                    )
                    .frame(minHeight: 88)
                    .scrollContentBackground(.hidden)
                Text("例：2 个鸡蛋、一杯无糖希腊酸奶、米饭 300g；「二两白酒」= 100g。顿号逗号分号加号换行都可以分隔。")
                    .srFont(.xs)
                    .foregroundStyle(Color.srForegroundSubtle)
                SRButton("解析这一餐", icon: "wand.and.stars", style: .primary) {
                    page.beginParse(customFoods: model.customFoods,
                                    calendar: model.recordsCalendar,
                                    workouts: model.workouts,
                                    entries: model.dietEntries,
                                    now: Date())
                }
                .disabled(page.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - 日/周/月总结

    private var summarySection: some View {
        VStack(spacing: SRSpacing.md) {
            SRSegmented(options: DietRangeTab.allCases, selection: $page.range) { $0.label }
            switch page.range {
            case .day: daySummaryCard
            case .week: periodSummaryCard(days: 7)
            case .month: periodSummaryCard(days: 30)
            }
        }
    }

    private var daySummaryCard: some View {
        let summary = DietEngine.dailySummary(model.dietEntries,
                                              day: model.recordsToday(),
                                              workouts: model.workouts,
                                              bodyweightKg: model.settings.bodyweightKg,
                                              calendar: model.recordsCalendar,
                                              now: Date())
        let t = summary.totals.totals
        let empty = summary.totals.itemCount == 0 && t.kcal == 0
            && summary.totals.unmatchedCount == 0
        return SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                Text("今日宏量").srFont(.lg, .semibold)
                if empty {
                    srRecordsEmptyHint(DietEngine.noEntryDayAdvice)
                } else {
                    macroBar("热量", current: t.kcal,
                             target: Double(summary.targets.kcal), unit: "kcal")
                    macroBar("蛋白质", current: t.proteinG,
                             target: Double(summary.targets.proteinTarget), unit: "g")
                    macroBar("碳水", current: t.carbsG,
                             target: Double(summary.targets.carbsG), unit: "g")
                    macroBar("脂肪", current: t.fatG,
                             target: Double(summary.targets.fatG), unit: "g")
                    Text("蛋白目标区间 \(summary.targets.proteinLo)–\(summary.targets.proteinHi) g"
                         + (summary.targets.trainedToday ? " · 今天练过，按训练日取上限" : ""))
                        .srFont(.xs)
                        .foregroundStyle(Color.srForegroundSubtle)
                }
                adviceList(summary.advice)
            }
        }
    }

    private func periodSummaryCard(days: Int) -> some View {
        let period = DietEngine.periodDiet(model.dietEntries,
                                           workouts: model.workouts,
                                           in: model.recordsRecentSpan(days: days),
                                           bodyweightKg: model.settings.bodyweightKg,
                                           calendar: model.recordsCalendar)
        let columns = [GridItem(.flexible(), spacing: SRSpacing.md),
                       GridItem(.flexible(), spacing: SRSpacing.md)]
        return SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                Text(days == 7 ? "近 7 天" : "近 30 天").srFont(.lg, .semibold)
                if period.daysTracked == 0 {
                    srRecordsEmptyHint(DietEngine.noRecordPeriodAdvice)
                } else {
                    LazyVGrid(columns: columns, spacing: SRSpacing.md) {
                        SRStatCard(label: "记录天数", value: "\(period.daysTracked)")
                        SRStatCard(label: "蛋白达标",
                                   value: "\(period.proteinHitDays)/\(period.daysTracked) 天")
                        SRStatCard(label: "日均热量", value: Formatting.kcal(period.avg.kcal))
                        SRStatCard(label: "日均蛋白", value: Formatting.grams(period.avg.proteinG))
                    }
                    if let rate = period.trainingLink.trainingDayHitRate {
                        Text("训练日蛋白达标率 \(Int((rate * 100).rounded()))%——饮食是否在支撑训练的主指标。")
                            .srFont(.xs)
                            .foregroundStyle(Color.srForegroundSubtle)
                    }
                    if !period.topFoods.isEmpty {
                        VStack(alignment: .leading, spacing: SRSpacing.xs) {
                            RecordsSectionLabel("常吃 Top5")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: SRSpacing.sm)],
                                      spacing: SRSpacing.sm) {
                                ForEach(period.topFoods) { food in
                                    SRBadge("\(food.name) ×\(food.count)")
                                }
                            }
                        }
                    }
                    adviceList(period.advice)
                }
            }
        }
    }

    private func macroBar(_ label: String, current: Double, target: Double, unit: String) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            HStack {
                Text(label).srFont(.sm, .medium)
                Spacer()
                Text("\(Int(current.rounded())) / \(Int(target.rounded())) \(unit)")
                    .srFont(.sm)
                    .monospacedDigit()
                    .foregroundStyle(Color.srForegroundMuted)
            }
            SRProgressBar(progress: target > 0 ? current / target : 0)
        }
    }

    private func adviceList(_ advice: [String]) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            RecordsSectionLabel(page.range == .day ? "今日建议" : "阶段建议")
            ForEach(Array(advice.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: SRSpacing.sm) {
                    Image(systemName: "lightbulb")
                        .font(.sr(.xs))
                        .foregroundStyle(Color.srForegroundSubtle)
                        .padding(.top, 2)
                    Text(line)
                        .srFont(.sm)
                        .foregroundStyle(Color.srForeground)
                }
            }
        }
    }

    // MARK: - 今日记录列表

    private var todayEntries: [DietEntry] {
        DietEngine.entriesOfDay(model.dietEntries,
                                day: model.recordsToday(),
                                calendar: model.recordsCalendar)
    }

    private func entryRow(_ entry: DietEntry) -> some View {
        SRCard(padding: SRSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SRSpacing.sm) {
                    SRBadge(entry.meal.label)
                    Text(RecordsFmt.hm(entry.date, calendar: model.recordsCalendar))
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                    Spacer()
                    Text(Formatting.kcal(entry.totals.kcal))
                        .srFont(.sm, .medium)
                        .monospacedDigit()
                }
                Text(entry.rawText)
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
                    .lineLimit(2)
                if let cost = entry.costYuan, cost > 0 {
                    Text("花费 \(Formatting.yuan(cost))，已自动入账预算")
                        .srFont(.xs)
                        .foregroundStyle(Color.srForegroundSubtle)
                }
            }
        }
    }
}

// MARK: - 解析确认卡 sheet（三层标记 + 餐次 + 花费）

struct DietConfirmSheet: View {

    @ObservedObject var model: AppModel
    @ObservedObject var page: DietRecordsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SRSpacing.lg) {
                Text("确认这一餐").srFont(.lg, .semibold)
                Text(page.draftRawText)
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)

                // 层①：库命中（含 tags）
                RecordsSectionLabel("库命中 \(page.parsedItems.count) 项")
                if page.parsedItems.isEmpty {
                    srRecordsEmptyHint("这一餐没有命中食物库的项。")
                } else {
                    ForEach(page.parsedItems) { item in
                        matchRow(item)
                    }
                }

                // 层②：手估（类别均值预填，可改克数、可整项不计入）
                RecordsSectionLabel("手估 \(page.countedRows.count) 项（按类别均值预填）")
                if page.countedRows.isEmpty {
                    srRecordsEmptyHint("没有估算中的项。")
                } else {
                    ForEach(page.countedRows) { row in
                        manualRow(row)
                    }
                }

                // 层③：未识别（不计入）
                RecordsSectionLabel("未识别 \(page.excludedRows.count) 项（不计入热量）")
                if page.excludedRows.isEmpty {
                    srRecordsEmptyHint("没有未识别的项。")
                } else {
                    ForEach(page.excludedRows) { row in
                        HStack(spacing: SRSpacing.md) {
                            Text(row.name).srFont(.base)
                            Spacer()
                            SRButton("按手估计入", style: .ghost, size: .sm) {
                                page.recallRow(id: row.id)
                            }
                        }
                    }
                }

                // 餐次（guessMeal 自动预选）
                RecordsSectionLabel("餐次（已按时段与训练自动预选）")
                SRSegmented(options: DietRecordsModel.mealOptionKeys.map { SRSimpleOption(id: $0) },
                            selection: mealBinding,
                            size: .sm) { DietEngine.mealLabel(forRawKey: $0.id) }

                // 花费（联动预算）
                RecordsSectionLabel("花费（可选，保存后自动入账预算）")
                SRField(text: $page.costText, placeholder: "如 25.5",
                        icon: "yensign.circle", keyboard: .decimal)

                Text(estimatedFooter)
                    .srFont(.sm, .medium)
                    .monospacedDigit()
                    .foregroundStyle(Color.srForeground)

                HStack {
                    Spacer()
                    SRButton("取消", style: .ghost) { page.closeConfirm() }
                    SRButton("保存这一餐", style: .primary, action: save)
                }
            }
            .padding(SRSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.srBackground)
        .presentationDetents([.large])
        .interactiveDismissDisabled(true)
    }

    /// 预计合计（引擎 entryTotals：命中 + 未排除手估）。
    private var estimatedFooter: String {
        let totals = DietEngine.entryTotals(parsed: page.parsedTotals,
                                            manualItems: page.countedManualItems)
        return "预计合计 \(Formatting.kcal(totals.kcal)) · 蛋白 \(Formatting.grams(totals.proteinG))"
            + " · 碳水 \(Formatting.grams(totals.carbsG)) · 脂肪 \(Formatting.grams(totals.fatG))"
    }

    private var mealBinding: Binding<SRSimpleOption> {
        Binding(
            get: { SRSimpleOption(id: page.mealRaw) },
            set: { page.mealRaw = $0.id }
        )
    }

    private func matchRow(_ item: FoodMatch) -> some View {
        HStack(spacing: SRSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.name) · \(Int(item.grams.rounded())) g")
                    .srFont(.base, .medium)
                Text(Formatting.kcal(item.macros.kcal) + " · 蛋白 " + Formatting.grams(item.macros.proteinG))
                    .srFont(.xs)
                    .foregroundStyle(Color.srForegroundSubtle)
                HStack(spacing: SRSpacing.xs) {
                    ForEach(item.tags, id: \.self) { tag in
                        SRBadge(RecordsFmt.foodTagLabel(tag))
                    }
                }
            }
            Spacer()
        }
    }

    private func manualRow(_ row: DietManualRow) -> some View {
        HStack(spacing: SRSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).srFont(.base, .medium)
                Text("按「\(row.categoryLabel)」估")
                    .srFont(.xs)
                    .foregroundStyle(Color.srForegroundSubtle)
            }
            Spacer()
            SRField(text: gramsBinding(row),
                    placeholder: "克数",
                    keyboard: .decimal,
                    size: .sm,
                    showsClearButton: false)
                .frame(width: 110)
            Text("g")
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)
            SRSwitch(isOn: countedBinding(row), label: "计入")
        }
    }

    private func gramsBinding(_ row: DietManualRow) -> Binding<String> {
        Binding(
            get: { page.rows.first { $0.id == row.id }?.gramsText ?? "" },
            set: { newValue in
                guard let index = page.rows.firstIndex(where: { $0.id == row.id }) else { return }
                page.rows[index].gramsText = newValue
            }
        )
    }

    private func countedBinding(_ row: DietManualRow) -> Binding<Bool> {
        Binding(
            get: { page.rows.first { $0.id == row.id }?.isCounted ?? false },
            set: { newValue in
                guard let index = page.rows.firstIndex(where: { $0.id == row.id }) else { return }
                page.rows[index].isCounted = newValue
            }
        )
    }

    private func save() {
        let saved = model.saveDietEntry(date: Date(),
                                        meal: page.meal,
                                        rawText: page.draftRawText,
                                        parsedTotals: page.parsedTotals,
                                        items: page.parsedItems,
                                        manualItems: page.countedManualItems,
                                        unmatched: page.excludedNames,
                                        costYuan: Double(page.costText))
        if saved != nil {
            page.resetAfterSave()
        }
    }
}
