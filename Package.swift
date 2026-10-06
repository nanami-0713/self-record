// swift-tools-version: 6.0
import PackageDescription

// SelfRecord · 模块化 Swift Package（docs/design.md §8）
//
// - SelfRecordCore：Foundation only，禁止 import SwiftUI / Charts（§8 目录树注释）。
// - SelfRecordUI：SwiftUI + Swift Charts；全包禁用 SwiftUI 宏（§0-2 / §8 约定 5，
//   状态管理走 ObservableObject + @Published propertyWrapper 路径）。
// - SelfRecordCoreTests：Swift Testing（import Testing）。
//
// ⚠ 必须声明 macOS：本机 swift build 以 host macOS 构建（design.md §8 目录树）。
// app/（@main 入口 + XcodeGen project.yml）不在任何 target 内，不参与 swift build。

let package = Package(
    name: "SelfRecord",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // 供 app/project.yml（XcodeGen）引用的两个本地 library
        .library(name: "SelfRecordCore", targets: ["SelfRecordCore"]),
        .library(name: "SelfRecordUI", targets: ["SelfRecordUI"]),
    ],
    targets: [
        .target(
            name: "SelfRecordCore"
        ),
        .target(
            name: "SelfRecordUI",
            dependencies: ["SelfRecordCore"]
        ),
        .testTarget(
            name: "SelfRecordCoreTests",
            dependencies: ["SelfRecordCore"]
            // 历史：CLT-only 环境曾需 .unsafeFlags 补 Swift Testing 宏插件搜索路径
            // （design.md §12.4）；2026-10-06 装好完整 Xcode 并切换 xcode-select 后
            // 已移除——unsafeFlags 会阻止本 package 被外部 SwiftPM 包声明为依赖。
            // 若回到 CLT-only 环境，用 scripts/test.sh（自带 -Xswiftc -plugin-path）。
        ),
    ],
    swiftLanguageModes: [.v6]
)
