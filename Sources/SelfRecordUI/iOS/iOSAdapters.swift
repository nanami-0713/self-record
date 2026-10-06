// MARK: - iOS-only 代码集中地（design.md §8 目录树 / §8 约定 6）
//
// UIKit 触感、Keychain、HealthKit 适配等 iOS 独有 API 一律：
//   1. 集中放本目录（Sources/SelfRecordUI/iOS/）；
//   2. 全部 #if os(iOS) / canImport(UIKit) 包裹，且保证缺省分支（macOS）可编译；
//   3. 写薄、写少——本机只有命令行工具，iOS SDK 不存在（§0-1），iOS 分支在本机
//      **从未编译过**，是真机首轮编译的预期爆雷点（§11 风险 1）。
//
// 共享代码（Today/ Records/ Workout/ Budget/ Settings/ DesignSystem/）只用
// SwiftUI / Charts 跨平台子集。
