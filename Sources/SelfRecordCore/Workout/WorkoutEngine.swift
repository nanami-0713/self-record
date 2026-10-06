import Foundation

// MARK: - workout 模块（design.md §3.3）
//
// 文件组成（本目录 = Workout/，workout 工程师独占；只依赖基础层，禁止横向调用）：
//   ExerciseLibrary.swift  内置动作库 112 项 + 名称匹配/搜索
//   SessionAnalysis.swift  est1RM / sessionStats / bestE1History / analyzeSession
//                         （单次分析 → WorkoutAnalysisSnapshot 落盘快照）
//   WorkoutEngine.swift   本文件：阶段分析（7/30/90 天）
//
// lifttime 对应：js/exercises.js + js/analysis.js（阶段分析 :282-396）。
//
// 跨域注入（§2 冻结契约）：恢复建议上下文全部显式收 RecoveryContext
// （analyzeSession 的 recovery 参数）——注入者由 UI / report 组装
// （DietEngine.dayIntake + TimeEngine.fitnessMinutes），本模块不调其它域引擎。

/// 训练引擎（§3.3）。`analyzePeriod(_:in:calendar:)` 签名 = 骨架冻结物 B（§2.1），
/// **不得偏离**；自定义动作版本走 `analyzePeriod(_:customExercises:in:calendar:)`
/// （冻结签名委托到它，内置动作口径完全一致）。
public enum WorkoutEngine {

    /// 区间阶段分析（频率/容量环比/部位分布/PR/streak/平衡/语气六档）。
    /// 窗口 = span 含首尾；对比窗 = 窗口等长前移一期（lifttime analyzePeriod
    /// 的 [start,end) 语义映射到 DateSpan 含首尾口径）。
    public static func analyzePeriod(_ workouts: [Workout],
                                     in span: DateSpan,
                                     calendar: DayCalendar) -> WorkoutPeriodAnalysis {
        analyzePeriod(workouts, customExercises: [], in: span, calendar: calendar)
    }

    /// 阶段分析（自定义动作版）：UI / report 用 exercises.json 的自定义库解析条目。
    public static func analyzePeriod(_ workouts: [Workout],
                                     customExercises: [Exercise],
                                     in span: DateSpan,
                                     calendar: DayCalendar) -> WorkoutPeriodAnalysis {
        guard span.isValid,
              let start = calendar.date(of: span.startDay),
              let endInclusive = calendar.date(of: span.endDay),
              let endExclusive = calendar.calendar.date(byAdding: .day, value: 1, to: endInclusive)
        else { return WorkoutPeriodAnalysis() }
        let rawDays = calendar.calendar.dateComponents([.day], from: start, to: endExclusive).day ?? 1
        let days = max(1, rawDays)

        let inWin = workouts
            .filter { $0.startedAt >= start && $0.startedAt < endExclusive }
            .sorted { $0.startedAt < $1.startedAt }
        let prevStart = calendar.calendar.date(byAdding: .day, value: -days, to: start) ?? start
        let prevWin = workouts.filter { $0.startedAt >= prevStart && $0.startedAt < start }

        // 频率与容量环比（analysis.js:291-294）
        let weeks = Double(days) / 7
        let freqRaw = weeks > 0 ? Double(inWin.count) / weeks : 0
        let freqPerWeek = (freqRaw * 10).rounded() / 10
        let tonnageThis = inWin.reduce(0.0) { $0 + sessionStats($1, customExercises: customExercises).tonnage }
        let tonnagePrev = prevWin.reduce(0.0) { $0 + sessionStats($1, customExercises: customExercises).tonnage }
        let trendPct: Int? = tonnagePrev > 0
            ? Int(((tonnageThis / tonnagePrev - 1) * 100).rounded()) : nil

        // 部位分布（按结构组聚合；analysis.js:297-304）
        var groupVolume: [StructuralGroup: Double] = [:]
        var groupSetCount: [StructuralGroup: Int] = [:]
        for w in inWin {
            for g in sessionStats(w, customExercises: customExercises).groups {
                groupVolume[g.key, default: 0] += g.volume
                groupSetCount[g.key, default: 0] += g.setCount
            }
        }
        let groupTotal = groupVolume.values.reduce(0, +)
        let groups = groupVolume.keys
            .sorted { (a, b) in
                let va = groupVolume[a] ?? 0, vb = groupVolume[b] ?? 0
                if va != vb { return va > vb }
                return (groupOrder[a] ?? 0) < (groupOrder[b] ?? 0)
            }
            .map { key -> GroupStat in
                let vol = groupVolume[key] ?? 0
                return GroupStat(key: key,
                                 label: ExerciseLibrary.groupLabel(key),
                                 volume: vol,
                                 setCount: groupSetCount[key] ?? 0,
                                 share: vol / (groupTotal != 0 ? groupTotal : 1))
            }
        func shareOf(_ key: StructuralGroup) -> Double {
            groups.first { $0.key == key }?.share ?? 0
        }

        // 窗口 PR：滚动 runningBest（analysis.js:307-319）
        let bestBeforeWin = bestE1History(workouts.filter { $0.startedAt < start }, before: nil)
        var runningBest = bestBeforeWin
        var prs: [WindowPRRecord] = []
        for w in inWin {
            for entry in w.entries {
                var best = 0.0
                for s in entry.sets {
                    best = max(best, est1RM(weightKg: s.weightKg, reps: s.reps))
                }
                if best > 0 && best > (runningBest[entry.exerciseID] ?? 0) {
                    prs.append(WindowPRRecord(exerciseID: entry.exerciseID,
                                              e1RM: best,
                                              prevE1RM: runningBest[entry.exerciseID] ?? 0,
                                              at: w.startedAt))
                    runningBest[entry.exerciseID] = best
                }
            }
        }

        // 连续训练天数（截至最近一次训练；analysis.js:322-328）
        var streak = 0
        var workoutDays = Set<DayKey>()
        if let last = inWin.last {
            for w in inWin { workoutDays.insert(calendar.dayKey(for: w.startedAt)) }
            var day = calendar.dayKey(for: last.startedAt)
            while workoutDays.contains(day) {
                streak += 1
                guard let prev = calendar.addingDays(-1, to: day) else { break }
                day = prev
            }
        }
        let restDays = days - workoutDays.count

        // 平衡性（analysis.js:331-338）
        let pushShare = shareOf(.push), pullShare = shareOf(.pull), legsShare = shareOf(.legs)
        var balanceNotes: [String] = []
        if pushShare + pullShare > 0.3 && pullShare / (pushShare > 0 ? pushShare : 0.01) < 0.5 {
            balanceNotes.append("拉类明显少于推类，时间久了圆肩、体态问题容易找上门，下次课优先补划船/引体类动作。")
        }
        if pushShare + pullShare > 0.3 && pushShare / (pullShare > 0 ? pullShare : 0.01) < 0.5 {
            balanceNotes.append("推类偏少，胸肩的容量这周可以加回来一些。")
        }
        if legsShare < 0.2 && (pushShare + pullShare) > 0.4 {
            balanceNotes.append("下肢占比不到两成，深蹲/硬拉这类大动作对全身激素环境和基础力量的回报最高，建议每周至少安排一次腿。")
        }
        if shareOf(.core) < 0.05 && inWin.count >= 2 {
            balanceNotes.append("核心练得很少，可以在组间穿插 2–3 组平板或举腿，不占额外时间。")
        }
        if balanceNotes.isEmpty && !inWin.isEmpty {
            balanceNotes.append("各部位分布比较均衡，继续保持这个节奏。")
        }

        // 状态评价（analysis.js:341-356）
        var stateParts: [String] = []
        stateParts.append("近 \(days) 天练了 \(inWin.count) 次（约 \(String(format: "%.1f", freqPerWeek)) 次/周）"
            + (tonnageThis > 0 ? "，总容量 \(WorkoutEngine.fmtLoad(tonnageThis))" : ""))
        if let trend = trendPct {
            if trend >= 15 {
                stateParts.append("比上一个 \(days) 天高 \(trend)%，容量处在上升通道")
            } else if trend <= -15 {
                stateParts.append("比上一个 \(days) 天低 \(abs(trend))%，量在回落")
            } else {
                stateParts.append("与上一阶段基本持平（\(trend >= 0 ? "+" : "")\(trend)%）")
            }
        } else if !inWin.isEmpty {
            stateParts.append("（上一阶段没有训练记录，趋势暂无法对比）")
        }
        if !prs.isEmpty {
            let refreshed = prs.filter { $0.prevE1RM > 0 }
            let firstCount = prs.count - refreshed.count
            var prText = ""
            if !refreshed.isEmpty {
                prText += "刷新 \(refreshed.count) 项个人纪录（"
                    + refreshed.prefix(3).map { Self.displayExerciseName($0.exerciseID, customExercises) }
                        .joined(separator: "、")
                    + (refreshed.count > 3 ? " 等" : "") + "）"
            }
            if firstCount > 0 {
                prText += (prText.isEmpty ? "首次建立 " : "，另外首次建立 ") + "\(firstCount) 个动作的力量基准"
            }
            stateParts.append("期间" + prText)
        }

        // 状态评价语气（六档）与建议（analysis.js:358-375）
        var tone: String
        var advice: [String] = []
        if inWin.isEmpty {
            tone = "这段时间没有训练记录。休息也是训练的一部分，但如果已经超过一周，从一次 30 分钟的轻量课重新启动最容易。"
            advice.append("先安排 2–3 组轻重量找回动作感，别一上来就冲 PR。")
        } else if freqPerWeek < 1 {
            tone = "频率偏低，进步主要靠规律的重复刺激，一周至少 2 次是性价比最高的起点。"
            advice.append("把训练固定写进日程（比如周二/周五晚），配合 App 的时间记录会更容易坚持。")
        } else if streak >= 5 {
            tone = "连续训练 \(streak) 天没有整休，进步幅度可能开始被疲劳吃掉，安排 1–2 天完全休息或低强度日会更好。"
            advice.append("疲劳是累积的，敢休息才敢进步。")
        } else if let trend = trendPct, trend >= 15, streak < 5 {
            tone = "容量与频率都在爬升，状态处于上升期；注意睡眠和蛋白质跟上，别让恢复拖后腿。"
        } else if prs.count >= 2 {
            tone = "力量在实打实增长，说明目前的计划适合你，照这个节奏推进即可。"
        } else {
            tone = "训练节奏稳定，属于积累期——力量的增长常滞后于努力，再给身体两三周时间。"
        }
        if let trend = trendPct, trend >= 40 {
            advice.append("容量单阶段涨幅超过四成，属于比较激进的加量，留意关节和小肌群的疲劳信号。")
        }

        // 逐日容量（趋势图数据；analysis.js:386-396 dailySeries）
        var dailyVolume: [DailyVolumePoint] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.addingDays(-offset, to: span.endDay),
                  let dayStart = calendar.date(of: day),
                  let dayEnd = calendar.calendar.date(byAdding: .day, value: 1, to: dayStart)
            else { continue }
            let ws = workouts.filter { $0.startedAt >= dayStart && $0.startedAt < dayEnd }
            let vol = ws.reduce(0.0) { $0 + sessionStats($1, customExercises: customExercises).tonnage }
            dailyVolume.append(DailyVolumePoint(day: day, volumeKg: vol, sessions: ws.count))
        }

        return WorkoutPeriodAnalysis(days: days,
                                     sessions: inWin.count,
                                     freqPerWeek: freqPerWeek,
                                     volumeKg: tonnageThis,
                                     trendPct: trendPct,
                                     groups: groups,
                                     prs: prs,
                                     streak: streak,
                                     restDays: restDays,
                                     balanceNotes: balanceNotes,
                                     stateParts: stateParts,
                                     tone: tone,
                                     advice: advice,
                                     dailyVolume: dailyVolume)
    }

    /// 动作 id → 展示名（内置 id=规范名；自定义取其 name；未知原样返回）。
    static func displayExerciseName(_ exerciseID: String, _ customExercises: [Exercise]) -> String {
        ExerciseLibrary.resolve(exerciseID: exerciseID, customExercises: customExercises)?.name ?? exerciseID
    }
}

// MARK: - 阶段分析值类型（字段按 §3.3 / lifttime analyzePeriod 返回值填充）

/// 窗口内滚动 PR 记录（同一动作可在窗口内多次刷新，id 含时间戳去重）。
public struct WindowPRRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { exerciseID + "@" + String(at.timeIntervalSince1970) }
    public var exerciseID: String
    public var e1RM: Double
    public var prevE1RM: Double            // 0 = 窗口前无纪录（首次建立基准）
    public var at: Date

    public init(exerciseID: String, e1RM: Double, prevE1RM: Double, at: Date) {
        self.exerciseID = exerciseID
        self.e1RM = e1RM
        self.prevE1RM = prevE1RM
        self.at = at
    }
}

/// 近 N 天逐日容量点（趋势图数据；lifttime dailySeries 元素）。
public struct DailyVolumePoint: Codable, Sendable, Equatable {
    public var day: DayKey
    public var volumeKg: Double
    public var sessions: Int

    public init(day: DayKey, volumeKg: Double, sessions: Int) {
        self.day = day
        self.volumeKg = volumeKg
        self.sessions = sessions
    }
}

/// analyzePeriod 返回类型（§2.1 冻结签名的产物；字段语义 = lifttime
/// analyzePeriod 返回值）：频率/容量环比/部位组分布/窗口 PR 滚动 runningBest/
/// 连续 streak ≥5 提示休息/推拉腿平衡提醒/六档语气 tone。
public struct WorkoutPeriodAnalysis: Codable, Sendable, Equatable {
    public var days: Int
    public var sessions: Int
    public var freqPerWeek: Double              // 1 位小数（lifttime toFixed(1) 口径）
    public var volumeKg: Double
    public var trendPct: Int?                   // vs 上一等长窗口；nil=无可比数据
    public var groups: [GroupStat]
    public var prs: [WindowPRRecord]
    public var streak: Int
    public var restDays: Int
    public var balanceNotes: [String]
    public var stateParts: [String]
    public var tone: String
    public var advice: [String]
    public var dailyVolume: [DailyVolumePoint]

    public init(days: Int = 0,
                sessions: Int = 0,
                freqPerWeek: Double = 0,
                volumeKg: Double = 0,
                trendPct: Int? = nil,
                groups: [GroupStat] = [],
                prs: [WindowPRRecord] = [],
                streak: Int = 0,
                restDays: Int = 0,
                balanceNotes: [String] = [],
                stateParts: [String] = [],
                tone: String = "",
                advice: [String] = [],
                dailyVolume: [DailyVolumePoint] = []) {
        self.days = days
        self.sessions = sessions
        self.freqPerWeek = freqPerWeek
        self.volumeKg = volumeKg
        self.trendPct = trendPct
        self.groups = groups
        self.prs = prs
        self.streak = streak
        self.restDays = restDays
        self.balanceNotes = balanceNotes
        self.stateParts = stateParts
        self.tone = tone
        self.advice = advice
        self.dailyVolume = dailyVolume
    }
}
