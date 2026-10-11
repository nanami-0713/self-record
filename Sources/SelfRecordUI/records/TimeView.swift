import Charts
import SelfRecordCore
import SwiftUI

// MARK: - TimeView（design.md §6「记录 · TimeView」）
//
// 单槽计时器大按钮（日常/睡眠互斥，占用中禁用另一个并引导）+ 24h 时间轴
// （Timeline24View：分类段 + 睡眠叠加深色 + 当前时刻线）+ 区间三档
// （今日 = 分类占比环形图 + 当日块列表；近 7/30 = 逐日堆叠柱）；
// 块列表支持补记（sheet 表单）、编辑、滑删（macOS 下以 contextMenu 兜底）。
//
// 数据一律来自 TimeEngine（§2.1 聚合 API + 模块自有 API）；视图层零业务逻辑。

/// 区间三档（lifttime time.js:31-36 的三段切换）。
enum TimeRangeTab: String, CaseIterable, Identifiable {
    case today, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "今日"
        case .week: return "近 7 天"
        case .month: return "近 30 天"
        }
    }
}

/// 补记 / 编辑共用草稿。
struct TimeBlockDraft {
    var blockID: UUID?               // nil = 补记
    var start: Date
    var end: Date
    var categoryID: String
    var note: String

    var isValid: Bool { end > start }   // 引擎 makeBlock 同口径二次把关
}

/// TimeView 页面态（SwiftUI 宏禁令 §8 约定 5：ObservableObject 路径）。
/// 非 @MainActor：仅由主线程 View 持有与驱动。
final class TimeRecordsModel: ObservableObject {

    @Published var range: TimeRangeTab = .today
    @Published var showsStopSheet = false
    @Published var showsDiscardDialog = false
    @Published var showsEditor = false
    @Published var draft = TimeBlockDraft(blockID: nil, start: Date(), end: Date(),
                                          categoryID: "other", note: "")
    @Published var stopCategoryID = "other"
    @Published var stopNote = ""

    func openStopSheet(defaultCategoryID: String) {
        stopCategoryID = defaultCategoryID
        stopNote = ""
        showsStopSheet = true
    }

    func openEditorNew(now: Date, defaultCategoryID: String) {
        draft = TimeBlockDraft(blockID: nil,
                               start: now.addingTimeInterval(-3600),
                               end: now,
                               categoryID: defaultCategoryID,
                               note: "")
        showsEditor = true
    }

    func openEditorEdit(_ block: TimeBlock) {
        draft = TimeBlockDraft(blockID: block.id,
                               start: block.start,
                               end: block.end,
                               categoryID: block.categoryID,
                               note: block.note ?? "")
        showsEditor = true
    }
}

/// 今日占比图数据行（Charts 需 Identifiable）。
struct TimeShareRow: Identifiable {
    let id: String                   // categoryID
    let label: String
    let minutes: Double
    let hue: ChartHue
}

/// 近 7/30 堆叠柱数据行。
struct TimeStackRow: Identifiable {
    let id: String                   // day-categoryID
    let dayLabel: String
    let categoryID: String
    let label: String
    let minutes: Double
    let hue: ChartHue
}

struct TimeView: View {

    @ObservedObject var model: AppModel
    @StateObject private var page = TimeRecordsModel()
    @Environment(\.colorScheme) private var scheme

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        List {
            Section {
                timerCard
                    .srRecordsRow()
            }
            Section {
                timelineCard
                    .srRecordsRow()
            }
            Section {
                rangeCard
                    .srRecordsRow()
            }
            blockSections
        }
        .listStyle(.plain)
        .listSectionSeparator(.hidden)
        .scrollContentBackground(.hidden)
        .background(Color.srBackground)
        .sheet(isPresented: $page.showsStopSheet) {
            TimeStopSheet(model: model, page: page)
        }
        .sheet(isPresented: $page.showsEditor) {
            TimeBlockEditorSheet(model: model, page: page)
        }
    }

    // MARK: - 单槽计时器卡

    /// 计时文本之外全是静态结构：TimelineView 只收敛包时长文本
    /// （原先包整卡——无进行中计时也每 30s 重建全卡，对齐 TodayActiveStrip 的做法）。
    private var timerCard: some View {
        timerCardContent
    }

    @ViewBuilder
    private var timerCardContent: some View {
        SRCard(elevation: .raised) {
            if let timer = model.activeTimer {
                VStack(alignment: .leading, spacing: SRSpacing.md) {
                    HStack {
                        SRBadge(timer.kind == .sleep ? "睡眠计时中" : "日常计时中")
                        Spacer()
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Formatting.duration(minutes: context.date.timeIntervalSince(timer.startedAt) / 60))
                            .srFont(.xxl, .semibold)
                            .monospacedDigit()
                    }
                    Text("自 \(RecordsFmt.hm(timer.startedAt, calendar: model.recordsCalendar)) 开始")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                    if timer.kind == .general {
                        HStack(spacing: SRSpacing.sm) {
                            SRButton("结束并保存", icon: "stop.fill", style: .primary) {
                                page.openStopSheet(defaultCategoryID: model.recordsDefaultCategoryID)
                            }
                            SRButton("丢弃", style: .ghost) { page.showsDiscardDialog = true }
                        }
                    } else {
                        // 互斥引导（lifttime time.js:86「睡完再记这段时间」）
                        Text("单槽被睡眠占用：到「睡眠」页起床并完成问卷，再记录日常时间。")
                            .srFont(.sm)
                            .foregroundStyle(Color.srForegroundMuted)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: SRSpacing.md) {
                    Text("单槽计时器").srFont(.lg, .semibold)
                    Text("日常与睡眠共用一个计时槽：开始、结束各一击，结束后选分类保存。")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                    SRButton("开始计时", icon: "play.fill", style: .primary) {
                        _ = model.startGeneralTimer(now: Date())
                    }
                }
            }
        }
        .confirmationDialog("丢弃这段计时？丢弃后不会生成时间块。",
                            isPresented: $page.showsDiscardDialog, titleVisibility: .visible) {
            Button("丢弃", role: .destructive) { model.discardActiveTimer() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 24h 时间轴卡（Canvas 自定义组件，§7.4）

    private var timelineCard: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            SRCard {
                VStack(alignment: .leading, spacing: SRSpacing.md) {
                    Text("24 小时时间轴").srFont(.lg, .semibold)
                    Timeline24View(
                        segments: timelineSegments(now: now),
                        nowMinutes: Double(model.recordsCalendar.minutesSinceMidnight(of: now)),
                        accessibilitySummary: "今日 24 小时时间轴，深色段为睡眠"
                    )
                    Text("彩色段 = 分类（今日 0 点起，跨午夜段按今日部分绘制）；深色段 = 睡眠；竖线 = 当前时刻。")
                        .srFont(.xs)
                        .foregroundStyle(Color.srForegroundSubtle)
                }
            }
        }
    }

    /// 今日时间轴段：分类块（ChartHue）+ 睡眠会话（叠加）+ 进行中计时。
    private func timelineSegments(now: Date) -> [SRTimeSegment] {
        let calendar = model.recordsCalendar
        let dayStart = calendar.date(of: model.recordsToday()) ?? now
        let dayEnd = dayStart.addingTimeInterval(86400)
        func minute(_ date: Date) -> Double { date.timeIntervalSince(dayStart) / 60 }

        var segments: [SRTimeSegment] = []
        for block in model.timeBlocks where block.start < dayEnd && block.end > dayStart {
            let hue = TimeEngine.resolveCategory(block.categoryID, in: model.categories)?.hue ?? .neutral
            segments.append(SRTimeSegment(id: block.id,
                                          start: minute(block.start),
                                          end: minute(Swift.min(block.end, dayEnd)),
                                          fill: .hue(hue)))
        }
        for session in model.sleepSessions where session.start < dayEnd && session.end > dayStart {
            segments.append(SRTimeSegment(id: session.id,
                                          start: minute(session.start),
                                          end: minute(Swift.min(session.end, dayEnd)),
                                          fill: .sleep))
        }
        if let timer = model.activeTimer, timer.startedAt < now {
            // 进行中：睡眠用叠加色；日常尚未选分类，用 neutral（最终归属由保存时的分类决定）
            segments.append(SRTimeSegment(id: UUID(),
                                          start: minute(Swift.max(timer.startedAt, dayStart)),
                                          end: minute(Swift.min(now, dayEnd)),
                                          fill: timer.kind == .sleep ? .sleep : .hue(.neutral)))
        }
        return segments
    }

    // MARK: - 区间三档

    private var rangeCard: some View {
        VStack(spacing: SRSpacing.md) {
            SRSegmented(options: TimeRangeTab.allCases, selection: $page.range) { $0.label }
            switch page.range {
            case .today: todayShareCard
            case .week: periodCard(days: 7)
            case .month: periodCard(days: 30)
            }
        }
    }

    private var todayShareCard: some View {
        let brief = TimeEngine.dayBrief(model.timeBlocks,
                                        day: model.recordsToday(),
                                        categories: model.categories,
                                        calendar: model.recordsCalendar)
        let rows: [TimeShareRow] = brief.topCategories.map { share in
            TimeShareRow(id: share.categoryID,
                         label: share.label,
                         minutes: share.minutes,
                         hue: model.categories.first { $0.id == share.categoryID }?.hue ?? .neutral)
        }
        return SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                Text("今日分类占比").srFont(.lg, .semibold)
                if rows.isEmpty {
                    srRecordsEmptyHint("今天还没有时间记录——开始计时或补记一段。")
                } else {
                    shareChart(rows: rows, total: brief.totalMinutes)
                    shareLegend(rows: rows, total: brief.totalMinutes)
                }
            }
        }
    }

    /// 环形图（SectorMark，macOS 15 / iOS 18 起）；更早系统降级为横向条
    /// （Swift Charts，同一数据口径）。
    @ViewBuilder
    private func shareChart(rows: [TimeShareRow], total: Double) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            ZStack {
                Chart(rows) { row in
                    SectorMark(angle: .value("分钟", row.minutes),
                               innerRadius: .ratio(0.62),
                               angularInset: 1)
                        .foregroundStyle(SRChartPalette.hue(row.hue, scheme))
                        .cornerRadius(2)
                }
                VStack(spacing: 2) {
                    Text("总计").srFont(.xs).foregroundStyle(Color.srForegroundMuted)
                    Text(Formatting.duration(minutes: total))
                        .srFont(.md, .semibold)
                        .monospacedDigit()
                }
            }
            .frame(height: 190)
        } else {
            SRChartContainer(height: CGFloat(40 * rows.count + 28)) {
                Chart(rows) { row in
                    BarMark(x: .value("分钟", row.minutes),
                            y: .value("分类", row.label))
                        .foregroundStyle(SRChartPalette.hue(row.hue, scheme))
                        .cornerRadius(2)
                }
                .srYAxisGrid()
                .srRecordsXAxis()
            }
        }
    }

    private func shareLegend(rows: [TimeShareRow], total: Double) -> some View {
        VStack(spacing: SRSpacing.xs) {
            ForEach(rows) { row in
                HStack(spacing: SRSpacing.sm) {
                    SRDotBadge(SRChartPalette.hue(row.hue, scheme))
                    Text(row.label).srFont(.base)
                    Spacer()
                    Text("\(Int(row.minutes.rounded())) 分 · \(Int((row.minutes / max(total, 1) * 100).rounded()))%")
                        .srFont(.sm)
                        .monospacedDigit()
                        .foregroundStyle(Color.srForegroundMuted)
                }
            }
        }
    }

    private func periodCard(days: Int) -> some View {
        let calendar = model.recordsCalendar
        let span = model.recordsRecentSpan(days: days)
        let breakdown = TimeEngine.dailyBreakdown(model.timeBlocks, in: span,
                                                  categories: model.categories,
                                                  calendar: calendar)
        let dayKeys = breakdown.keys.sorted { $0.rawValue < $1.rawValue }
        let activeCategories = model.categories.filter { !$0.isArchived }
        var rows: [TimeStackRow] = []
        var presentIDs: [String] = []
        for day in dayKeys {
            let perDay = breakdown[day] ?? [:]
            for category in activeCategories {
                let minutes = perDay[category.id] ?? 0
                guard minutes > 0 else { continue }
                rows.append(TimeStackRow(id: "\(day.rawValue)-\(category.id)",
                                         dayLabel: RecordsFmt.dayLabel(day),
                                         categoryID: category.id,
                                         label: category.label,
                                         minutes: minutes,
                                         hue: category.hue))
                if !presentIDs.contains(category.id) { presentIDs.append(category.id) }
            }
        }
        let totalMinutes = rows.reduce(0) { $0 + $1.minutes }
        let legendCategories = activeCategories.filter { presentIDs.contains($0.id) }

        return SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                HStack {
                    Text("逐日堆叠（\(days) 天）").srFont(.lg, .semibold)
                    Spacer()
                    Text("共 \(Formatting.duration(minutes: totalMinutes))")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                }
                if rows.isEmpty {
                    srRecordsEmptyHint("区间内还没有时间记录。")
                } else {
                    SRChartContainer(height: 220) {
                        Chart(rows) { row in
                            BarMark(x: .value("日期", row.dayLabel),
                                    y: .value("分钟", row.minutes))
                                .foregroundStyle(SRChartPalette.hue(row.hue, scheme))
                                .cornerRadius(2)
                        }
                        .srYAxisGrid()
                        .srRecordsXAxis()
                    }
                    VStack(spacing: SRSpacing.xs) {
                        ForEach(legendCategories) { category in
                            HStack(spacing: SRSpacing.sm) {
                                SRDotBadge(SRChartPalette.hue(category.hue, scheme))
                                Text(category.label).srFont(.base)
                                Spacer()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 今日块列表（补记 / 编辑 / 滑删）

    /// 今日块（归属口径 = start 所在日，与 TimeEngine.dayBrief 一致）。
    private var todayBlocks: [TimeBlock] {
        let calendar = model.recordsCalendar
        let today = model.recordsToday()
        return model.timeBlocks
            .filter { calendar.dayKey(for: $0.start) == today }
            .sorted { $0.start < $1.start }
    }

    @ViewBuilder
    private var blockSections: some View {
        if page.range == .today {
            Section {
                HStack {
                    Text("今日记录").srFont(.lg, .semibold)
                    Spacer()
                    SRButton("补记", icon: "plus", style: .secondary, size: .sm) {
                        page.openEditorNew(now: Date(), defaultCategoryID: model.recordsDefaultCategoryID)
                    }
                }
                .srRecordsRow()
                ForEach(todayBlocks) { block in
                    blockRow(block)
                        .srRecordsRow()
                        .contentShape(Rectangle())
                        .onTapGesture { page.openEditorEdit(block) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                model.deleteTimeBlock(id: block.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                page.openEditorEdit(block)
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                        }
                        .contextMenu {
                            Button {
                                page.openEditorEdit(block)
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                model.deleteTimeBlock(id: block.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        }
    }

    private func blockRow(_ block: TimeBlock) -> some View {
        let calendar = model.recordsCalendar
        let category = TimeEngine.resolveCategory(block.categoryID, in: model.categories)
        return SRCard(padding: SRSpacing.md) {
            HStack(spacing: SRSpacing.md) {
                SRDotBadge(SRChartPalette.hue(category?.hue ?? .neutral, scheme))
                VStack(alignment: .leading, spacing: 2) {
                    Text(category?.label ?? "未知分类").srFont(.base, .medium)
                    Text("\(RecordsFmt.hm(block.start, calendar: calendar)) – "
                         + "\(RecordsFmt.hm(block.end, calendar: calendar)) · "
                         + Formatting.duration(minutes: block.end.timeIntervalSince(block.start) / 60))
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                    if let note = block.note {
                        Text(note)
                            .srFont(.sm)
                            .foregroundStyle(Color.srForegroundSubtle)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
        }
    }
}

// MARK: - 结束计时 sheet（选分类保存 / 丢弃）

struct TimeStopSheet: View {

    @ObservedObject var model: AppModel
    @ObservedObject var page: TimeRecordsModel

    var body: some View {
        VStack(alignment: .leading, spacing: SRSpacing.lg) {
            if let timer = model.activeTimer, timer.kind == .general {
                Text("结束计时").srFont(.lg, .semibold)
                Text("已进行 \(Formatting.duration(minutes: Date().timeIntervalSince(timer.startedAt) / 60))（自 "
                     + RecordsFmt.hm(timer.startedAt, calendar: model.recordsCalendar) + " 开始）")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)

                HStack {
                    Text("分类").srFont(.base)
                    Spacer()
                    Picker("分类", selection: $page.stopCategoryID) {
                        ForEach(model.categories.filter { !$0.isArchived }) { category in
                            Text(category.label).tag(category.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                SRField(text: $page.stopNote, placeholder: "备注（可选）")

                HStack {
                    SRButton("丢弃", style: .ghost) { page.showsDiscardDialog = true }
                    Spacer()
                    SRButton("取消", style: .ghost) { page.showsStopSheet = false }
                    SRButton("保存", style: .primary) {
                        if model.stopGeneralTimer(categoryID: page.stopCategoryID,
                                                  note: page.stopNote, now: Date()) {
                            page.showsStopSheet = false
                        }
                    }
                }
            } else {
                Text("没有进行中的日常计时").srFont(.lg, .semibold)
            }
        }
        .padding(SRSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(true)
        .confirmationDialog("丢弃这段计时？丢弃后不会生成时间块。",
                            isPresented: $page.showsDiscardDialog, titleVisibility: .visible) {
            Button("丢弃", role: .destructive) {
                model.discardActiveTimer()
                page.showsStopSheet = false
            }
            Button("取消", role: .cancel) {}
        }
    }
}

// MARK: - 补记 / 编辑 sheet

struct TimeBlockEditorSheet: View {

    @ObservedObject var model: AppModel
    @ObservedObject var page: TimeRecordsModel

    var body: some View {
        VStack(alignment: .leading, spacing: SRSpacing.lg) {
            Text(page.draft.blockID == nil ? "补记时间段" : "编辑时间段")
                .srFont(.lg, .semibold)

            DatePicker("开始", selection: $page.draft.start)
            DatePicker("结束", selection: $page.draft.end, in: page.draft.start...)

            HStack {
                Text("分类").srFont(.base)
                Spacer()
                Picker("分类", selection: $page.draft.categoryID) {
                    ForEach(model.categories.filter { !$0.isArchived }) { category in
                        Text(category.label).tag(category.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            SRField(text: $page.draft.note, placeholder: "备注（可选）")

            if !page.draft.isValid {
                Text("结束时间要晚于开始时间")
                    .srFont(.sm)
                    .foregroundStyle(Color.srDanger)
            }

            HStack {
                Spacer()
                SRButton("取消", style: .ghost) { page.showsEditor = false }
                SRButton("保存", style: .primary, action: save)
                    .disabled(!page.draft.isValid)
            }
        }
        .padding(SRSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(true)
    }

    private func save() {
        let draft = page.draft
        if let id = draft.blockID {
            _ = model.updateTimeBlock(id: id, start: draft.start, end: draft.end,
                                      categoryID: draft.categoryID, note: draft.note)
        } else {
            _ = model.addTimeBlock(start: draft.start, end: draft.end,
                                   categoryID: draft.categoryID, note: draft.note)
        }
        page.showsEditor = false
    }
}
