import Charts
import SelfRecordCore
import SwiftUI

// MARK: - SleepView（design.md §6「记录 · SleepView」）
//
// 两击上床/起床（与日常计时互斥）+ 起床问卷 sheet（三题可整页跳过——跳过不惩罚）；
// 手动补记睡眠（忘了两击时「＋ 补记睡眠」；与编辑共用一个 sheet，参考 lifttime
// sleep.js:97/:171-279 sessionSheet——Core 侧 = SleepEngine.makeSession/entryError/
// entryPreview，补录会话与两击会话同形同口径）；近 7 天时长条形 + 逐夜分数折线
// ——分数与均值**一律出自 SleepEngine.periodSummary**（区间中位锚，缺省 330；
// design.md §3.2 A3 口径，杜绝锚漂移）；列表项点开调整归属 dayOverride（含
// 「恢复自动」）、滑动/长按编辑与删除；睡眠债与规律性摘要卡。
//
// 数据一律来自 SleepEngine；视图层零业务逻辑。

/// 待完成的起床（问卷 sheet 的载体）。
struct PendingWake: Identifiable {
    let id = UUID()
    let startedAt: Date
    let wokeAt: Date

    var durationMinutes: Double { wokeAt.timeIntervalSince(startedAt) / 60 }
}

/// 补记 / 编辑共用草稿（lifttime sleep.js:172 sessionSheet：补记与编辑同一个 sheet，
/// 编辑模式预填既有值）。
struct SleepEntryDraft {
    /// nil = 补记新会话；非 nil = 编辑该会话
    var sessionID: UUID?
    /// 编辑时保留的原手动归属（时间改动不影响归属；补记 = nil 走自动规则）
    var dayOverride: DayKey?
    var bed = Date()
    var wake = Date()
    var feelText = "未填"
    var wakesText = "未填"
    var latencyText = "未填"

    var isEditing: Bool { sessionID != nil }
    var feel: Int? { SleepRecordsModel.feelValue(feelText) }
    var wakeCount: Int? { SleepRecordsModel.wakesValue(wakesText) }
    var latency: SleepLatency? { SleepRecordsModel.latencyValue(latencyText) }
}

/// SleepView 页面态（SwiftUI 宏禁令 §8 约定 5：ObservableObject 路径）。
final class SleepRecordsModel: ObservableObject {

    @Published var pending: PendingWake?
    @Published var feelText = "未填"
    @Published var wakesText = "未填"
    @Published var latencyText = "未填"
    @Published var overrideSession: SleepSession?
    @Published var overrideDate = Date()
    @Published var showsEditor = false
    @Published var showsEditorDeleteDialog = false
    @Published var editorDraft = SleepEntryDraft()

    /// 问卷选项（首项 = 未填 = 跳过；feel 1–5 / wakes 0–3 / latency 三档，§3.2）。
    static let feelOptions = ["未填", "1", "2", "3", "4", "5"]
    static let wakesOptions = ["未填", "0", "1", "2", "3"]
    static let latencyOptions = ["未填", "快", "还好", "慢"]

    /// 问卷选项串 → 值（SleepWakeSheet 与 SleepEntrySheet 共用；「未填」→ nil）。
    static func feelValue(_ text: String) -> Int? { Int(text) }   // Int("未填") = nil
    static func wakesValue(_ text: String) -> Int? { text == "未填" ? nil : Int(text) }
    static func latencyValue(_ text: String) -> SleepLatency? {
        switch text {
        case "快": return .fast
        case "还好": return .ok
        case "慢": return .slow
        default: return nil
        }
    }

    var feel: Int? { Self.feelValue(feelText) }
    var wakeCount: Int? { Self.wakesValue(wakesText) }
    var latency: SleepLatency? { Self.latencyValue(latencyText) }

    func beginWake(_ timer: ActiveTimer, now: Date) {
        pending = PendingWake(startedAt: timer.startedAt, wokeAt: now)
        feelText = "未填"
        wakesText = "未填"
        latencyText = "未填"
    }

    /// 打开补记 sheet：默认「昨晚 23:00 → 今早 07:00」（lifttime sleep.js:178-179
    /// 的 23:00/07:00 默认值同思路），用户可任意改。
    func openEditorNew(now: Date, calendar: DayCalendar) {
        let todayStart = calendar.date(of: calendar.dayKey(for: now)) ?? now
        editorDraft = SleepEntryDraft(
            sessionID: nil,
            dayOverride: nil,
            bed: todayStart.addingTimeInterval(-3600),        // 昨晚 23:00
            wake: todayStart.addingTimeInterval(7 * 3600)    // 今早 07:00
        )
        showsEditor = true
    }

    /// 打开编辑 sheet：预填既有时间 / 问卷字段 / 手动归属（sleep.js:172-205）。
    func openEditorEdit(_ session: SleepSession) {
        editorDraft = SleepEntryDraft(
            sessionID: session.id,
            dayOverride: session.dayOverride,
            bed: session.start,
            wake: session.end,
            feelText: session.feel.map(String.init) ?? "未填",
            wakesText: session.wakeCount.map(String.init) ?? "未填",
            latencyText: {
                switch session.latency {
                case .fast: return "快"
                case .ok: return "还好"
                case .slow: return "慢"
                case nil: return "未填"
                }
            }()
        )
        showsEditor = true
    }
}

/// 趋势图数据行。
struct SleepTrendRow: Identifiable {
    let id: String
    let label: String
    let value: Double
}

struct SleepView: View {

    @ObservedObject var model: AppModel
    @StateObject private var page = SleepRecordsModel()
    @Environment(\.colorScheme) private var scheme

    init(model: AppModel) {
        self.model = model
    }

    var body: some View {
        List {
            Section {
                bedCard
                    .srRecordsRow()
                // 补记入口（lifttime sleep.js:97「＋ 补记昨晚 / 午睡」同位语义：
                // 两击卡之下、随手可及的 ghost 小按钮）
                HStack {
                    SRButton("补记睡眠", icon: "plus", style: .ghost, size: .sm) {
                        page.openEditorNew(now: Date(), calendar: model.recordsCalendar)
                    }
                    Spacer()
                }
                .srRecordsRow()
            }
            Section {
                trendCard
                    .srRecordsRow()
            }
            Section {
                summaryGrid
                    .srRecordsRow()
            }
            Section {
                Text("最近会话").srFont(.lg, .semibold)
                    .srRecordsRow()
                ForEach(recentSessions) { session in
                    sessionRow(session)
                        .srRecordsRow()
                        .contentShape(Rectangle())
                        .onTapGesture { openOverride(session) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                model.deleteSleepSession(id: session.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            Button {
                                page.openEditorEdit(session)
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                        }
                        .contextMenu {
                            Button {
                                page.openEditorEdit(session)
                            } label: {
                                Label("编辑睡眠", systemImage: "pencil")
                            }
                            Button {
                                openOverride(session)
                            } label: {
                                Label("调整归属", systemImage: "calendar")
                            }
                            Button(role: .destructive) {
                                model.deleteSleepSession(id: session.id)
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
        .sheet(item: $page.pending) { _ in
            SleepWakeSheet(model: model, page: page)
        }
        .sheet(item: $page.overrideSession) { _ in
            SleepOverrideSheet(model: model, page: page)
        }
        .sheet(isPresented: $page.showsEditor) {
            SleepEntrySheet(model: model, page: page)
        }
    }

    // MARK: - 两击上床/起床卡

    private var bedCard: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            bedCardContent(now: context.date)
        }
    }

    @ViewBuilder
    private func bedCardContent(now: Date) -> some View {
        SRCard(elevation: .raised) {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                if let timer = model.activeTimer, timer.kind == .sleep {
                    SRBadge("入睡中")
                    Text(Formatting.duration(minutes: now.timeIntervalSince(timer.startedAt) / 60))
                        .srFont(.xxl, .semibold)
                        .monospacedDigit()
                    Text("自 \(RecordsFmt.hm(timer.startedAt, calendar: model.recordsCalendar)) 上床")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                    SRButton("起床", icon: "alarm", style: .primary) {
                        page.beginWake(timer, now: Date())
                    }
                } else if model.activeTimer != nil {
                    // 单槽互斥：日常计时占用 → 禁用上床并引导（sleep.js:107 语义）
                    Text("两击上床").srFont(.lg, .semibold)
                    Text("日常计时进行中——先到「时间」页结束它，再上床记录睡眠（单槽互斥）。")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                    SRButton("上床", icon: "moon.zzz", style: .primary, action: {})
                        .disabled(true)
                } else {
                    Text("两击上床").srFont(.lg, .semibold)
                    Text("上床一点、起床一点；问卷三题都可以跳过，跳过不扣分。")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                    SRButton("上床", icon: "moon.zzz", style: .primary) {
                        _ = model.startSleepTimer(now: Date())
                    }
                }
            }
        }
    }

    // MARK: - 近 7 天趋势（一律出自 periodSummary）

    /// 近 7 天区间统计（分数/均值唯一来源，A3 口径）。
    private var weekSummary: SleepPeriodSummary {
        SleepEngine.periodSummary(model.sleepSessions,
                                  in: model.recordsRecentSpan(days: 7),
                                  goalMinutes: model.settings.sleepGoalMinutes,
                                  calendar: model.recordsCalendar)
    }

    private var durationRows: [SleepTrendRow] {
        weekSummary.series.compactMap { night in
            guard let minutes = night.durationMinutes else { return nil }
            return SleepTrendRow(id: "\(night.day.rawValue)-min",
                                 label: RecordsFmt.dayLabel(night.day),
                                 value: Double(minutes))
        }
    }

    private var scoreRows: [SleepTrendRow] {
        weekSummary.series.compactMap { night in
            guard let score = night.score else { return nil }
            return SleepTrendRow(id: "\(night.day.rawValue)-score",
                                 label: RecordsFmt.dayLabel(night.day),
                                 value: Double(score))
        }
    }

    private var trendCard: some View {
        let summary = weekSummary
        return SRCard {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                HStack {
                    Text("近 7 天").srFont(.lg, .semibold)
                    Spacer()
                    if let avgScore = summary.avgScore {
                        SRBadge("平均 \(avgScore) 分", tone: .info)
                    }
                }
                if summary.nights == 0 {
                    srRecordsEmptyHint("还没有睡眠记录——今晚两击开始。")
                } else {
                    VStack(alignment: .leading, spacing: SRSpacing.xs) {
                        RecordsSectionLabel("夜间时长（缺记夜不画柱）")
                        SRChartContainer(height: 140) {
                            Chart(durationRows) { row in
                                BarMark(x: .value("日", row.label),
                                        y: .value("分钟", row.value))
                                    .foregroundStyle(SRChartPalette.hue(.violet, scheme))
                                    .cornerRadius(2)
                            }
                            .srYAxisGrid()
                            .srRecordsXAxis()
                        }
                    }
                    if !scoreRows.isEmpty {
                        VStack(alignment: .leading, spacing: SRSpacing.xs) {
                            RecordsSectionLabel("逐夜分数（0–100）")
                            SRChartContainer(height: 140) {
                                Chart(scoreRows) { row in
                                    LineMark(x: .value("日", row.label),
                                             y: .value("分数", row.value))
                                        .foregroundStyle(SRChartPalette.hue(.teal, scheme))
                                        .lineStyle(StrokeStyle(lineWidth: SRChartMetrics.strokeWidth))
                                    PointMark(x: .value("日", row.label),
                                              y: .value("分数", row.value))
                                        .foregroundStyle(SRChartPalette.hue(.teal, scheme))
                                }
                                .srYAxisGrid()
                                .chartYScale(domain: 0.0...100.0)
                                .srRecordsXAxis()
                            }
                        }
                    }
                    Text("分数与均值一律以近 7 天区间中位就寝锚计算（periodSummary），与报告口径一致。")
                        .srFont(.xs)
                        .foregroundStyle(Color.srForegroundSubtle)
                }
            }
        }
    }

    // MARK: - 睡眠债与规律性摘要

    private var summaryGrid: some View {
        let summary = weekSummary
        let columns = [GridItem(.flexible(), spacing: SRSpacing.md),
                       GridItem(.flexible(), spacing: SRSpacing.md)]
        return VStack(spacing: SRSpacing.md) {
            LazyVGrid(columns: columns, spacing: SRSpacing.md) {
                SRStatCard(label: "睡眠债（近 7 晚）",
                           value: Formatting.duration(minutes: Double(summary.debtMinutes)))
                SRStatCard(label: "平均夜间时长",
                           value: summary.avgMinutes.map { Formatting.duration(minutes: Double($0)) } ?? "—")
                SRStatCard(label: "中位就寝", value: summary.medBedtimeHM)
                SRStatCard(label: "就寝规律 MAD",
                           value: summary.madMinutes.map { "±\($0) 分" } ?? "—")
            }
            HStack(spacing: SRSpacing.lg) {
                if summary.napMinutes > 0 {
                    Text("区间午睡 \(Formatting.duration(minutes: Double(summary.napMinutes)))")
                }
                if !summary.missingDays.isEmpty {
                    Text("缺记 \(summary.missingDays.count) 晚（不进均值、不记债）")
                }
                Spacer()
            }
            .srFont(.xs)
            .foregroundStyle(Color.srForegroundSubtle)
        }
    }

    // MARK: - 会话列表（点开调整归属）

    private var recentSessions: [SleepSession] {
        Array(model.sleepSessions.sorted { $0.end > $1.end }.prefix(14))
    }

    private func sessionRow(_ session: SleepSession) -> some View {
        let calendar = model.recordsCalendar
        let day = SleepEngine.sessionDay(session, calendar: calendar)
        let isNap = SleepEngine.isNap(start: session.start, end: session.end, calendar: calendar)
        return SRCard(padding: SRSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SRSpacing.sm) {
                    Text(RecordsFmt.dayLabel(day)).srFont(.base, .medium)
                    if isNap { SRBadge("午睡") }
                    if session.dayOverride != nil { SRBadge("手动归属") }
                    Spacer()
                }
                Text("\(RecordsFmt.hm(session.start, calendar: calendar)) – "
                     + "\(RecordsFmt.hm(session.end, calendar: calendar)) · "
                     + Formatting.duration(minutes: SleepEngine.durationSeconds(session) / 60))
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
                if let feel = session.feel {
                    Text("起床感受 \(feel)/5")
                        .srFont(.xs)
                        .foregroundStyle(Color.srForegroundSubtle)
                }
            }
        }
    }

    private func openOverride(_ session: SleepSession) {
        page.overrideSession = session
        page.overrideDate = model.recordsCalendar.date(
            of: SleepEngine.sessionDay(session, calendar: model.recordsCalendar)
        ) ?? Date()
    }
}

// MARK: - 起床问卷 sheet（三题可整页跳过）

struct SleepWakeSheet: View {

    @ObservedObject var model: AppModel
    @ObservedObject var page: SleepRecordsModel

    var body: some View {
        VStack(alignment: .leading, spacing: SRSpacing.lg) {
            if let pending = page.pending {
                Text("起床问卷").srFont(.lg, .semibold)
                Text("睡了 \(Formatting.duration(minutes: pending.durationMinutes))（"
                     + RecordsFmt.hm(pending.startedAt, calendar: model.recordsCalendar) + " – "
                     + RecordsFmt.hm(pending.wokeAt, calendar: model.recordsCalendar) + "）")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)

                question("起床感受（1–5）", options: SleepRecordsModel.feelOptions, selection: $page.feelText)
                question("夜醒次数（0–3）", options: SleepRecordsModel.wakesOptions, selection: $page.wakesText)
                question("入睡快慢", options: SleepRecordsModel.latencyOptions, selection: $page.latencyText)

                Text("三题都可以不填：跳过不惩罚，未填项按中性分计入。")
                    .srFont(.xs)
                    .foregroundStyle(Color.srForegroundSubtle)

                HStack {
                    Spacer()
                    SRButton("返回", style: .ghost) { page.pending = nil }
                    SRButton("完成", style: .primary) {
                        _ = model.completeSleepSession(startedAt: pending.startedAt,
                                                        wokeAt: pending.wokeAt,
                                                        feel: page.feel,
                                                        wakeCount: page.wakeCount,
                                                        latency: page.latency,
                                                        note: nil)
                        page.pending = nil
                    }
                }
            } else {
                Text("没有待完成的起床").srFont(.lg, .semibold)
            }
        }
        .padding(SRSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(true)
    }

    private func question(_ title: String, options: [String], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            Text(title).srFont(.base, .medium)
            SRSegmented(options: options, selection: selection, size: .sm)
        }
    }
}

// MARK: - 归属调整 sheet（dayOverride / 恢复自动）

struct SleepOverrideSheet: View {

    @ObservedObject var model: AppModel
    @ObservedObject var page: SleepRecordsModel

    var body: some View {
        VStack(alignment: .leading, spacing: SRSpacing.lg) {
            if let session = page.overrideSession {
                let calendar = model.recordsCalendar
                Text("调整归属日").srFont(.lg, .semibold)
                Text("自动归属（醒来往前推 4 小时所在日）："
                     + SleepEngine.sleepDayKey(end: session.end, calendar: calendar).rawValue)
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
                if let override = session.dayOverride {
                    Text("当前手动归属：\(override.rawValue)")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                }
                DatePicker("归属日", selection: $page.overrideDate, displayedComponents: .date)
                HStack {
                    SRButton("恢复自动", style: .ghost) {
                        model.setSleepDayOverride(nil, for: session.id)
                        page.overrideSession = nil
                    }
                    Spacer()
                    SRButton("取消", style: .ghost) { page.overrideSession = nil }
                    SRButton("保存", style: .primary) {
                        model.setSleepDayOverride(
                            DayKey(page.overrideDate, calendar: model.recordsCalendar),
                            for: session.id)
                        page.overrideSession = nil
                    }
                }
            } else {
                Text("没有选中的会话").srFont(.lg, .semibold)
            }
        }
        .padding(SRSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(true)
    }
}

// MARK: - 补记 / 编辑 sheet（sleep.js:172 sessionSheet：补记与编辑共用）

struct SleepEntrySheet: View {

    @ObservedObject var model: AppModel
    @ObservedObject var page: SleepRecordsModel

    var body: some View {
        // 判定全在引擎（视图层零业务规则）：校验错误 + 归属预览实时重算
        let draft = page.editorDraft
        let error = SleepEngine.entryError(start: draft.bed, end: draft.wake)
        let preview = SleepEngine.entryPreview(start: draft.bed, end: draft.wake,
                                               dayOverride: draft.dayOverride,
                                               calendar: model.recordsCalendar)
        return VStack(alignment: .leading, spacing: SRSpacing.lg) {
            Text(draft.isEditing ? "编辑睡眠" : "补记睡眠").srFont(.lg, .semibold)

            // 默认 displayedComponents 即日期+时刻（DatePickerComponents 无
            // .dateAndTime 成员；跨零点补录需要完整日期，不用 hourAndMinute 档）
            DatePicker("上床", selection: $page.editorDraft.bed)
                .datePickerStyle(.compact)
            DatePicker("起床", selection: $page.editorDraft.wake)
                .datePickerStyle(.compact)

            // 归属预览（实时更新；文案拼装是展示，日与夜睡/午睡判定来自引擎）
            Text(previewText(preview))
                .srFont(.sm)
                .foregroundStyle(Color.srForegroundMuted)

            question("起床感受（1–5）", options: SleepRecordsModel.feelOptions,
                     selection: $page.editorDraft.feelText)
            question("夜醒次数（0–3）", options: SleepRecordsModel.wakesOptions,
                     selection: $page.editorDraft.wakesText)
            question("入睡快慢", options: SleepRecordsModel.latencyOptions,
                     selection: $page.editorDraft.latencyText)

            if let error {
                Text(Self.errorText(error))
                    .srFont(.sm)
                    .foregroundStyle(Color.srDanger)
            }

            HStack(spacing: SRSpacing.md) {
                if draft.isEditing {
                    SRButton("删除", icon: "trash", style: .danger, size: .sm) {
                        page.showsEditorDeleteDialog = true
                    }
                }
                Spacer()
                SRButton("取消", style: .ghost) { page.showsEditor = false }
                SRButton("保存", style: .primary, action: save)
                    .disabled(error != nil)
            }
        }
        .padding(SRSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.large])
        .interactiveDismissDisabled(true)
        .confirmationDialog("删除这段睡眠记录？",
                            isPresented: $page.showsEditorDeleteDialog,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let id = page.editorDraft.sessionID {
                    model.deleteSleepSession(id: id)
                }
                page.showsEditor = false
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 子视图与文案

    private func question(_ title: String, options: [String], selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.xs) {
            Text(title).srFont(.base, .medium)
            SRSegmented(options: options, selection: selection, size: .sm)
        }
    }

    /// 「将记为 10月5日晚 · 夜睡」；午睡不带「晚」（白天的午睡挂在当天名下）。
    private func previewText(_ preview: SleepEntryPreview) -> String {
        let day = RecordsFmt.monthDayLabel(preview.day)
        return preview.isNap ? "将记为 \(day) · 午睡" : "将记为 \(day)晚 · 夜睡"
    }

    /// 校验错误 → 中文文案（TimeBlockEditorSheet 同款：文案在视图层，判定在引擎）。
    private static func errorText(_ error: SleepEntryError) -> String {
        switch error {
        case .endNotAfterStart: return "起床时间要晚于上床时间（跨零点请把起床调到次日）"
        case .tooShort: return "这段睡眠太短了，检查一下时间（不足 1 分钟）"
        case .over24Hours: return "单段睡眠不能超过 24 小时"
        }
    }

    private func save() {
        let draft = page.editorDraft
        // 保存按钮已按 entryError 禁用，这里只做兜底：失败保持 sheet 打开
        if let id = draft.sessionID {
            if model.updateSleepSession(id: id, start: draft.bed, end: draft.wake,
                                        feel: draft.feel, wakeCount: draft.wakeCount,
                                        latency: draft.latency,
                                        dayOverride: draft.dayOverride) != nil {
                return
            }
        } else if model.addManualSleepSession(start: draft.bed, end: draft.wake,
                                              feel: draft.feel, wakeCount: draft.wakeCount,
                                              latency: draft.latency) != nil {
            return
        }
        page.showsEditor = false
    }
}
