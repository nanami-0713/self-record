import Testing
import Foundation
@testable import SelfRecordCore

// MARK: - time-tracking 模块测试（design.md §3.1 / §10 测试清单）
//
// lifttime 时间模块无专属测试基线，自建用例：计时器互斥与恢复、end>start 校验、
// 跨午夜日聚合、近 7/30 逐日聚合、分类删除/归档归并到 isFallback、引用完整性
// + 移植 store.test.mjs:42-44 的 timer 断言语义（睡眠计时器保留 kind；
// 旧数据无 kind 归 general——基础层解码行为已在
// ModelSanitizeTests.legacyTimerWithoutKindDecodesAsGeneral 覆盖，此处为模块层移植）。
// 时间锚定 UTC+8（§8 约定 2）；构造日期一律走 DayCalendar.utc8()，不依赖宿主时区。

// MARK: 工具

private let cal = DayCalendar.utc8()

/// UTC+8 时区的 y-m-d h:m 时刻（经由注入历法构造，dayKey 往返稳定）。
private func date(_ year: Int, _ month: Int, _ day: Int,
                  _ hour: Int = 0, _ minute: Int = 0) -> Date {
    let key = DayKey(rawValue: String(format: "%04d-%02d-%02d", year, month, day))!
    return cal.date(of: key)!.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
}

private func day(_ raw: String) -> DayKey { DayKey(rawValue: raw)! }

@Suite
struct TimeTrackingModulePlaceholder {

    @Test func frozenSignaturesPresent() {
        // 冻结物 B 签名桩可调用（实现后保留本断言应继续通过；签名不得偏离 §2.1）
        let cal = DayCalendar.utc8()
        let day = DayKey(rawValue: "2026-10-06")!
        #expect(TimeEngine.dayBrief([], day: day, categories: [], calendar: cal) == TimeDayBrief())
        #expect(TimeEngine.dailyBreakdown([], in: DateSpan(startDay: day, endDay: day),
                                          categories: [], calendar: cal).isEmpty)
        #expect(TimeEngine.fitnessMinutes([], day: day, calendar: cal) == 0)
        // FITNESS_CATS = §3.1 冻结集合（lifttime workout.js:12 口径）
        #expect(FITNESS_CATS == ["warmup", "strength", "cardio", "stretch", "shower"])
    }
}

// MARK: - 单槽计时器（互斥 + 崩溃恢复）

@Suite
struct TimerSingleSlot {

    @Test func startFromIdleOccupiesSingleSlot() {
        let start = date(2026, 10, 6, 9, 0)
        let outcome = TimeEngine.startTimer(kind: .general, at: start, current: nil)
        guard case .started(let timer) = outcome else {
            Issue.record("空闲单槽应允许启动，实际 \(outcome)"); return
        }
        #expect(timer == ActiveTimer(startedAt: start, kind: .general))
    }

    @Test func rejectsGeneralStartWhileSleepTiming() {
        // lifttime time.js:86：睡眠计时中拒绝开始日常计时（「睡完再记这段时间」）
        let sleepTimer = ActiveTimer(startedAt: date(2026, 10, 6, 23, 30), kind: .sleep)
        let outcome = TimeEngine.startTimer(kind: .general,
                                            at: date(2026, 10, 6, 23, 40),
                                            current: sleepTimer)
        #expect(outcome == .rejected(occupiedBy: sleepTimer))
    }

    @Test func rejectsSleepStartWhileGeneralTiming() {
        // lifttime sleep.js:107：「已有计时在进行」——反向同样互斥（单槽）
        let generalTimer = ActiveTimer(startedAt: date(2026, 10, 6, 20, 0), kind: .general)
        let outcome = TimeEngine.startTimer(kind: .sleep,
                                            at: date(2026, 10, 6, 22, 0),
                                            current: generalTimer)
        #expect(outcome == .rejected(occupiedBy: generalTimer))
    }

    @Test func stopProducesBlockFromPersistedStartPoint() {
        // 崩溃恢复语义（§11 风险 8）：只存 startedAt 时刻，停止时由 end 重算时长——
        // 中途「重启」不影响产块（09:00 开始，10:30 停止 = 90 分钟）
        let timer = ActiveTimer(startedAt: date(2026, 10, 6, 9, 0), kind: .general)
        let end = date(2026, 10, 6, 10, 30)
        let block = TimeEngine.stopTimer(timer, at: end, categoryID: "strength",
                                         note: "  深蹲日  ", categories: TimeCategory.defaults)
        #expect(block?.start == timer.startedAt)
        #expect(block?.end == end)
        #expect(block?.categoryID == "strength")
        #expect(block?.note == "深蹲日")       // 去首尾空白
    }

    @Test func stopRejectsEndNotAfterStart() {
        let timer = ActiveTimer(startedAt: date(2026, 10, 6, 9, 0), kind: .general)
        #expect(TimeEngine.stopTimer(timer, at: timer.startedAt, categoryID: "strength",
                                     note: nil, categories: TimeCategory.defaults) == nil)
        #expect(TimeEngine.stopTimer(timer, at: timer.startedAt.addingTimeInterval(-10),
                                     categoryID: "strength",
                                     note: nil, categories: TimeCategory.defaults) == nil)
    }

    @Test func activeTimerSurvivesPersistenceForCrashRecovery() async throws {
        // active.json 落盘 → 读回 → 停止产块，端到端恢复路径（§5「启动即读」）
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-time-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try DataStore(directory: dir)

        let start = date(2026, 10, 6, 7, 15)
        guard case .started(let timer) = TimeEngine.startTimer(kind: .sleep, at: start, current: nil) else {
            Issue.record("启动失败"); return
        }
        await store.save(active: ActiveStateRecord(timer: timer))
        await store.flushNow()

        // 「崩溃重启」：内存态丢失，只从盘上恢复
        let restored = await store.loadActive()?.timer
        #expect(restored == timer)

        let block = TimeEngine.stopTimer(restored!, at: date(2026, 10, 6, 15, 45),
                                         categoryID: "commute", note: nil,
                                         categories: TimeCategory.defaults)
        #expect(block?.start == start)
        #expect(block?.categoryID == "commute")
    }
}

// MARK: - store.test.mjs timer 断言移植（:42-44）

@Suite
struct TimerBackwardCompatibility {

    @Test func legacyTimerWithoutKindDecodesAsGeneral() throws {
        // store.test.mjs:43-44「旧数据无 kind → general（向后兼容）」
        let json = #"{"startedAt":"2026-10-06T09:00:00Z"}"#.data(using: .utf8)!
        let timer = try BackupSanitizer.makeDecoder().decode(ActiveTimer.self, from: json)
        #expect(timer.kind == .general)
        // 兼容旧数据后整条停止产块路径照常可用（kind=general 语义）
        let block = TimeEngine.stopTimer(timer, at: timer.startedAt.addingTimeInterval(1200),
                                         categoryID: "warmup", note: nil,
                                         categories: TimeCategory.defaults)
        #expect(block?.categoryID == "warmup")
    }

    @Test func sleepTimerKindAndStartPreservedOnDecode() throws {
        // store.test.mjs:42「睡眠计时器保留 kind」
        let json = #"{"startedAt":"2026-10-06T23:00:00Z","kind":"sleep"}"#.data(using: .utf8)!
        let timer = try BackupSanitizer.makeDecoder().decode(ActiveTimer.self, from: json)
        #expect(timer.kind == .sleep)
        #expect(timer.startedAt == ISO8601DateFormatter().date(from: "2026-10-06T23:00:00Z"))
    }
}

// MARK: - 时间块补记 / 编辑校验（time.js:250「结束时间要晚于开始时间」）

@Suite
struct BlockValidation {

    @Test func makeBlockRequiresEndAfterStart() {
        let start = date(2026, 10, 6, 12, 0)
        let ok = TimeEngine.makeBlock(start: start, end: start.addingTimeInterval(1800),
                                      categoryID: "commute", note: nil,
                                      categories: TimeCategory.defaults)
        #expect(ok != nil)
        // end == start 与 end < start 均拒绝（与净化管线 end>start 剔除同口径）
        #expect(TimeEngine.makeBlock(start: start, end: start, categoryID: "commute",
                                     note: nil, categories: TimeCategory.defaults) == nil)
        #expect(TimeEngine.makeBlock(start: start, end: start.addingTimeInterval(-1),
                                     categoryID: "commute",
                                     note: nil, categories: TimeCategory.defaults) == nil)
    }

    @Test func unknownCategoryResolvesToFallback() {
        // lifttime store.js:221-223 catOf「找不到归最后一个（其他）」的显式化：
        // 未知 categoryID → isFallback 兜底分类
        let block = TimeEngine.makeBlock(start: date(2026, 10, 6, 8, 0),
                                         end: date(2026, 10, 6, 8, 30),
                                         categoryID: "ghost-cat",
                                         note: nil, categories: TimeCategory.defaults)
        #expect(block?.categoryID == "other")
    }

    @Test func knownCategoryResolvesEvenWithoutFallbackInTable() {
        // 无兜底分类的异常分类表：已知 id 仍可解析，未知 id 才拒绝
        let oddTable = [TimeCategory(id: "work", label: "工作", hue: .blue)]
        let block = TimeEngine.makeBlock(start: date(2026, 10, 6, 8, 0),
                                         end: date(2026, 10, 6, 9, 0),
                                         categoryID: "work", note: nil, categories: oddTable)
        #expect(block?.categoryID == "work")
        #expect(TimeEngine.makeBlock(start: date(2026, 10, 6, 8, 0),
                                     end: date(2026, 10, 6, 9, 0),
                                     categoryID: "ghost", note: nil,
                                     categories: oddTable) == nil)
    }

    @Test func noteTrimsAndEmptyBecomesNil() {
        let start = date(2026, 10, 6, 10, 0)
        let block = TimeEngine.makeBlock(start: start, end: start.addingTimeInterval(600),
                                         categoryID: "meal", note: "   ",
                                         categories: TimeCategory.defaults)
        #expect(block?.note == nil)
    }
}

// MARK: - 按日聚合（dayBrief / 跨午夜归属）

@Suite
struct DayBriefAggregation {

    @Test func aggregatesOnlyBlocksStartingOnDayWithTopSorted() {
        let blocks = [
            TimeBlock(start: date(2026, 10, 6, 9, 0), end: date(2026, 10, 6, 10, 0),   // 力量 60
                      categoryID: "strength", note: nil),
            TimeBlock(start: date(2026, 10, 6, 11, 0), end: date(2026, 10, 6, 11, 45), // 有氧 45
                      categoryID: "cardio", note: nil),
            TimeBlock(start: date(2026, 10, 5, 20, 0), end: date(2026, 10, 5, 20, 30), // 前一日 30
                      categoryID: "warmup", note: nil),
        ]
        let brief = TimeEngine.dayBrief(blocks, day: day("2026-10-06"),
                                        categories: TimeCategory.defaults, calendar: cal)
        #expect(brief.totalMinutes == 105)
        #expect(brief.topCategories.map(\.categoryID) == ["strength", "cardio"])
        #expect(brief.topCategories.map(\.label) == ["力量训练", "有氧"])
        #expect(brief.topCategories.map(\.minutes) == [60, 45])
    }

    @Test func crossMidnightBlockBelongsToStartDay() {
        // 23:30 → 次日 00:30 整段归开始日（time.js:145 start 日归属，不拆分）
        let blocks = [TimeBlock(start: date(2026, 10, 5, 23, 30), end: date(2026, 10, 6, 0, 30),
                                categoryID: "commute", note: nil)]
        let day5 = TimeEngine.dayBrief(blocks, day: day("2026-10-05"),
                                       categories: TimeCategory.defaults, calendar: cal)
        let day6 = TimeEngine.dayBrief(blocks, day: day("2026-10-06"),
                                       categories: TimeCategory.defaults, calendar: cal)
        #expect(day5.totalMinutes == 60)
        #expect(day5.topCategories.first?.categoryID == "commute")
        #expect(day6.totalMinutes == 0)
        #expect(day6.topCategories.isEmpty)
    }

    @Test func unknownCategoryBucketedIntoFallbackShare() {
        // analysis.js:408 未知分类 → 「其他」；Swift 版经 isFallback 兜底
        let blocks = [TimeBlock(start: date(2026, 10, 6, 9, 0), end: date(2026, 10, 6, 9, 20),
                                categoryID: "ghost-cat", note: nil)]
        let brief = TimeEngine.dayBrief(blocks, day: day("2026-10-06"),
                                        categories: TimeCategory.defaults, calendar: cal)
        #expect(brief.totalMinutes == 20)
        #expect(brief.topCategories.count == 1)
        #expect(brief.topCategories.first?.categoryID == "other")
        #expect(brief.topCategories.first?.label == "其他")
    }
}

// MARK: - 区间逐日聚合（近 7 / 近 30，time.js:280-305 byDay + 零填列）

@Suite
struct DailyBreakdownAggregation {

    @Test func zeroFillsEveryDayOfSevenDaySpan() {
        // 近 7 天档（time.js:35）：区间内每天一列（无数据天全 0），分类为列内键
        let span = DateSpan(startDay: day("2026-09-30"), endDay: day("2026-10-06"))
        let blocks = [
            TimeBlock(start: date(2026, 9, 30, 7, 0), end: date(2026, 9, 30, 7, 15),  // 热身 15
                      categoryID: "warmup", note: nil),
            TimeBlock(start: date(2026, 9, 30, 7, 15), end: date(2026, 9, 30, 8, 15),  // 力量 60
                      categoryID: "strength", note: nil),
            TimeBlock(start: date(2026, 10, 2, 20, 0), end: date(2026, 10, 2, 21, 30), // 通勤 90
                      categoryID: "commute", note: nil),
            TimeBlock(start: date(2026, 9, 29, 9, 0), end: date(2026, 9, 29, 10, 0),   // 区间前，不计
                      categoryID: "strength", note: nil),
        ]
        let result = TimeEngine.dailyBreakdown(blocks, in: span,
                                               categories: TimeCategory.defaults, calendar: cal)
        #expect(result.count == 7)
        #expect(Set(result.keys) == Set(["2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03",
                                         "2026-10-04", "2026-10-05", "2026-10-06"].map(day)))
        #expect(result[day("2026-09-30")]?["warmup"] == 15)
        #expect(result[day("2026-09-30")]?["strength"] == 60)
        #expect(result[day("2026-10-02")]?["commute"] == 90)
        // 无数据天：9 个默认分类列全 0
        let emptyDay = result[day("2026-10-04")]!
        #expect(emptyDay.count == 9)
        #expect(emptyDay.values.allSatisfy { $0 == 0 })
        // 区间外的块没有混入任何一天
        #expect(result.values.allSatisfy { ($0["strength"] ?? 0) == 60 || ($0["strength"] ?? 0) == 0 })
    }

    @Test func thirtyDaySpanCoversAllDays() {
        // 近 30 天档（time.js:36）
        let span = DateSpan(startDay: day("2026-09-07"), endDay: day("2026-10-06"))
        let blocks = [TimeBlock(start: date(2026, 10, 6, 6, 0), end: date(2026, 10, 6, 6, 10),
                                categoryID: "shower", note: nil)]
        let result = TimeEngine.dailyBreakdown(blocks, in: span,
                                               categories: TimeCategory.defaults, calendar: cal)
        #expect(result.count == 30)
        #expect(result[day("2026-10-06")]?["shower"] == 10)
        #expect(result[day("2026-10-05")]?["shower"] == 0)
    }

    @Test func crossMidnightAttributedToStartDayInsideSpan() {
        // 跨午夜块整段归开始日；start 日在区间内才计入（结束日溢出区间不影响）
        let span = DateSpan(startDay: day("2026-10-05"), endDay: day("2026-10-06"))
        let blocks = [
            TimeBlock(start: date(2026, 10, 5, 23, 0), end: date(2026, 10, 6, 0, 30),
                      categoryID: "stretch", note: nil),                              // 归 10-05
            TimeBlock(start: date(2026, 10, 6, 23, 30), end: date(2026, 10, 7, 0, 30),
                      categoryID: "warmup", note: nil),                               // 归 10-06（start 在区间内）
            TimeBlock(start: date(2026, 10, 4, 23, 0), end: date(2026, 10, 5, 0, 30),
                      categoryID: "warmup", note: nil),                               // start 在区间前，不计
        ]
        let result = TimeEngine.dailyBreakdown(blocks, in: span,
                                               categories: TimeCategory.defaults, calendar: cal)
        #expect(result[day("2026-10-05")]?["stretch"] == 90)
        #expect(result[day("2026-10-06")]?["warmup"] == 60)
        #expect(result[day("2026-10-05")]?["warmup"] == 0)
    }

    @Test func archivedCategoryHasNoColumnAndUnknownGoesToFallback() {
        var categories = TimeCategory.defaults
        categories[6].isArchived = true                       // supplement 归档
        let span = DateSpan(startDay: day("2026-10-06"), endDay: day("2026-10-06"))
        let blocks = [
            TimeBlock(start: date(2026, 10, 6, 8, 0), end: date(2026, 10, 6, 8, 30),
                      categoryID: "ghost-cat", note: nil),    // 未知 → 兜底 other
        ]
        let result = TimeEngine.dailyBreakdown(blocks, in: span, categories: categories, calendar: cal)
        let columns = result[day("2026-10-06")]!
        #expect(columns["supplement"] == nil)                 // 归档分类不占列
        #expect(columns.count == 8)
        #expect(columns["other"] == 30)
    }

    @Test func invalidSpanOrEmptyCategoriesReturnEmpty() {
        let reversed = DateSpan(startDay: day("2026-10-06"), endDay: day("2026-10-05"))
        #expect(TimeEngine.dailyBreakdown([], in: reversed,
                                          categories: TimeCategory.defaults,
                                          calendar: cal).isEmpty)
        #expect(TimeEngine.dailyBreakdown([], in: DateSpan(startDay: day("2026-10-06"),
                                                           endDay: day("2026-10-06")),
                                          categories: [], calendar: cal).isEmpty)
    }
}

// MARK: - fitnessMinutes（workout.js:338-343 时间×训练联动数据源）

@Suite
struct FitnessMinutesAggregation {

    @Test func sumsFitnessCatsForStartDayOnly() {
        let blocks = [
            TimeBlock(start: date(2026, 10, 6, 7, 0), end: date(2026, 10, 6, 7, 10),   // warmup 10
                      categoryID: "warmup", note: nil),
            TimeBlock(start: date(2026, 10, 6, 7, 10), end: date(2026, 10, 6, 8, 0),   // strength 50
                      categoryID: "strength", note: nil),
            TimeBlock(start: date(2026, 10, 6, 18, 0), end: date(2026, 10, 6, 18, 30), // cardio 30
                      categoryID: "cardio", note: nil),
            TimeBlock(start: date(2026, 10, 6, 8, 30), end: date(2026, 10, 6, 8, 55),  // commute 不计
                      categoryID: "commute", note: nil),
            TimeBlock(start: date(2026, 10, 6, 9, 0), end: date(2026, 10, 6, 9, 15),   // meal 不计
                      categoryID: "meal", note: nil),
            TimeBlock(start: date(2026, 10, 5, 7, 0), end: date(2026, 10, 5, 8, 0),    // 前一日不计
                      categoryID: "strength", note: nil),
        ]
        #expect(TimeEngine.fitnessMinutes(blocks, day: day("2026-10-06"), calendar: cal) == 90)
    }

    @Test func crossMidnightFitnessBlockBelongsToStartDay() {
        // 23:00 → 次日 00:30 的拉伸归开始日
        let blocks = [TimeBlock(start: date(2026, 10, 6, 23, 0), end: date(2026, 10, 7, 0, 30),
                                categoryID: "stretch", note: nil)]
        #expect(TimeEngine.fitnessMinutes(blocks, day: day("2026-10-06"), calendar: cal) == 90)
        #expect(TimeEngine.fitnessMinutes(blocks, day: day("2026-10-07"), calendar: cal) == 0)
    }

    @Test func emptyInputIsZero() {
        #expect(TimeEngine.fitnessMinutes([], day: day("2026-10-06"), calendar: cal) == 0)
    }
}

// MARK: - 分类管理（删除/归档 → 历史块归 isFallback；兜底不可删）

@Suite
struct CategoryManagement {

    @Test func deleteMigratesHistoricalBlocksToFallback() {
        let strengthBlock = TimeBlock(start: date(2026, 10, 5, 9, 0), end: date(2026, 10, 5, 10, 0),
                                      categoryID: "strength", note: "保备注")
        let commuteBlock = TimeBlock(start: date(2026, 10, 5, 18, 0), end: date(2026, 10, 5, 18, 30),
                                     categoryID: "commute", note: nil)
        let outcome = TimeEngine.deleteCategory(id: "strength", categories: TimeCategory.defaults,
                                                blocks: [strengthBlock, commuteBlock])
        guard case .applied(let categories, let blocks) = outcome else {
            Issue.record("应可删除非兜底分类，实际 \(outcome)"); return
        }
        #expect(categories.count == 8)
        #expect(!categories.contains { $0.id == "strength" })
        // strength 历史块改挂 other；块 id / 起止 / 备注原样保留（只换分类）
        #expect(blocks.first?.categoryID == "other")
        #expect(blocks.first?.id == strengthBlock.id)
        #expect(blocks.first?.note == "保备注")
        #expect(blocks.last?.categoryID == "commute")
    }

    @Test func deleteFallbackRejected() {
        // §4：isFallback 分类（默认 other）恰好一个、不可删
        let outcome = TimeEngine.deleteCategory(id: "other", categories: TimeCategory.defaults,
                                                blocks: [])
        #expect(outcome == .rejectedFallback)
    }

    @Test func deleteUnknownCategoryNotFound() {
        #expect(TimeEngine.deleteCategory(id: "ghost-cat", categories: TimeCategory.defaults,
                                          blocks: []) == .notFound)
    }

    @Test func archiveFlagsCategoryAndMigratesBlocks() {
        // 归档：分类留在表中（isArchived），历史块同样归兜底（§3.1）
        let block = TimeBlock(start: date(2026, 10, 5, 9, 0), end: date(2026, 10, 5, 9, 45),
                              categoryID: "cardio", note: nil)
        let outcome = TimeEngine.archiveCategory(id: "cardio", categories: TimeCategory.defaults,
                                                 blocks: [block])
        guard case .applied(let categories, let blocks) = outcome else {
            Issue.record("应可归档非兜底分类，实际 \(outcome)"); return
        }
        #expect(categories.count == 9)
        #expect(categories.first { $0.id == "cardio" }?.isArchived == true)
        #expect(blocks.first?.categoryID == "other")
    }

    @Test func archiveFallbackRejected() {
        #expect(TimeEngine.archiveCategory(id: "other", categories: TimeCategory.defaults,
                                           blocks: []) == .rejectedFallback)
    }

    @Test func addCategoryAcceptsColoredHueOnly() {
        // §4.1 取色口径：自建限 8 个彩色档；neutral 为兜底专属
        let added = TimeEngine.addCategory(id: "study", label: "学习阅读", hue: .blue,
                                           to: TimeCategory.defaults)
        #expect(added?.count == 10)
        #expect(added?.last == TimeCategory(id: "study", label: "学习阅读", hue: .blue))
        // neutral / 重复 id / 非法 id / 空 label 全拒
        #expect(TimeEngine.addCategory(id: "study2", label: "撞色", hue: .neutral,
                                       to: TimeCategory.defaults) == nil)
        #expect(TimeEngine.addCategory(id: "meal", label: "重复", hue: .green,
                                       to: TimeCategory.defaults) == nil)
        #expect(TimeEngine.addCategory(id: "非法 id!", label: "坏id", hue: .green,
                                       to: TimeCategory.defaults) == nil)
        #expect(TimeEngine.addCategory(id: "study3", label: "   ", hue: .green,
                                       to: TimeCategory.defaults) == nil)
    }
}

// MARK: - 引用完整性（导入后 categoryID 必须能在分类表中解析）

@Suite
struct ReferentialIntegrity {

    @Test func repairingReassignsOnlyUnknownReferences() {
        let orphan = TimeBlock(start: date(2026, 10, 6, 9, 0), end: date(2026, 10, 6, 9, 30),
                               categoryID: "deleted-cat", note: "孤儿")
        let intact = TimeBlock(start: date(2026, 10, 6, 10, 0), end: date(2026, 10, 6, 10, 20),
                               categoryID: "warmup", note: nil)
        let repaired = TimeEngine.repairingOrphanedBlocks([orphan, intact],
                                                          categories: TimeCategory.defaults)
        #expect(repaired.first?.categoryID == "other")
        #expect(repaired.first?.id == orphan.id)          // 只换分类，其余不动
        #expect(repaired.first?.note == "孤儿")
        #expect(repaired.last == intact)                  // 可解析的块原样保留
    }

    @Test func repairingWithoutFallbackLeavesBlocksUntouched() {
        // 无兜底分类的异常表：无迁移目标，保持原样（净化管线会先补位兜底）
        let oddTable = [TimeCategory(id: "work", label: "工作", hue: .blue)]
        let block = TimeBlock(start: date(2026, 10, 6, 9, 0), end: date(2026, 10, 6, 9, 30),
                              categoryID: "ghost-cat", note: nil)
        #expect(TimeEngine.repairingOrphanedBlocks([block], categories: oddTable) == [block])
    }
}
