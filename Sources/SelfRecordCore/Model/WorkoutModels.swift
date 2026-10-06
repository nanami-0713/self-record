import Foundation

// MARK: - 训练（design.md §4）

/// 12 肌群 key + 5 结构组（对应 lifttime exercises.js:4-25 的口径）
public enum MuscleGroup: String, Codable, Sendable, CaseIterable, Hashable {
    case chest, shoulder, triceps, back, biceps, forearm
    case quad, hamstring, glute, calf, core, full
}

public enum StructuralGroup: String, Codable, Sendable, CaseIterable, Hashable {
    case push, pull, legs, core, cardio
}

public struct Exercise: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String                         // 内置动作固定 key；自定义=UUID 字符串
    public var name: String
    public var aliases: [String]
    public var primaryMuscles: [MuscleGroup]      // 主肌群
    public var secondaryMuscles: [MuscleGroup]    // 次肌群
    public var isCustom: Bool
    public var isBodyweight: Bool                 // 自重：容量记 0、组数计入
    public var isCardio: Bool
    public var isEccentricHeavy: Bool             // 离心大：DOMS +1

    public init(id: String,
                name: String,
                aliases: [String] = [],
                primaryMuscles: [MuscleGroup] = [],
                secondaryMuscles: [MuscleGroup] = [],
                isCustom: Bool = false,
                isBodyweight: Bool = false,
                isCardio: Bool = false,
                isEccentricHeavy: Bool = false) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.isCustom = isCustom
        self.isBodyweight = isBodyweight
        self.isCardio = isCardio
        self.isEccentricHeavy = isEccentricHeavy
    }

    enum CodingKeys: String, CodingKey {
        case id, name, aliases, primaryMuscles, secondaryMuscles
        case isCustom, isBodyweight, isCardio, isEccentricHeavy
    }

    /// 宽松解码（§4 管线 2）：布尔缺 key 归 false、数组缺 key 归空——
    /// 自定义动作库与内置库新旧版本字段演进不炸导入。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        aliases = (try? c.decodeIfPresent([String].self, forKey: .aliases)) ?? []
        primaryMuscles = (try? c.decodeIfPresent([MuscleGroup].self, forKey: .primaryMuscles)) ?? []
        secondaryMuscles = (try? c.decodeIfPresent([MuscleGroup].self, forKey: .secondaryMuscles)) ?? []
        isCustom = (try? c.decodeIfPresent(Bool.self, forKey: .isCustom)) ?? false
        isBodyweight = (try? c.decodeIfPresent(Bool.self, forKey: .isBodyweight)) ?? false
        isCardio = (try? c.decodeIfPresent(Bool.self, forKey: .isCardio)) ?? false
        isEccentricHeavy = (try? c.decodeIfPresent(Bool.self, forKey: .isEccentricHeavy)) ?? false
    }
}

public struct WorkoutSet: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var weightKg: Double                   // 0 = 自重/无重量（净化收敛非负）
    public var reps: Int                          // 净化收敛非负
    public var timestamp: Date

    public init(id: UUID = UUID(),
                weightKg: Double,
                reps: Int,
                timestamp: Date) {
        self.id = id
        self.weightKg = weightKg
        self.reps = reps
        self.timestamp = timestamp
    }
}

public struct WorkoutExerciseEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var exerciseID: String
    public var sets: [WorkoutSet]

    public init(id: UUID = UUID(),
                exerciseID: String,
                sets: [WorkoutSet] = []) {
        self.id = id
        self.exerciseID = exerciseID
        self.sets = sets
    }
}

/// 进行中训练（落盘，崩溃恢复）。
public struct ActiveWorkout: Codable, Sendable, Equatable {
    public var id: UUID
    public var startedAt: Date
    public var entries: [WorkoutExerciseEntry]
    public var notes: String?

    public init(id: UUID = UUID(),
                startedAt: Date,
                entries: [WorkoutExerciseEntry] = [],
                notes: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.entries = entries
        self.notes = notes
    }
}

public struct Workout: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var entries: [WorkoutExerciseEntry]
    public var feeling: Int?                      // 1–5
    public var notes: String?
    public var analysis: WorkoutAnalysisSnapshot? // 生成时冻结的快照；详情页可再生成

    public init(id: UUID = UUID(),
                startedAt: Date,
                endedAt: Date,
                entries: [WorkoutExerciseEntry] = [],
                feeling: Int? = nil,
                notes: String? = nil,
                analysis: WorkoutAnalysisSnapshot? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.entries = entries
        self.feeling = feeling
        self.notes = notes
        self.analysis = analysis
    }
}

// MARK: - 训练分析快照（规则版结构 = 未来 AI 输出契约 = 渲染契约）

public enum DOMSLevel: String, Codable, Sendable {
    case severe, noticeable, moderate, mild
}

public enum IntensityBand: String, Codable, Sendable {
    case high, moderatelyHigh, moderate, light
}

public struct WorkoutTotals: Codable, Sendable, Equatable {
    public var setCount: Int
    public var repCount: Int
    public var volumeKg: Double                   // 自重动作贡献 0

    public init(setCount: Int = 0, repCount: Int = 0, volumeKg: Double = 0) {
        self.setCount = setCount
        self.repCount = repCount
        self.volumeKg = volumeKg
    }
}

public struct PRRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { exerciseID }
    public var exerciseID: String
    public var bestE1RM: Double
    public var isNewBaseline: Bool                // true=首次基准（prev=0），false=刷新纪录

    public init(exerciseID: String, bestE1RM: Double, isNewBaseline: Bool) {
        self.exerciseID = exerciseID
        self.bestE1RM = bestE1RM
        self.isNewBaseline = isNewBaseline
    }
}

/// AI 覆写标记（后置启用，§9-5）
public struct AICredit: Codable, Sendable, Equatable {
    public var model: String
    public var effort: AIEffort
    public var generatedAt: Date

    public init(model: String, effort: AIEffort, generatedAt: Date) {
        self.model = model
        self.effort = effort
        self.generatedAt = generatedAt
    }
}

public struct WorkoutAnalysisSnapshot: Codable, Sendable, Equatable {
    public var brief: [String]                    // 简评要点
    public var postFeel: [String]                 // 练后感受建议
    public var nextDayText: String                // 次日预期（DOMS 文案）
    public var domsLevel: DOMSLevel
    public var diet: [String]                     // 恢复饮食建议（读注入的实际蛋白摄入）
    public var rest: [String]
    public var prs: [PRRecord]
    public var muscleVolume: [MuscleGroup: Double]  // 分摊后容量
    public var groupSets: [StructuralGroup: Int]
    public var totals: WorkoutTotals
    public var intensityBand: IntensityBand
    public var volumeVsRecentAverage: Double?     // vs 近 5 次均值
    public var primaryMuscles: [MuscleGroup]
    public var secondaryMuscles: [MuscleGroup]
    public var ai: AICredit?                      // 非 nil=AI 覆写过

    public init(brief: [String] = [],
                postFeel: [String] = [],
                nextDayText: String = "",
                domsLevel: DOMSLevel = .mild,
                diet: [String] = [],
                rest: [String] = [],
                prs: [PRRecord] = [],
                muscleVolume: [MuscleGroup: Double] = [:],
                groupSets: [StructuralGroup: Int] = [:],
                totals: WorkoutTotals = WorkoutTotals(),
                intensityBand: IntensityBand = .light,
                volumeVsRecentAverage: Double? = nil,
                primaryMuscles: [MuscleGroup] = [],
                secondaryMuscles: [MuscleGroup] = [],
                ai: AICredit? = nil) {
        self.brief = brief
        self.postFeel = postFeel
        self.nextDayText = nextDayText
        self.domsLevel = domsLevel
        self.diet = diet
        self.rest = rest
        self.prs = prs
        self.muscleVolume = muscleVolume
        self.groupSets = groupSets
        self.totals = totals
        self.intensityBand = intensityBand
        self.volumeVsRecentAverage = volumeVsRecentAverage
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.ai = ai
    }
}
