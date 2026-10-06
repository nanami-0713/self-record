import SwiftUI

// MARK: - SRBadge 家族（design.md §7.4 · Ely badge.rs:55-208）

/// 徽标：圆角 Sm 4、字号 Xs 11（badge.rs:116-118）。色调 = 实色/淡底成对
/// （severity.rs 的 color/subtle）；neutral 档 fg_subtle 字 + sunken 底（badge.rs:55）。
public struct SRBadge: View {

    public enum Tone: String, Sendable, CaseIterable {
        case neutral, info, success, warning, danger

        var severity: SRSeverity? {
            switch self {
            case .neutral: nil
            case .info: .info
            case .success: .success
            case .warning: .warning
            case .danger: .danger
            }
        }

        var foreground: Color {
            severity?.color ?? .srForegroundSubtle
        }

        var background: Color {
            severity?.subtleColor ?? .srSunken
        }
    }

    let text: String
    let tone: Tone

    public init(_ text: String, tone: Tone = .neutral) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text)
            .srFont(.xs, .medium)
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: SRRadius.sm, style: .continuous)
                    .fill(tone.background)
            )
    }
}

/// 计数徽标：全圆、封顶 99+（badge.rs:128-187）；0 时隐藏。
public struct SRCountBadge: View {

    let count: Int
    let maxCount: Int

    public init(count: Int, maxCount: Int = 99) {
        self.count = count
        self.maxCount = maxCount
    }

    public var body: some View {
        if count > 0 {
            Text(count > maxCount ? "\(maxCount)+" : "\(count)")
                .srFont(.xs, .medium)
                .monospacedDigit()
                .foregroundStyle(Color.srOnAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.srAccent))
                .clipShape(Capsule())
                .accessibilityLabel("\(count)")
        }
    }
}

/// 状态点：6px 全圆（badge.rs:204-208；status_dot tokens.rs:405-412）。
/// 外描一圈 bg 色的用法（badge.rs:247-251）由调用方加 `.overlay`/padding 实现。
public struct SRDotBadge: View {

    let color: Color

    public init(_ color: Color) {
        self.color = color
    }

    public init(severity: SRSeverity) {
        self.color = severity.color
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }
}
