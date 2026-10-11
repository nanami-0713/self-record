import SelfRecordCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 导出文件文档（design.md §5：导出 = BackupDocument JSON，文件名带日期由 UI 层处理）

/// `fileExporter` 的载荷：备份 JSON 数据。AI Key 不含由 `BackupDocument`
/// 结构本身保证（无该字段，AppModel.exportBackup 注释）。
struct BackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - 数据管理流程状态（宏禁令 §8 约定 5：页面局部状态走 ObservableObject）

/// DataManagementView 的状态机：
/// - 数据概览（各域计数 + 估算体积，onAppear / 导入 / 清空后刷新）；
/// - 导出（exportBackup → fileExporter）；
/// - 导入（选文件 → **三步容错净化干跑** → 预览 sheet → **双确认** → 外壳 importBackup）；
/// - 清空（**双确认** → 外壳 eraseAll）。
@MainActor
final class DataManagementFlow: ObservableObject {

    enum ConfirmStage: Equatable {
        case idle, first, second
    }

    @Published var overview: AppModel.DataOverview?
    @Published var isExporting = false
    @Published var exportDocument: BackupFileDocument?
    @Published var exportFileName = ""
    @Published var exportPresented = false
    @Published var importerPresented = false
    /// 净化后文档（非 nil 即出预览 sheet）+ 原始数据（双确认后走外壳 importBackup 再净化一次）。
    @Published var preview: BackupDocument?
    @Published var pendingImportData: Data?
    @Published var importStage: ConfirmStage = .idle
    @Published var eraseStage: ConfirmStage = .idle
    @Published var importError: String?
    @Published var actionError: String?

    /// 本页轻反馈（导出成功 / 导入完成 / 已清空）。
    let toast = SRToastCenter()

    // MARK: 概览

    func refresh(_ model: AppModel) {
        // 主线程只取值拷贝，8 域 pretty-print 编码在后台跑（同 sanitizeForPreview 模式）
        let input = model.dataOverviewInput()
        Task {
            let overview = await Task.detached(priority: .userInitiated) {
                AppModel.computeOverview(input)
            }.value
            self.overview = overview
        }
    }

    // MARK: 导出

    func startExport(_ model: AppModel) {
        isExporting = true
        Task {
            do {
                let now = Date()
                let data = try await model.exportBackup(now: now)
                let day = DayKey(now, calendar: DayCalendar()).rawValue
                exportDocument = BackupFileDocument(data: data)
                exportFileName = "SelfRecord-backup-\(day)"
                exportPresented = true
            } catch {
                actionError = "导出失败：\(error.localizedDescription)"
            }
            isExporting = false
        }
    }

    // MARK: 导入（选文件 → 净化干跑 → 预览 → 双确认 → 覆盖）

    /// 选中文件后的落点：读盘 + 三步容错净化（干跑）。净化在后台线程执行
    /// （50MB 上限内的 JSON 解析也不该卡主线程），结果回主线程出预览或错误。
    func pickImport(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            sanitizeForPreview(data)
        } catch {
            importError = "读取文件失败：\(error.localizedDescription)"
        }
    }

    /// 净化干跑的结果载体（Result 的 Failure 须为 Error，故自备枚举）。
    private enum SanitizeOutcome: Sendable {
        case sanitized(BackupDocument)
        case failed(String)
    }

    private func sanitizeForPreview(_ data: Data) {
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                () -> SanitizeOutcome in
                do {
                    return .sanitized(try AppModel.sanitizeForPreview(data))
                } catch let error as SanitizeError {
                    return .failed(DataManagementFlow.message(for: error))
                } catch {
                    return .failed("解析失败：\(error.localizedDescription)")
                }
            }.value
            switch outcome {
            case .sanitized(let document):
                preview = document
                pendingImportData = data
                importStage = .idle
            case .failed(let message):
                importError = message
            }
        }
    }

    /// SanitizeError → 用户可读文案（§5 四种预检失败）。
    nonisolated private static func message(for error: SanitizeError) -> String {
        switch error {
        case .tooLarge: "文件超过 50MB 导入上限"
        case .notJSON: "不是有效的 JSON 文件"
        case .tooDeep: "数据嵌套层级过深"
        case .notObject: "备份文件格式不正确（顶层应为对象）"
        }
    }

    func cancelImport() {
        preview = nil
        pendingImportData = nil
        importStage = .idle
    }

    /// 第二次确认后的落点：整体替换各域 + 刷新快照与概览（外壳通用入口）。
    func performImport(_ model: AppModel) {
        guard let data = pendingImportData else { return }
        importStage = .idle
        Task {
            do {
                try await model.importBackup(data)
                pendingImportData = nil
                preview = nil
                refresh(model)
                toast.show("导入完成", message: "已用净化后的备份覆盖全部数据", severity: .success)
            } catch {
                importError = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: 清空（双确认 → 外壳 eraseAll）

    func performErase(_ model: AppModel) {
        eraseStage = .idle
        Task {
            do {
                try await model.eraseAll()
                refresh(model)
                toast.show("已清空全部数据", severity: .success)
            } catch {
                actionError = "清空失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - DataManagementView（design.md §6：导出/导入/清空 + 存储占用概览）

public struct DataManagementView: View {

    @EnvironmentObject private var model: AppModel
    @StateObject private var flow = DataManagementFlow()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SRSpacing.xl) {
                overviewSection
                exportSection
                importSection
                eraseSection
            }
            .padding(.horizontal, SRSpacing.lg)
            .padding(.vertical, SRSpacing.xl)
        }
        .background(Color.srBackground)
        .navigationTitle("数据管理")
        .onAppear { flow.refresh(model) }
        .srToastHost(flow.toast)
        .sheet(isPresented: previewBinding) {
            ImportPreviewSheet(flow: flow)
        }
        .alert("操作失败", isPresented: actionErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(flow.actionError ?? "")
        }
        .alert("最后确认", isPresented: eraseSecondBinding) {
            Button("确认清空", role: .destructive) { flow.performErase(model) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可恢复。确定要清空全部数据吗？")
        }
    }

    // MARK: 绑定（sheet / 弹层由枚举 stage 驱动，Bool 绑定做归一）

    private var previewBinding: Binding<Bool> {
        Binding(
            get: { flow.preview != nil },
            set: { if !$0 { flow.cancelImport() } }
        )
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { flow.actionError != nil },
            set: { if !$0 { flow.actionError = nil } }
        )
    }

    private var eraseFirstBinding: Binding<Bool> {
        Binding(
            get: { flow.eraseStage == .first },
            set: { if !$0, flow.eraseStage == .first { flow.eraseStage = .idle } }
        )
    }

    private var eraseSecondBinding: Binding<Bool> {
        Binding(
            get: { flow.eraseStage == .second },
            set: { if !$0, flow.eraseStage == .second { flow.eraseStage = .idle } }
        )
    }

    // MARK: 数据概览（§6「存储占用概览」）

    private var overviewSection: some View {
        section("数据概览") {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: SRSpacing.md)],
                          spacing: SRSpacing.md) {
                    ForEach(overviewItems, id: \.label) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                                .srFont(.xs)
                                .foregroundStyle(Color.srForegroundMuted)
                            Text("\(item.count)")
                                .srFont(.md, .semibold)
                                .monospacedDigit()
                                .foregroundStyle(Color.srForeground)
                        }
                    }
                }
                let bytes = flow.overview?.totalBytes ?? 0
                Text("估算存储占用 \(bytesText(bytes))（当前内存快照按磁盘同款编码测算）")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
            }
        }
    }

    private var overviewItems: [(label: String, count: Int)] {
        guard let overview = flow.overview else { return [] }
        return [
            ("时间分类", overview.categories),
            ("时间块", overview.timeBlocks),
            ("睡眠", overview.sleepSessions),
            ("训练", overview.workouts),
            ("饮食记录", overview.dietEntries),
            ("开销", overview.expenses),
            ("自学习食物", overview.customFoods),
            ("自定义动作", overview.customExercises),
        ]
    }

    // MARK: 导出

    private var exportSection: some View {
        section("导出") {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                Text("全量导出为带日期的 JSON 备份文件；AI Key 属 Keychain，永不进备份。")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
                SRButton("导出备份", icon: "square.and.arrow.up", style: .primary,
                         isLoading: flow.isExporting) {
                    flow.startExport(model)
                }
            }
        }
        .fileExporter(isPresented: $flow.exportPresented,
                      document: flow.exportDocument,
                      contentType: .json,
                      defaultFilename: flow.exportFileName) { result in
            switch result {
            case .success:
                flow.toast.show("导出成功", severity: .success)
            case .failure(let error):
                flow.actionError = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: 导入

    private var importSection: some View {
        section("导入") {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                Text("选择备份文件：50MB 上限与格式预检 → 三步容错净化（坏条剔除、好条目存活）→ 双重确认后覆盖全部数据。")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
                SRButton("选择备份文件", icon: "square.and.arrow.down", style: .secondary) {
                    flow.importerPresented = true
                }
            }
        }
        .fileImporter(isPresented: $flow.importerPresented,
                      allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                flow.pickImport(url: url)
            case .failure(let error):
                flow.importError = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .alert("导入失败", isPresented: importErrorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(flow.importError ?? "")
        }
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(
            get: { flow.importError != nil },
            set: { if !$0 { flow.importError = nil } }
        )
    }

    // MARK: 清空（危险区）

    private var eraseSection: some View {
        section("危险区") {
            VStack(alignment: .leading, spacing: SRSpacing.md) {
                Text("删除所有记录、分类与设置。此操作不可恢复，且不影响已导出的备份文件。")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
                SRButton("清空全部数据", icon: "trash", style: .danger) {
                    flow.eraseStage = .first
                }
            }
        }
        .confirmationDialog("清空全部数据？",
                            isPresented: eraseFirstBinding,
                            titleVisibility: .visible) {
            Button("继续", role: .destructive) { flow.eraseStage = .second }
            Button("取消", role: .cancel) {}
        } message: {
            Text(eraseFirstMessage)
        }
    }

    private var eraseFirstMessage: String {
        let total = flow.overview.map {
            $0.timeBlocks + $0.sleepSessions + $0.workouts
                + $0.dietEntries + $0.expenses + $0.customFoods + $0.customExercises
        }
        if let total {
            return "将删除全部 \(total) 条记录与所有设置（含时间分类），不可恢复。"
        }
        return "将删除全部记录与所有设置（含时间分类），不可恢复。"
    }

    // MARK: 分节骨架

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SRSpacing.sm) {
            Text(title)
                .srFont(.sm, .medium)
                .foregroundStyle(Color.srForegroundMuted)
            SRCard {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func bytesText(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

// MARK: - 导入预览 sheet（净化摘要 + 双确认）

private struct ImportPreviewSheet: View {

    @ObservedObject var flow: DataManagementFlow
    /// sheet 继承呈现视图的环境（SwiftUI 呈现语义），AppModel 由根部注入。
    @EnvironmentObject private var model: AppModel

    private var firstConfirmBinding: Binding<Bool> {
        Binding(
            get: { flow.importStage == .first },
            set: { if !$0, flow.importStage == .first { flow.importStage = .idle } }
        )
    }

    private var secondConfirmBinding: Binding<Bool> {
        Binding(
            get: { flow.importStage == .second },
            set: { if !$0, flow.importStage == .second { flow.importStage = .idle } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SRSpacing.lg) {
            Text("导入预览")
                .srFont(.lg, .semibold)

            if let document = flow.preview {
                VStack(alignment: .leading, spacing: SRSpacing.md) {
                    Text("文件已通过三步容错净化（逐条容错解码 → 字段归 nil → 值域校验）。以下为净化后将被写入的数据：")
                        .srFont(.sm)
                        .foregroundStyle(Color.srForegroundMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: SRSpacing.md)],
                              spacing: SRSpacing.md) {
                        countItem("时间分类", document.categories.count)
                        countItem("时间块", document.timeBlocks.count)
                        countItem("睡眠", document.sleepSessions.count)
                        countItem("训练", document.workouts.count)
                        countItem("饮食记录", document.dietEntries.count)
                        countItem("开销", document.expenses.count)
                        countItem("自学习食物", document.customFoods.count)
                        countItem("自定义动作", document.customExercises.count)
                    }

                    Text("备份版本 \(document.version) · 导出于 \(document.exportedAt.formatted(date: .abbreviated, time: .shortened))")
                        .srFont(.xs)
                        .foregroundStyle(Color.srForegroundSubtle)
                }
            }

            HStack(alignment: .top, spacing: SRSpacing.md) {
                Image(systemName: SRSeverity.danger.symbolName)
                    .font(.sr(.base))
                    .foregroundStyle(Color.srDanger)
                Text("导入将整体替换当前全部数据（含设置与分类），此操作不可撤销。")
                    .srFont(.sm)
                    .foregroundStyle(Color.srForegroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SRSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.srDangerSubtle)
            .clipShape(RoundedRectangle(cornerRadius: SRRadius.lg, style: .continuous))

            Spacer(minLength: 0)

            HStack {
                SRButton("取消", style: .ghost) { flow.cancelImport() }
                Spacer()
                SRButton("覆盖导入", icon: "square.and.arrow.down", style: .danger) {
                    flow.importStage = .first
                }
            }
        }
        .padding(SRSpacing.lg)
        .frame(maxWidth: 560, alignment: .leading)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(true)   // 双确认流程中途防误关
        .confirmationDialog("覆盖现有数据？",
                            isPresented: firstConfirmBinding,
                            titleVisibility: .visible) {
            Button("继续", role: .destructive) { flow.importStage = .second }
            Button("取消", role: .cancel) { flow.importStage = .idle }
        } message: {
            Text("导入将整体替换当前全部记录与设置，此操作不可撤销。")
        }
        .alert("最后确认", isPresented: secondConfirmBinding) {
            Button("确认覆盖", role: .destructive) { flow.performImport(model) }
            Button("取消", role: .cancel) { flow.importStage = .idle }
        } message: {
            Text("确定要用备份覆盖当前全部数据吗？")
        }
    }

    private func countItem(_ label: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .srFont(.xs)
                .foregroundStyle(Color.srForegroundMuted)
            Text("\(count)")
                .srFont(.md, .semibold)
                .monospacedDigit()
                .foregroundStyle(Color.srForeground)
        }
    }
}
