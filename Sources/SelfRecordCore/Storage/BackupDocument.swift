import Foundation

// MARK: - 备份（导出/导入契约，design.md §4 末；实现位置裁决见 §12）

/// 全量备份文档。apiKey 永不出现；导入时全字段过 `BackupSanitizer`。
/// 类型定义放 `Storage/`（§3.0 Storage 职责行、§8 目录树注释）。
public struct BackupDocument: Codable, Sendable, Equatable {
    public var version: String                    // "selfrecord.v1"
    public var exportedAt: Date
    public var settings: AppSettings
    public var categories: [TimeCategory]
    public var timeBlocks: [TimeBlock]
    public var sleepSessions: [SleepSession]
    public var workouts: [Workout]
    public var customExercises: [Exercise]
    public var dietEntries: [DietEntry]
    public var expenses: [Expense]
    public var customFoods: [CustomFood]           // §4 净化语义修正：必须保留（lifttime sanitizeState 丢此域是已知缺陷，不复刻）

    public static let currentVersion = "selfrecord.v1"

    public init(version: String = BackupDocument.currentVersion,
                exportedAt: Date,
                settings: AppSettings,
                categories: [TimeCategory],
                timeBlocks: [TimeBlock],
                sleepSessions: [SleepSession],
                workouts: [Workout],
                customExercises: [Exercise],
                dietEntries: [DietEntry],
                expenses: [Expense],
                customFoods: [CustomFood]) {
        self.version = version
        self.exportedAt = exportedAt
        self.settings = settings
        self.categories = categories
        self.timeBlocks = timeBlocks
        self.sleepSessions = sleepSessions
        self.workouts = workouts
        self.customExercises = customExercises
        self.dietEntries = dietEntries
        self.expenses = expenses
        self.customFoods = customFoods
    }
}

/// active.json 的落盘形状（§5：崩溃恢复态 `ActiveTimer? + ActiveWorkout?`，启动即读）。
/// 存储层私有形状，不属于领域模型。
public struct ActiveStateRecord: Codable, Sendable, Equatable {
    public var timer: ActiveTimer?
    public var workout: ActiveWorkout?

    public init(timer: ActiveTimer? = nil, workout: ActiveWorkout? = nil) {
        self.timer = timer
        self.workout = workout
    }
}
