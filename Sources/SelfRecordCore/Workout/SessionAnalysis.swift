import Foundation

// MARK: - 单次训练统计与快照（design.md §3.3）
//
// lifttime 对应：js/analysis.js
//   est1RM        analysis.js:6-9
//   sessionStats  analysis.js:16-76（分摊 :36-44、组归属 :49）
//   bestE1History analysis.js:79-91
//   analyzeSession analysis.js:95-276（PR :113-131、DOMS :146-155、
//   恢复 ctx :188-218、简评 :221-263）
//
// 产物 WorkoutAnalysisSnapshot = Model 冻结契约（历史落盘不漂移、可再生成、
// 未来 AI 输出契约 = 渲染契约）。所有文本按 lifttime 原文移植（口径即文案）。

extension WorkoutEngine {

    // MARK: - Epley e1RM（analysis.js:6-9，rep 15 封顶）

    /// Epley 估算 1RM = w×(1+min(r,15)/30)；非正重量/次数返回 0。
    public static func est1RM(weightKg: Double, reps: Int) -> Double {
        guard weightKg > 0, reps > 0 else { return 0 }
        return weightKg * (1 + Double(min(reps, 15)) / 30)
    }

    // MARK: - 一次训练的肌群/容量统计（analysis.js:16-76）

    /// 一次训练统计：容量 = 重量×次数；自重/无重量动作容量记 0 但组数次数计入，
    /// 肌群分摊 credit = 容量 > 0 ? 容量 : 1（按组计）；
    /// 主肌群 1/n、次肌群 0.5/n（analysis.js:36-44）；
    /// 结构组按「每个主肌群整记该动作的总容量与组数」累计（analysis.js:49）。
    public static func sessionStats(_ workout: Workout, customExercises: [Exercise] = []) -> SessionStats {
        var muscleVolume: [MuscleGroup: Double] = [:]
        var muscleSets: [MuscleGroup: Double] = [:]
        var muscleReps: [MuscleGroup: Double] = [:]
        var groupVolume: [StructuralGroup: Double] = [:]
        var groupSets: [StructuralGroup: Int] = [:]
        var tonnage = 0.0
        var setCount = 0
        var repCount = 0
        var topSets: [TopSetStat] = []
        var eccentricSetCount = 0
        var cardioSetCount = 0
        var bodyweightSetCount = 0

        for entry in workout.entries {
            let resolved = ExerciseLibrary.resolve(exerciseID: entry.exerciseID,
                                                   customExercises: customExercises)
            var exerciseTonnage = 0.0
            var exerciseSetCount = 0
            var exerciseRepCount = 0
            var best: BestSetInfo?
            for set in entry.sets {
                let w = set.weightKg > 0 ? set.weightKg : 0
                let r = set.reps > 0 ? set.reps : 0
                let vol = w * Double(r)
                tonnage += vol; exerciseTonnage += vol
                setCount += 1; exerciseSetCount += 1
                repCount += r; exerciseRepCount += r
                let e1 = est1RM(weightKg: w, reps: r)
                if best == nil || e1 > best!.e1RM {
                    best = BestSetInfo(weightKg: w, reps: r, e1RM: e1)
                }
                let credit = vol > 0 ? vol : 1.0   // 自重动作按组计（analysis.js:36）
                let primaries = resolved?.primaryMuscles ?? []
                if !primaries.isEmpty {
                    let c = 1.0 / Double(primaries.count)
                    for k in primaries {
                        muscleVolume[k, default: 0] += credit * c
                        muscleSets[k, default: 0] += c
                        muscleReps[k, default: 0] += Double(r)
                    }
                }
                let secondaries = resolved?.secondaryMuscles ?? []
                if !secondaries.isEmpty {
                    let c = 0.5 / Double(secondaries.count)
                    for k in secondaries {
                        muscleVolume[k, default: 0] += credit * c
                        muscleSets[k, default: 0] += c
                        muscleReps[k, default: 0] += Double(r)
                    }
                }
                if resolved?.isEccentricHeavy == true { eccentricSetCount += 1 }
                if resolved?.isCardio == true { cardioSetCount += 1 }
                if w == 0 { bodyweightSetCount += 1 }
            }
            // 主肌群所在结构组整记本动作容量与组数（analysis.js:49）
            for k in (resolved?.primaryMuscles ?? []) {
                let g = ExerciseLibrary.groupOfMuscle(k)
                groupVolume[g, default: 0] += exerciseTonnage
                groupSets[g, default: 0] += exerciseSetCount
            }
            topSets.append(TopSetStat(exerciseID: entry.exerciseID,
                                      displayName: resolved?.name ?? entry.exerciseID,
                                      setCount: exerciseSetCount,
                                      repCount: exerciseRepCount,
                                      tonnage: exerciseTonnage,
                                      best: best))
        }

        // share 分摊（分母为 0 时取 1，防除零；analysis.js:53/:67）
        let muscleTotal = muscleVolume.values.reduce(0, +)
        let muscles = muscleVolume.keys
            .sorted { (a, b) in
                let va = muscleVolume[a] ?? 0, vb = muscleVolume[b] ?? 0
                if va != vb { return va > vb }
                return (muscleOrder[a] ?? 0) < (muscleOrder[b] ?? 0)   // 并列按枚举声明序，输出确定
            }
            .map { key -> MuscleStat in
                let vol = muscleVolume[key] ?? 0
                return MuscleStat(key: key,
                                  label: ExerciseLibrary.muscleLabel(key),
                                  group: ExerciseLibrary.groupOfMuscle(key),
                                  volume: vol,
                                  sets: muscleSets[key] ?? 0,
                                  reps: muscleReps[key] ?? 0,
                                  share: vol / (muscleTotal != 0 ? muscleTotal : 1))
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
                                 setCount: groupSets[key] ?? 0,
                                 share: vol / (groupTotal != 0 ? groupTotal : 1))
            }

        return SessionStats(tonnage: tonnage,
                            setCount: setCount,
                            repCount: repCount,
                            muscles: muscles,
                            groups: groups,
                            topSets: topSets,
                            eccentricSetCount: eccentricSetCount,
                            cardioSetCount: cardioSetCount,
                            bodyweightSetCount: bodyweightSetCount)
    }

    /// MuscleGroup / StructuralGroup 声明序（排序并列时的确定性 tiebreaker）。
    static let muscleOrder: [MuscleGroup: Int] =
        Dictionary(uniqueKeysWithValues: MuscleGroup.allCases.enumerated().map { ($1, $0) })
    static let groupOrder: [StructuralGroup: Int] =
        Dictionary(uniqueKeysWithValues: StructuralGroup.allCases.enumerated().map { ($1, $0) })

    // MARK: - 历史 e1RM 最佳（analysis.js:79-91）

    /// 历史中每个动作的 e1RM 最好成绩；`before` 非nil 时排除该时刻起之后的训练
    /// （w.startedAt >= before 跳过）。key = exerciseID。
    public static func bestE1History(_ workouts: [Workout], before: Date?) -> [String: Double] {
        var best: [String: Double] = [:]
        for w in workouts {
            if let before = before, w.startedAt >= before { continue }
            for entry in w.entries {
                for s in entry.sets {
                    let e1 = est1RM(weightKg: s.weightKg, reps: s.reps)
                    if e1 > 0 && e1 > (best[entry.exerciseID] ?? 0) {
                        best[entry.exerciseID] = e1
                    }
                }
            }
        }
        return best
    }

    // MARK: - 单次训练完整分析 → 落盘快照（analysis.js:95-276）

    /// 单次训练完整分析，产出落盘快照 `Workout.analysis`（历史不漂移；详情页
    /// 「按当前口径再生成」= 用相同入参重跑本函数显式覆盖）。
    ///
    /// - Parameters:
    ///   - workout: 本次训练。
    ///   - history: 历史训练（引擎只取 startedAt 严格早于本次者；建议传全量，函数内过滤）。
    ///   - customExercises: 自定义动作库（exercises.json）。
    ///   - recovery: 跨域注入上下文（design.md §2 冻结契约）——bodyweightKg /
    ///     dayIntake（proteinG/kcal/itemCount/hasPostMeal）/ fitnessTimeMinutes，
    ///     注入者由 UI / report 组装（DietEngine.dayIntake + TimeEngine.fitnessMinutes）。
    public static func analyzeSession(_ workout: Workout,
                                      history: [Workout],
                                      customExercises: [Exercise] = [],
                                      recovery: RecoveryContext = RecoveryContext()) -> WorkoutAnalysisSnapshot {
        let stats = sessionStats(workout, customExercises: customExercises)
        // lifttime 假定 history 升序（store 追加序）；此处显式排序后再取「近 5 次」，
        // 语义相同且对乱序输入稳健。
        let prior = history
            .filter { $0.startedAt < workout.startedAt }
            .sorted { $0.startedAt < $1.startedAt }
        let bestBefore = bestE1History(prior, before: nil)

        // —— 主练 / 次重点（analysis.js:107-111）——
        let primaryPool = stats.muscles.filter { $0.share >= 0.25 }.prefix(3)
        let primary = primaryPool.isEmpty ? Array(stats.muscles.prefix(1)) : Array(primaryPool)
        let primaryKeys = Set(primary.map(\.key))
        let secondary = stats.muscles
            .filter { !primaryKeys.contains($0.key) && $0.share >= 0.12 }
            .prefix(3)
        func labels(_ list: [MuscleStat]) -> String {
            list.map { ExerciseLibrary.muscleLabel($0.key) }.joined(separator: "、")
        }
        let primaryLabels = labels(primary)
        let secondaryLabels = labels(Array(secondary))

        // —— 强度：本次每组最好 e1RM vs 历史最佳（analysis.js:113-131）——
        var ratioSum = 0.0
        var ratioCount = 0
        var prs: [PRRecord] = []
        for top in stats.topSets {
            guard let best = top.best, best.e1RM > 0 else { continue }
            let hist = bestBefore[top.exerciseID] ?? 0
            if hist > 0 {
                ratioSum += best.e1RM / hist
                ratioCount += 1
            }
            if hist <= 0 || best.e1RM > hist {   // prev=0 → 首次基准
                prs.append(PRRecord(exerciseID: top.exerciseID,
                                    bestE1RM: best.e1RM,
                                    isNewBaseline: hist <= 0))
            }
        }
        let ratio = ratioCount > 0 ? ratioSum / Double(ratioCount) : nil
        let intensityBand: IntensityBand
        if let ratio {
            if ratio >= 0.95 { intensityBand = .high }
            else if ratio >= 0.85 { intensityBand = .moderatelyHigh }
            else if ratio >= 0.70 { intensityBand = .moderate }
            else { intensityBand = .light }
        } else {
            // 无历史可比时按组数兜底（analysis.js:129）
            if stats.setCount >= 20 { intensityBand = .moderatelyHigh }
            else if stats.setCount >= 10 { intensityBand = .moderate }
            else { intensityBand = .light }
        }

        // —— 容量 vs 近 5 次均值（analysis.js:132-137）——
        let prevTonnages = prior.suffix(5)
            .map { sessionStats($0, customExercises: customExercises).tonnage }
            .filter { $0 > 0 }
        var volumeVsRecentAverage: Double?
        if prevTonnages.count >= 2 {
            volumeVsRecentAverage = stats.tonnage / (prevTonnages.reduce(0, +) / Double(prevTonnages.count))
        }

        // —— 新动作比例（近 14 天没做过的；analysis.js:139-144）——
        let cut = workout.startedAt.addingTimeInterval(-14 * 86400)
        let recentIDs = Set(prior.filter { $0.startedAt >= cut }.flatMap { $0.entries.map(\.exerciseID) })
        let newCount = workout.entries.filter { !recentIDs.contains($0.exerciseID) }.count
        let newRatio = workout.entries.isEmpty ? 0.0 : Double(newCount) / Double(workout.entries.count)

        // —— 次日酸痛(DOMS)加权计分（analysis.js:146-155）——
        let legsHeavy = primary.contains { ExerciseLibrary.groupOfMuscle($0.key) == .legs }
            || (stats.groups.first?.key == .legs && (stats.groups.first?.share ?? 0) > 0.4)
        var domsScore = 1
        if let v = volumeVsRecentAverage {
            domsScore += v > 1.5 ? 3 : (v > 1.15 ? 2 : (v < 0.7 ? 0 : 1))
        } else {
            domsScore += stats.setCount >= 20 ? 2 : 1
        }
        domsScore += newRatio > 0.5 ? 2 : (newRatio > 0.2 ? 1 : 0)
        if stats.eccentricSetCount > 0 { domsScore += 1 }
        if legsHeavy { domsScore += 1 }
        if prior.isEmpty { domsScore += 1 }
        let domsLevel: DOMSLevel = domsScore >= 7 ? .severe
            : (domsScore >= 5 ? .noticeable : (domsScore >= 3 ? .moderate : .mild))

        // —— 练后感觉（analysis.js:157-177）——
        var postFeel = primary.compactMap { Self.postFeelText[$0.key] }
        if intensityBand == .high || (volumeVsRecentAverage ?? 0) > 1.3 {
            postFeel.append("这次强度/容量不小，练后可能比平时更累，晚上容易早困，是正常的深度刺激反应。")
        } else if stats.setCount >= 24 {
            postFeel.append("组数偏多，练后 1–2 小时可能进入明显疲劳期，先安排好这一餐再继续一天的事。")
        }

        // —— 次日感觉（analysis.js:179-185）——
        let nextDayText: String
        switch domsLevel {
        case .mild:
            nextDayText = "第二天基本无感或只有轻微发紧，属于正常恢复节奏，可以照常安排训练或活动。"
        case .moderate:
            nextDayText = "第二天目标肌群会有中度酸痛，24–48 小时内逐渐消退，日常活动基本不受影响。"
        case .noticeable:
            nextDayText = "预计第二天酸痛明显，起床和久坐后起身时最有感觉；"
                + (legsHeavy ? "腿臀类的酸痛常持续 48 小时以上，别急着安排第二次腿课。" : "48 小时内避免同部位再次大强度训练。")
        case .severe:
            nextDayText = "第二天可能出现较强酸痛并伴随短暂力量下降，这是超大容量刺激后的正常反应；把吃睡做好，必要时完全休息一天。"
        }

        // —— 恢复建议（analysis.js:188-218；RecoveryContext 完整消费）——
        let bw = recovery.bodyweightKg ?? 0
        let lo = bw > 0 ? Int((bw * 1.6).rounded()) : 80
        let hi = bw > 0 ? Int((bw * 2.2).rounded()) : 110
        var diet: [String] = []
        if let di = recovery.dayIntake, di.itemCount > 0 {
            // dayIntake.itemCount > 0 分支（analysis.js:193-197）
            let eaten = Int(di.proteinG.rounded())
            let left = max(0, lo - eaten)
            diet.append("你在饮食页已记录今天摄入约 \(eaten)g 蛋白质（目标 \(lo)–\(hi)g）"
                + (left > 0 ? "，还差约 \(left)g——练后这餐优先把它补上。" : "，下限已达成，练后再补 20–30g 巩固一下即可。"))
        } else if bw > 0 {
            diet.append("蛋白质按 \(fmtBodyweight(bw))kg、每公斤 1.6–2.2g 算，今天目标 \(lo)–\(hi)g，分 3–4 餐吃，练后 2 小时内先落实 25–40g。")
        } else {
            diet.append("蛋白质按每公斤体重 1.6–2.2g 摄入（在「设置」里填体重可得到具体克数），练后 2 小时内先吃含 25–40g 蛋白的一餐。")
        }
        if legsHeavy || (volumeVsRecentAverage ?? 0) > 1.2 {
            diet.append("这次练腿/容量偏大，碳水要吃够：练后一餐多安排米饭、面食或薯类帮糖原回补，这个阶段不用怕碳水。")
        } else {
            diet.append("练后一餐正常吃碳水＋蛋白的组合即可，别空着肚子硬扛。")
        }
        diet.append("训练每 1 小时补 500–750ml 水，全天以尿色淡黄为达标；出汗多时适当补点盐分。")

        var rest: [String] = []
        if recovery.dayIntake?.hasPostMeal == true {
            // analysis.js:211
            rest.append("练后餐已经吃上了 ✓ 恢复的开局很好，接下来把睡眠守住就行。")
        }
        rest.append("今晚睡够 7–9 小时，肌肉修复的大头在深睡期"
            + (legsHeavy ? "；练腿日晚上腿胀的话可以把脚垫高一会儿。" : "。"))
        if domsLevel == .noticeable || domsLevel == .severe {
            rest.append("明天做 10–15 分钟低强度活动（快走、轻松单车）加 5–10 分钟"
                + (primaryLabels.isEmpty ? "目标肌群" : primaryLabels) + "静态拉伸或泡沫轴放松，比完全躺平恢复更快。")
        } else {
            rest.append("明天对" + (primaryLabels.isEmpty ? "目标肌群" : primaryLabels) + "做 5–10 分钟拉伸放松，保持活动量即可。")
        }
        rest.append("24 小时内避免同部位二次大强度训练和过量饮酒，两者都会明显拖慢恢复。")
        if !prs.isEmpty {
            rest.append("今天有 \(prs.count) 项个人纪录进账，神经系统消耗比平时大，接下来 1–2 天可以顺势降一点量。")
        }

        // —— 简评（analysis.js:221-263）——
        var brief: [String] = []
        brief.append("本次以\(primaryLabels)为主"
            + (secondaryLabels.isEmpty ? "" : "、\(secondaryLabels)为辅")
            + "，共 \(workout.entries.count) 个动作、\(stats.setCount) 组"
            + (stats.tonnage > 0 ? "、总容量 \(fmtLoad(stats.tonnage))" : "") + "。")
        let displayName = { (id: String) -> String in
            ExerciseLibrary.resolve(exerciseID: id, customExercises: customExercises)?.name ?? id
        }
        let refreshed = prs.filter { !$0.isNewBaseline }
        let firsts = prs.filter { $0.isNewBaseline }
        let quality: String
        if prs.count >= 2 {
            var s = ""
            if !refreshed.isEmpty {
                s += "强度上得很足，\(refreshed.map { displayName($0.exerciseID) }.joined(separator: "、")) 刷新了你的历史最好水平（估算1RM），状态在线。"
            }
            if !firsts.isEmpty {
                s += "\(firsts.map { displayName($0.exerciseID) }.joined(separator: "、")) 为首次记录，从今天起有了对照基准。"
            }
            quality = s
        } else if prs.count == 1 {
            let p = prs[0]
            quality = p.isNewBaseline
                ? "其中 \(displayName(p.exerciseID)) 是首次记录（估算1RM \(fmtLoad(p.bestE1RM))），以后就以它为基准看进步。"
                : "其中 \(displayName(p.exerciseID)) 刷新了历史最好（估算1RM \(fmtLoad(p.bestE1RM))），这个部位的力量正在往上走。"
        } else if intensityBand == .high {
            quality = "负荷已经贴近你的最好水平，动作质量保持住的话进步会很快。"
        } else if intensityBand == .moderate || intensityBand == .moderatelyHigh {
            quality = "负荷中等，是一次扎实的积累型训练。"
        } else {
            quality = "负荷偏轻，如果是主动恢复或技术打磨没问题，正式课可以再加点重量。"
        }
        brief.append(quality)
        // 课内结构（analysis.js:243-257）
        if let g0 = stats.groups.first, g0.share > 0.65, stats.groups.count > 1 {
            let tips: [StructuralGroup: String] = [
                .push: "如果长期这样排，肩后侧和背会相对落后，下次课可以补一个拉类动作。",
                .pull: "推类占比偏低，胸肩的刺激这周记得找补回来。",
                .legs: "这次几乎是纯下肢日，上肢安排在别的日子即可，注意 48 小时内别再排腿。",
                .core: "核心占比很高，记得它更多是「辅助强健」，大肌群的容量也要跟上。",
                .cardio: "有氧占绝对主导，力量刺激这周记得安排上。",
            ]
            brief.append("动作结构上\(g0.label)占比 \(Int((g0.share * 100).rounded()))%。" + (tips[g0.key] ?? ""))
        } else if stats.groups.count >= 2 {
            brief.append("课内推/拉/腿分布相对均衡，是一次结构健康的训练。")
        } else if let g0 = stats.groups.first, workout.entries.count >= 2 {
            brief.append("这次是专注\(g0.label)的单部位课，同类动作排在一起、组间休息控制在 1–2 分钟，泵感和刺激都会更完整。")
        }
        if let v = volumeVsRecentAverage {
            let p = Int((v * 100).rounded())
            if p >= 115 {
                brief.append("总容量约为近几次平均的 \(p)%，比平时大不少，接下来一两天重点做好恢复。")
            } else if p <= 70 {
                brief.append("总容量约为近几次平均的 \(p)%，明显偏轻——如果是减载周那正好，不是的话下次可以加量。")
            }
        }
        if let minutes = recovery.fitnessTimeMinutes, minutes > 0 {
            // analysis.js:263：时间×训练联动（RecoveryContext.fitnessTimeMinutes）
            brief.append("算上热身、整理等前后投入，今天为这次训练总共花掉 \(Formatting.duration(minutes: minutes))。")
        }

        return WorkoutAnalysisSnapshot(
            brief: brief,
            postFeel: postFeel,
            nextDayText: nextDayText,
            domsLevel: domsLevel,
            diet: diet,
            rest: rest,
            prs: prs,
            muscleVolume: Dictionary(uniqueKeysWithValues: stats.muscles.map { ($0.key, $0.volume) }),
            groupSets: Dictionary(uniqueKeysWithValues: stats.groups.map { ($0.key, $0.setCount) }),
            totals: WorkoutTotals(setCount: stats.setCount,
                                  repCount: stats.repCount,
                                  volumeKg: stats.tonnage),
            intensityBand: intensityBand,
            volumeVsRecentAverage: volumeVsRecentAverage,
            primaryMuscles: primary.map(\.key),
            secondaryMuscles: secondary.map(\.key),
            ai: nil)
    }

    // MARK: - 文案数据（analysis.js:158-171 feelMap 原文）

    private static let postFeelText: [MuscleGroup: String] = [
        .chest: "胸口会明显充血发胀，推到最后几组手臂打颤属正常",
        .back: "背部整体紧绷、肩胛周围酸胀，握力通常先于背力耗尽",
        .shoulder: "肩部酸胀明显，手臂过头会感觉吃力，暂时别提重物",
        .biceps: "手臂泵感强，屈肘到位时上臂前侧发僵",
        .triceps: "手臂后侧发胀，伸肘发力时酸感清晰",
        .forearm: "前臂和握力酸胀明显，抓握会短暂受影响",
        .quad: "大腿前侧发胀发软，起身、下蹲会明显吃力",
        .hamstring: "大腿后侧紧绷，弯腰和蹬地时酸感明显",
        .glute: "臀部酸胀，坐硬凳子会有感觉",
        .calf: "小腿发胀，踮脚时酸感清晰",
        .core: "腹部发紧发酸，咳嗽、大笑、起身时核心存在感很强",
        .full: "心率回落后疲惫与轻松并存，大量出汗后记得补水",
    ]

    /// 重量展示（lifttime util.js fmtLoad 的 kg 分支：0.1 精度、去尾 0；
    /// 非正值 → 自重）。
    static func fmtLoad(_ kg: Double) -> String {
        guard kg > 0 else { return "自重" }
        let v = (kg * 10).rounded() / 10
        return v == v.rounded() ? "\(Int(v))kg" : String(format: "%.1f", v) + "kg"
    }

    /// 体重展示（整数直出、小数去尾 0，与 fmtLoad 同规则）。
    static func fmtBodyweight(_ kg: Double) -> String {
        kg == kg.rounded() ? "\(Int(kg))" : String(format: "%.1f", kg)
    }
}

// MARK: - 统计值类型

/// 每个动作的最好一组（lifttime topSets.best）。
public struct BestSetInfo: Codable, Sendable, Equatable {
    public var weightKg: Double
    public var reps: Int
    public var e1RM: Double

    public init(weightKg: Double, reps: Int, e1RM: Double) {
        self.weightKg = weightKg
        self.reps = reps
        self.e1RM = e1RM
    }
}

/// 每动作统计（lifttime topSets 元素）。
public struct TopSetStat: Codable, Sendable, Equatable, Identifiable {
    public var id: String { exerciseID }
    public var exerciseID: String
    public var displayName: String
    public var setCount: Int
    public var repCount: Int
    public var tonnage: Double
    public var best: BestSetInfo?

    public init(exerciseID: String,
                displayName: String,
                setCount: Int,
                repCount: Int,
                tonnage: Double,
                best: BestSetInfo?) {
        self.exerciseID = exerciseID
        self.displayName = displayName
        self.setCount = setCount
        self.repCount = repCount
        self.tonnage = tonnage
        self.best = best
    }
}

/// 单肌群统计（lifttime muscles 元素；sets/reps 为分摊值故为 Double）。
public struct MuscleStat: Codable, Sendable, Equatable {
    public var key: MuscleGroup
    public var label: String
    public var group: StructuralGroup
    public var volume: Double
    public var sets: Double
    public var reps: Double
    public var share: Double

    public init(key: MuscleGroup,
                label: String,
                group: StructuralGroup,
                volume: Double,
                sets: Double,
                reps: Double,
                share: Double) {
        self.key = key
        self.label = label
        self.group = group
        self.volume = volume
        self.sets = sets
        self.reps = reps
        self.share = share
    }
}

/// 单结构组统计（lifttime groups 元素）。
public struct GroupStat: Codable, Sendable, Equatable, Identifiable {
    public var id: String { key.rawValue }
    public var key: StructuralGroup
    public var label: String
    public var volume: Double
    public var setCount: Int
    public var share: Double

    public init(key: StructuralGroup,
                label: String,
                volume: Double,
                setCount: Int,
                share: Double) {
        self.key = key
        self.label = label
        self.volume = volume
        self.setCount = setCount
        self.share = share
    }
}

/// 一次训练的统计汇总（lifttime sessionStats 返回值）。
public struct SessionStats: Codable, Sendable, Equatable {
    public var tonnage: Double
    public var setCount: Int
    public var repCount: Int
    public var muscles: [MuscleStat]
    public var groups: [GroupStat]
    public var topSets: [TopSetStat]
    public var eccentricSetCount: Int
    public var cardioSetCount: Int
    public var bodyweightSetCount: Int

    public init(tonnage: Double = 0,
                setCount: Int = 0,
                repCount: Int = 0,
                muscles: [MuscleStat] = [],
                groups: [GroupStat] = [],
                topSets: [TopSetStat] = [],
                eccentricSetCount: Int = 0,
                cardioSetCount: Int = 0,
                bodyweightSetCount: Int = 0) {
        self.tonnage = tonnage
        self.setCount = setCount
        self.repCount = repCount
        self.muscles = muscles
        self.groups = groups
        self.topSets = topSets
        self.eccentricSetCount = eccentricSetCount
        self.cardioSetCount = cardioSetCount
        self.bodyweightSetCount = bodyweightSetCount
    }
}
