import Foundation

// MARK: - 内置动作库（design.md §3.3 / §8 约定 8）
//
// 数据源 = lifttime js/exercises.js 的 EXERCISE_DB（107 项）全量移植，
// 另补 5 个常见动作补足 110+（共 112 项）。以 Swift 静态数组源码形式放本模块，
// 可编译期检查、可测试，不做资源文件。
//
// 内置动作的 `id` = 规范中文名（「内置动作固定 key」，Model/WorkoutModels.swift
// Exercise.id 注释）；自定义动作 id = UUID 字符串，两套 id 天然不冲突。
//
// 肌群 → 结构组映射（exercises.js MUSCLES）：
//   push = chest/shoulder/triceps；pull = back/biceps/forearm；
//   legs = quad/hamstring/glute/calf；core = core；cardio = full。

/// 动作库与名称匹配（design.md §3.3：自定义 → 精确名 → 精确别名 → 双向包含；
/// 搜索按精确/前缀/包含打分，对应 lifttime exercises.js:148-207）。
public enum ExerciseLibrary {

    /// 12 肌群中文标签（exercises.js:4-17 MUSCLES.label）。
    public static func muscleLabel(_ muscle: MuscleGroup) -> String {
        switch muscle {
        case .chest: return "胸"
        case .shoulder: return "肩"
        case .triceps: return "肱三头"
        case .back: return "背"
        case .biceps: return "肱二头"
        case .forearm: return "前臂"
        case .quad: return "股四头"
        case .hamstring: return "腘绳肌"
        case .glute: return "臀"
        case .calf: return "小腿"
        case .core: return "核心"
        case .full: return "全身"
        }
    }

    /// 肌群 → 结构组（exercises.js:211 groupOfMuscle；12 肌群全覆盖）。
    public static func groupOfMuscle(_ muscle: MuscleGroup) -> StructuralGroup {
        switch muscle {
        case .chest, .shoulder, .triceps: return .push
        case .back, .biceps, .forearm: return .pull
        case .quad, .hamstring, .glute, .calf: return .legs
        case .core: return .core
        case .full: return .cardio
        }
    }

    /// 5 结构组中文标签（exercises.js:19-25 GROUPS.label）。
    public static func groupLabel(_ group: StructuralGroup) -> String {
        switch group {
        case .push: return "推类(胸肩三头)"
        case .pull: return "拉类(背二头)"
        case .legs: return "腿臀"
        case .core: return "核心"
        case .cardio: return "有氧/全身"
        }
    }

    /// 内置动作库（112 项 = lifttime 107 项全量 + 5 项补足）。
    public static let all: [Exercise] = builtIn

    /// id → 动作索引（O(1) 解析）。
    public static let byID: [String: Exercise] = Dictionary(
        uniqueKeysWithValues: builtIn.map { ($0.id, $0) }
    )

    /// 按 id 解析动作：内置库 → 自定义库（分析路径用；entry 里存的是 exerciseID）。
    public static func resolve(exerciseID: String, customExercises: [Exercise]) -> Exercise? {
        if let built = byID[exerciseID] { return built }
        return customExercises.first { $0.id == exerciseID }
    }

    /// 按名称找动作。匹配顺序（design.md §3.3，对应 exercises.js:152-163
    /// findInDB + resolveExercise 的 custom 优先）：
    /// 自定义精确名 → 内置精确名 → 内置精确别名 → 名称双向包含 → 别名双向包含。
    public static func find(name: String, customExercises: [Exercise]) -> Exercise? {
        let q = norm(name)
        guard !q.isEmpty else { return nil }
        if let custom = customExercises.first(where: { norm($0.name) == q }) { return custom }
        if let exact = builtIn.first(where: { norm($0.name) == q }) { return exact }
        if let alias = builtIn.first(where: { $0.aliases.contains { norm($0) == q } }) { return alias }
        if let contains = builtIn.first(where: {
            let n = norm($0.name); return n.contains(q) || q.contains(n)
        }) { return contains }
        return builtIn.first { ex in
            ex.aliases.contains { al in
                let n = norm(al); return n.contains(q) || q.contains(n)
            }
        }
    }

    /// 搜索动作（选择器用；lifttime exercises.js:186-207 searchExercises）。
    /// 打分：精确 100 / 前缀 80 / 包含 60 / 被包含 40；同分自定义在前。
    /// 空查询返回前 limit 个（内置在前）。
    public static func search(_ query: String,
                              limit: Int = 40,
                              customExercises: [Exercise] = []) -> [Exercise] {
        guard !query.isEmpty else {
            return Array(builtIn.prefix(limit))
        }
        let nq = norm(query)
        guard !nq.isEmpty else { return Array(builtIn.prefix(limit)) }
        var scored: [(score: Int, isCustom: Bool, index: Int, exercise: Exercise)] = []
        func scoreCandidates(_ list: [Exercise], isCustom: Bool) {
            for (i, e) in list.enumerated() {
                var best = -1
                for nm in [e.name] + e.aliases {
                    let n = norm(nm)
                    var sc = -1
                    if n == nq { sc = 100 }
                    else if n.hasPrefix(nq) { sc = 80 }
                    else if n.contains(nq) { sc = 60 }
                    else if nq.contains(n) { sc = 40 }
                    if sc > best { best = sc }
                }
                if best > 0 { scored.append((best, isCustom, i, e)) }
            }
        }
        scoreCandidates(customExercises, isCustom: true)
        scoreCandidates(builtIn, isCustom: false)
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.isCustom != rhs.isCustom { return lhs.isCustom }
            return lhs.index < rhs.index
        }
        return scored.prefix(limit).map(\.exercise)
    }

    /// 归一化名称用于匹配（exercises.js:149 norm）：去所有空白 + 小写。
    static func norm(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace }).lowercased()
    }
}

// MARK: - 数据（lifttime EXERCISE_DB 全量移植 + 补足 5 项）

private let builtIn: [Exercise] = {
    func lib(_ name: String,
             _ aliases: [String],
             _ primary: [MuscleGroup],
             _ secondary: [MuscleGroup],
             bodyweight: Bool = false,
             cardio: Bool = false,
             eccentric: Bool = false) -> Exercise {
        Exercise(id: name, name: name, aliases: aliases, primaryMuscles: primary,
                 secondaryMuscles: secondary, isCustom: false,
                 isBodyweight: bodyweight, isCardio: cardio, isEccentricHeavy: eccentric)
    }
    return [
        // —— 胸 ——
        lib("卧推", ["杠铃卧推", "平板卧推", "哑铃卧推", "bench press"], [.chest], [.triceps, .shoulder]),
        lib("上斜卧推", ["上斜杠铃卧推", "上斜哑铃卧推"], [.chest], [.shoulder, .triceps]),
        lib("下斜卧推", [], [.chest], [.triceps]),
        lib("夹胸", ["蝴蝶机夹胸", "绳索夹胸", "龙门架夹胸"], [.chest], []),
        lib("俯卧撑", ["标准俯卧撑"], [.chest], [.triceps, .core], bodyweight: true),
        lib("双杠臂屈伸", ["双杠"], [.chest, .triceps], [.shoulder], bodyweight: true, eccentric: true),
        // —— 背 ——
        lib("引体向上", ["正手引体", "chin up"], [.back, .biceps], [.forearm], bodyweight: true, eccentric: true),
        lib("高位下拉", ["坐姿下拉"], [.back], [.biceps]),
        lib("杠铃划船", ["俯身划船", "barbell row"], [.back], [.biceps, .hamstring]),
        lib("坐姿划船", ["器械划船", "绳索划船"], [.back], [.biceps]),
        lib("单臂哑铃划船", ["单边划船"], [.back], [.biceps]),
        lib("直臂下压", ["直臂下拉"], [.back], []),
        lib("硬拉", ["deadlift"], [.back, .hamstring], [.glute, .quad, .forearm], eccentric: true),
        lib("罗马尼亚硬拉", ["RDL"], [.hamstring, .glute], [.back], eccentric: true),
        lib("面拉", ["face pull"], [.back, .shoulder], []),
        // —— 肩 ——
        lib("推举", ["肩推", "杠铃推举", "哑铃推举", "军推", "实力举"], [.shoulder], [.triceps]),
        lib("阿诺德推举", [], [.shoulder], [.triceps]),
        lib("侧平举", ["哑铃侧平举"], [.shoulder], []),
        lib("前平举", [], [.shoulder], []),
        lib("反向飞鸟", ["俯身飞鸟", "后束飞鸟"], [.shoulder], [.back]),
        lib("耸肩", ["哑铃耸肩"], [.back], [.forearm]),
        // —— 手臂 ——
        lib("弯举", ["杠铃弯举", "哑铃弯举", "站姿弯举"], [.biceps], [.forearm]),
        lib("锤式弯举", [], [.biceps, .forearm], []),
        lib("牧师弯举", ["斜板弯举"], [.biceps], []),
        lib("绳索弯举", [], [.biceps], [.forearm]),
        lib("窄距卧推", ["窄握卧推"], [.triceps], [.chest]),
        lib("绳索下压", ["三头下压", "器械下压"], [.triceps], []),
        lib("仰卧臂屈伸", ["skull crusher", "碎颅式"], [.triceps], []),
        lib("过头臂屈伸", ["哑铃颈后臂屈伸"], [.triceps], [.shoulder]),
        lib("腕弯举", ["前臂弯举"], [.forearm], []),
        // —— 腿臀 ——
        lib("深蹲", ["杠铃深蹲", "后蹲", "squat"], [.quad, .glute], [.hamstring, .core], eccentric: true),
        lib("前蹲", ["前深蹲"], [.quad], [.core], eccentric: true),
        lib("腿举", ["倒蹬", "leg press"], [.quad, .glute], [.hamstring]),
        lib("哈克深蹲", ["hack squat"], [.quad], [.glute]),
        lib("保加利亚分腿蹲", ["保加利亚蹲"], [.quad, .glute], [.hamstring], eccentric: true),
        lib("箭步蹲", ["弓步蹲", "行走箭步蹲"], [.quad, .glute], [.hamstring], eccentric: true),
        lib("腿屈伸", ["坐姿屈膝伸腿"], [.quad], []),
        lib("腿弯举", ["俯卧腿弯举"], [.hamstring], [.calf]),
        lib("臀桥", ["髋推", "臀推"], [.glute], [.hamstring]),
        lib("提踵", ["站姿提踵", "坐姿提踵"], [.calf], []),
        // —— 核心 ——
        lib("平板支撑", ["plank"], [.core], [.shoulder], bodyweight: true),
        lib("卷腹", ["仰卧起坐"], [.core], [], bodyweight: true),
        lib("悬垂举腿", ["举腿"], [.core], [.forearm], bodyweight: true),
        lib("俄罗斯转体", [], [.core], [], bodyweight: true),
        lib("健腹轮", ["腹轮"], [.core], [.shoulder], bodyweight: true),
        // —— 有氧 / 全身 ——
        lib("跑步", ["慢跑", "跑步机"], [.full], [.quad, .calf], bodyweight: true, cardio: true),
        lib("快走", [], [.full], [], bodyweight: true, cardio: true),
        lib("椭圆机", [], [.full], [], bodyweight: true, cardio: true),
        lib("划船机", ["赛艇机"], [.full], [.back, .quad], bodyweight: true, cardio: true),
        lib("骑行", ["动感单车", "自行车"], [.full], [.quad], bodyweight: true, cardio: true),
        lib("跳绳", [], [.full], [.calf], bodyweight: true, cardio: true),
        lib("游泳", [], [.full], [.back], bodyweight: true, cardio: true),
        lib("波比跳", ["burpee"], [.full], [.chest, .quad], bodyweight: true, cardio: true),
        lib("HIIT", ["高强度间歇"], [.full], [], bodyweight: true, cardio: true),
        // —— 扩充：器械与变式 ——
        lib("坐姿推胸机", ["器械推胸", "坐姿推胸"], [.chest], [.triceps]),
        lib("史密斯卧推", ["史密斯架卧推"], [.chest], [.triceps, .shoulder]),
        lib("上斜器械推胸", [], [.chest], [.shoulder, .triceps]),
        lib("龙门架飞鸟", ["绳索飞鸟"], [.chest], []),
        lib("史密斯深蹲", [], [.quad, .glute], [.hamstring, .core], eccentric: true),
        lib("箱式深蹲", ["箱子深蹲"], [.quad, .glute], [.hamstring], eccentric: true),
        lib("泽奇深蹲", [], [.quad, .core], [.glute], eccentric: true),
        lib("相扑硬拉", [], [.glute, .hamstring], [.back, .quad], eccentric: true),
        lib("直腿硬拉", [], [.hamstring], [.back, .glute], eccentric: true),
        lib("六角杠硬拉", ["陷阱杠硬拉"], [.quad, .back], [.glute, .hamstring], eccentric: true),
        lib("单腿硬拉", [], [.hamstring, .glute], [.core], eccentric: true),
        lib("山羊挺身", ["罗马椅挺身", "背部伸展"], [.back, .hamstring], [.glute], eccentric: true),
        lib("早安式", ["早安深蹲"], [.hamstring, .back], [.glute], eccentric: true),
        lib("坐姿髋外展", ["腿外展机", "髋外展"], [.glute], []),
        lib("坐姿髋内收", ["腿内收机", "髋内收"], [.quad], [.glute]),
        lib("T杠划船", ["T形划船"], [.back], [.biceps]),
        lib("辅助引体机", ["辅助引体"], [.back, .biceps], [.forearm]),
        lib("TRX划船", [], [.back], [.biceps, .core], bodyweight: true),
        lib("TRX俯卧撑", [], [.chest, .core], [.triceps], bodyweight: true),
        lib("高位下压", [], [.back], [.triceps]),
        lib("器械推举", ["坐姿推肩机"], [.shoulder], [.triceps]),
        lib("颈后推举", [], [.shoulder], [.triceps]),
        lib("借力推举", ["挺举推"], [.shoulder, .full], [.quad, .triceps]),
        lib("反向蝴蝶机", ["器械反向飞鸟"], [.shoulder], [.back]),
        lib("集中弯举", [], [.biceps], []),
        lib("佐特曼弯举", [], [.biceps, .forearm], []),
        lib("反握弯举", [], [.forearm, .biceps], []),
        lib("哑铃臂屈伸", [], [.triceps], []),
        // —— 核心与功能 ——
        lib("侧平板支撑", ["侧桥"], [.core], [.shoulder], bodyweight: true),
        lib("死虫式", ["死虫"], [.core], [], bodyweight: true),
        lib("鸟狗式", ["鸟狗"], [.core], [.glute], bodyweight: true),
        lib("空中蹬车", ["空中自行车"], [.core], [], bodyweight: true),
        lib("反向卷腹", [], [.core], [], bodyweight: true),
        lib("仰卧抬腿", ["仰卧举腿"], [.core], [], bodyweight: true),
        lib("V字支撑", ["V字两头起"], [.core], [], bodyweight: true),
        lib("农夫行走", ["农夫走"], [.forearm, .core], [.back, .full]),
        lib("壶铃摇摆", ["壶铃摆动"], [.hamstring, .glute], [.core, .shoulder], eccentric: true),
        lib("跳箱", ["跳箱子上"], [.quad, .glute], [.calf], bodyweight: true),
        lib("高翻", ["翻铃"], [.full], [.back, .quad, .shoulder]),
        lib("抓举", [], [.full], [.shoulder, .quad, .back]),
        // —— 有氧补充 ——
        lib("爬楼梯机", ["登山机", "楼梯机"], [.full], [.quad, .glute], bodyweight: true, cardio: true),
        lib("开合跳", [], [.full], [], bodyweight: true, cardio: true),
        lib("高抬腿", [], [.full], [.quad], bodyweight: true, cardio: true),
        lib("登山跑", ["登山者"], [.core, .full], [.shoulder], bodyweight: true, cardio: true),
        lib("战绳", ["甩绳"], [.full, .shoulder], [.core], bodyweight: true, cardio: true),
        lib("滑雪机", [], [.full], [.back], bodyweight: true, cardio: true),
        lib("瑜伽", ["瑜伽课"], [.full], [.core], bodyweight: true, cardio: true),
        lib("普拉提", [], [.core, .full], [], bodyweight: true),
        lib("徒步", ["爬山"], [.full], [.quad], bodyweight: true, cardio: true),
        lib("篮球", [], [.full], [], bodyweight: true, cardio: true),
        lib("羽毛球", [], [.full], [], bodyweight: true, cardio: true),
        lib("足球", [], [.full], [.quad], bodyweight: true, cardio: true),
        lib("网球", [], [.full], [], bodyweight: true, cardio: true),
        // —— 补足 110+（lifttime 之外新增，避开既有精确名/别名冲突）——
        lib("悬垂划船", [], [.back, .biceps], [.core], bodyweight: true, eccentric: true),
        lib("倒立撑", ["靠墙倒立撑"], [.shoulder], [.triceps], bodyweight: true),
        lib("派克俯卧撑", [], [.shoulder], [.chest, .triceps], bodyweight: true),
        lib("登台阶", ["箱式登台阶"], [.quad, .glute], [.hamstring], eccentric: true),
        lib("单腿提踵", [], [.calf], [], bodyweight: true),
    ]
}()
