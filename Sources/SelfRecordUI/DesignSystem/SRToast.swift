import SwiftUI

// MARK: - SRToast（design.md §6/§7.4 · Ely toast.rs:19-407）

/// 自研 Toast overlay 栈（lifttime toast 的 iOS 替代，§6 全局交互约定表）。
/// 规格（toast.rs）：卡片 = surface 底 + 1px border + 圆角 Lg 8 + Floating 阴影
/// + p_3(12)（:278-288）；结构 = Severity 图标 + 标题(MEDIUM/fg) + 正文(fg_muted)
/// + 可选动作按钮(Sm) + 关闭钮（:290-333）；栈宽 360（tokens.rs:277-280）、
/// 默认停留 5s、最多 4 条超出踢掉最旧（:19-22、:119-124）；Undo/动作型底部
/// 2px 倒计时线（:382-407）；进场 SLOW ease_out、退场 BASE 折叠+淡出（:361-379）。
///
/// 与 Ely 的差异（iOS 化）：
/// - 位置改**底部居中**（拇指区，§7.4）；
/// - 「指针悬停栈上计时暂停」（:160-177）属桌面悬停语义，舍弃（§9-4）；
/// - 退场「高度折叠」以 opacity+底部缩放近似（SwiftUI transition 无高度折叠原语）。
///
/// 用法：AppModel 或页面持有 `SRToastCenter`（ObservableObject 路径，
/// 宏禁令 §8 约定 5），根视图 `.srToastHost(center)`。
public struct SRToastMessage: Identifiable {
    public let id: UUID
    public let severity: SRSeverity
    public let title: String
    public let message: String?
    public let actionTitle: String?
    public let action: (() -> Void)?
    public let duration: TimeInterval
    /// 倒计时线锚点（show 时定，TimelineView 据此画剩余比例）。
    public let expiresAt: Date

    init(
        id: UUID = UUID(),
        severity: SRSeverity,
        title: String,
        message: String?,
        actionTitle: String?,
        action: (() -> Void)?,
        duration: TimeInterval
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.duration = duration
        self.expiresAt = Date().addingTimeInterval(duration)
    }
}

/// Toast 栈控制器（@MainActor；计时用 Task，不依赖 Timer 对象）。
@MainActor
public final class SRToastCenter: ObservableObject {

    /// 最多 4 条，超出踢掉最旧（toast.rs:119-124）。
    public static let stackLimit = 4
    /// 默认停留 5s（toast.rs:19-22）。
    public static let defaultDuration: TimeInterval = 5

    @Published public private(set) var messages: [SRToastMessage] = []

    private var autoDismissTasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    deinit {
        for task in autoDismissTasks.values {
            task.cancel()
        }
    }

    /// 弹出一条。`actionTitle` 非空即为 Undo/动作型（带倒计时线）。
    public func show(
        _ title: String,
        message: String? = nil,
        severity: SRSeverity = .info,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        duration: TimeInterval = SRToastCenter.defaultDuration
    ) {
        let toast = SRToastMessage(
            severity: severity, title: title, message: message,
            actionTitle: actionTitle, action: action, duration: duration
        )
        // 超出上限踢最旧
        while messages.count >= Self.stackLimit, let oldest = messages.first {
            cancelTask(id: oldest.id)
            messages.removeAll { $0.id == oldest.id }
        }
        messages.append(toast)
        scheduleAutoDismiss(for: toast)
    }

    /// 立即关闭指定条目（关闭钮/动作按钮触发）。
    public func dismiss(id: UUID) {
        cancelTask(id: id)
        messages.removeAll { $0.id == id }
    }

    public func dismissAll() {
        autoDismissTasks.values.forEach { $0.cancel() }
        autoDismissTasks.removeAll()
        messages.removeAll()
    }

    private func scheduleAutoDismiss(for toast: SRToastMessage) {
        autoDismissTasks[toast.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(toast.duration))
            guard !Task.isCancelled else { return }
            self?.dismiss(id: toast.id)
        }
    }

    private func cancelTask(id: UUID) {
        autoDismissTasks[id]?.cancel()
        autoDismissTasks[id] = nil
    }
}

// MARK: - 视图

/// Toast 栈宿主：底部居中、宽 360、间距 8；进出场动画挂在 messages 变化上。
public struct SRToastHost: View {

    @ObservedObject public var center: SRToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(center: SRToastCenter) {
        self.center = center
    }

    public var body: some View {
        VStack(spacing: SRSpacing.sm) {
            ForEach(center.messages) { message in
                SRToastCard(message: message) {
                    center.dismiss(id: message.id)
                }
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
                    )
                )
            }
        }
        .frame(maxWidth: 360)                         // 栈宽 360
        .animation(
            reduceMotion ? nil : SRMotion.base,
            value: center.messages.map(\.id)          // 消息含闭包不可 Equatable，按 id 序列驱动
        )
        .allowsHitTesting(!center.messages.isEmpty)
    }
}

struct SRToastCard: View {

    let message: SRToastMessage
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: SRSpacing.sm) {
                Image(systemName: message.severity.symbolName)
                    .font(.sr(.sm))
                    .foregroundStyle(message.severity.color)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.title)
                        .srFont(.base, .medium)
                        .foregroundStyle(Color.srForeground)
                    if let detail = message.message {
                        Text(detail)
                            .srFont(.sm)
                            .foregroundStyle(Color.srForegroundMuted)
                    }
                }
                Spacer(minLength: SRSpacing.xs)
                if let actionTitle = message.actionTitle {
                    SRButton(actionTitle, style: .ghost, size: .sm) {
                        message.action?()
                        onDismiss()
                    }
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.sr(.xs))
                        .foregroundStyle(Color.srForegroundMuted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            .padding(SRSpacing.md)                    // p_3(12)
            if message.actionTitle != nil {
                SRToastCountdownLine(
                    expiresAt: message.expiresAt,
                    duration: message.duration
                )
            }
        }
        .background(Color.srSurface)
        .clipShape(RoundedRectangle(cornerRadius: SRRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SRRadius.lg, style: .continuous)
                .stroke(Color.srBorder, lineWidth: 1)
        )
        .srShadow(.floating)
        .accessibilityElement(children: .combine)
    }
}

/// Undo/动作型底部 2px 倒计时线（toast.rs:382-407）。
/// 无状态实现：TimelineView 逐帧用当前时间对 expiresAt 求剩余比例。
struct SRToastCountdownLine: View {

    let expiresAt: Date
    let duration: TimeInterval

    var body: some View {
        TimelineView(.animation) { context in
            let remaining = expiresAt.timeIntervalSince(context.date)
            let fraction = duration > 0
                ? Swift.min(1, Swift.max(0, remaining / duration))
                : 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.clear
                    Rectangle()
                        .fill(Color.srAccent.opacity(0.4))
                        .frame(width: geo.size.width * fraction, height: 2)
                }
            }
        }
        .frame(height: 2)
    }
}

// MARK: - 宿主修饰器

public extension View {
    /// 挂 Toast 栈（底部居中 overlay；「已保存/可撤销」轻反馈，§6）。
    func srToastHost(_ center: SRToastCenter) -> some View {
        overlay(alignment: .bottom) {
            SRToastHost(center: center)
                .padding(.bottom, SRSpacing.xl)
        }
    }
}
