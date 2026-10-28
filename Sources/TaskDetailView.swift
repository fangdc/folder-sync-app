import SwiftUI
import AppKit

// MARK: - 系统设置风格的行
//
// 背景、行内边距、行间分隔线全部交给 `.formStyle(.grouped)` 的 Form 处理，
// 这里只负责「左边标题 / 右边控件」的排布，不自己画底。

/// 一行设置项：左边标题（可带灰色说明），右边控件。
/// 应用图标：优先取运行中 App 的图标（换了图标这里自动跟着变），取不到时退回 SF Symbol。
struct AppIconImage: View {
    var size: CGFloat = 64

    var body: some View {
        Group {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: size * 0.68))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: size, height: size)
            }
        }
    }
}

/// 等宽字体的路径展示：空路径显示占位文字并变灰，太长时中间截断。
/// 详情页和首次欢迎页共用，保证两边观感一致。
struct PathText: View {
    let path: String
    var placeholder: String = "未选择"

    var body: some View {
        Text(path.isEmpty ? placeholder : Fmt.prettyPath(path))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(path.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var description: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

// MARK: - 详情页

/// 文件夹行里那对按钮（选择文件夹 / 在访达中显示）的标签内容高度。
///
/// 注意：在 Button **外面**套 `.frame(height:)` 是没用的 —— 那只占布局槽位，
/// 系统底纹仍按自己的自然高度居中绘制，两个按钮照样一高一低（实测约 17pt vs 15pt）。
/// 底纹是包着标签内容画的，所以要把「内容盒子」撑成同一高度。
private let folderButtonLabelHeight: CGFloat = 16

/// 「间隔」下拉里的常用值（分钟）。原来那一排「常用间隔」快捷按钮并到了这一行的下拉里。
private let intervalPresets = [5, 15, 30, 60, 180, 720]

/// 间隔选项的文案：满一小时的按小时显示
private func intervalLabel(_ minutes: Int) -> String {
    minutes >= 60 ? "\(minutes / 60) 小时" : "\(minutes) 分钟"
}

struct TaskDetailView: View {
    @EnvironmentObject private var center: SyncCenter
    @Binding var task: SyncTask
    @State private var showHistory = false

    private var isRunning: Bool { center.runningTaskIDs.contains(task.id) }
    private var progress: SyncProgress? { center.activeProgress[task.id] }

    var body: some View {
        // 用原生的分组表单（.formStyle(.grouped)）：行背景、内边距、行间分隔线、
        // 浅色/深色适配全部由系统负责，和「系统设置」是同一套外观。
        // 底部操作栏照样单独占一行，不浮在表单上。
        Form {
            // 启用开关单独放最顶部一组
            Section {
                Toggle("启用这个任务", isOn: $task.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            folderSection
            modeSection
            scheduleSection
            recentSection
        }
        .formStyle(.grouped)
        // 右栏内容铺到了窗口最顶（为了配合工具栏那条毛玻璃），
        // 所以滚动内容要让开工具栏高度，否则第一行会被压在工具栏下面。
        .contentMargins(.top, center.toolbarHeight, for: .scrollContent)
        // 底部按钮是悬浮的、不占布局，所以要给滚动内容留出底部空间，
        // 否则最后一行会被永久压住（滚到底也露不出来）。
        .contentMargins(.bottom, 52, for: .scrollContent)
        // 右下角悬浮
        .overlay(alignment: .bottomTrailing) { actionBar }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showHistory) {
            HistorySheet(taskID: task.id)
                .environmentObject(center)
        }
    }

    // MARK: 文件夹

    private var folderSection: some View {
        Section {
            SettingsRow(title: "源文件夹") {
                HStack(spacing: 8) {
                    PathText(path: task.sourcePath)
                    Button {
                        chooseSource()
                    } label: {
                        Text("选择文件夹").frame(height: folderButtonLabelHeight)
                    }
                    .controlSize(.small)

                    if !task.sourcePath.isEmpty {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([task.sourceURL])
                        } label: {
                            // Label + iconOnly：系统才会按标准图标按钮算边框（纯 Image 不会）
                            Label("在访达中显示", systemImage: "folder")
                                .labelStyle(.iconOnly)
                                .frame(height: folderButtonLabelHeight)
                        }
                        .controlSize(.small)
                        .help("在访达中显示")
                    }
                }
            }

            SettingsRow(title: "目标文件夹") {
                HStack(spacing: 8) {
                    // 显示**最终写入的完整路径**（目标文件夹 + 新建的同名子文件夹），
                    // 而不是只显示用户选的根目录 —— 一眼就能看出文件到底会落到哪儿。
                    // 路径由 destinationURL 算出来（子文件夹名取源文件夹名），所以天然与源文件夹一致。
                    PathText(path: task.isConfigured ? task.destinationURL.path : "")
                    Button {
                        chooseDestination()
                    } label: {
                        Text("选择文件夹").frame(height: folderButtonLabelHeight)
                    }
                    .controlSize(.small)

                    if !task.destinationRoot.isEmpty {
                        Button {
                            // 优先打开最终写入的目录（和左边显示的路径一致）；
                            // 它要等第一次同步后才会被创建，尚不存在时退回根目录
                            // —— 否则 Finder 打不开不存在的路径，点了没反应。
                            let destination = task.destinationURL
                            let target = FileManager.default.fileExists(atPath: destination.path)
                                ? destination
                                : task.destinationRootURL
                            NSWorkspace.shared.activateFileViewerSelecting([target])
                        } label: {
                            Label("在访达中显示", systemImage: "folder")
                                .labelStyle(.iconOnly)
                                .frame(height: folderButtonLabelHeight)
                        }
                        .controlSize(.small)
                        .help("在访达中显示")
                    }
                }
            }

        } header: {
            Text("文件夹")
        } footer: {
            folderFooter
        }
    }


    @ViewBuilder
    private var folderFooter: some View {
        let fm = FileManager.default
        var sourceIsDirectory: ObjCBool = false
        let sourceAvailable = !task.sourcePath.isEmpty
            && fm.fileExists(atPath: task.sourceURL.path, isDirectory: &sourceIsDirectory)
            && sourceIsDirectory.boolValue
        var rootIsDirectory: ObjCBool = false
        let rootAvailable = !task.destinationRoot.isEmpty
            && fm.fileExists(atPath: task.destinationRootURL.path, isDirectory: &rootIsDirectory)
            && rootIsDirectory.boolValue
        if !task.sourcePath.isEmpty, !sourceAvailable {
            // 源盘没挂载是最危险的情况：不能让镜像同步把目标当成「源已清空」。
            Label("暂停同步！源文件夹不存在，请查看移动存储设备是否已挂载。",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if !task.destinationRoot.isEmpty, !rootAvailable {
            Label("暂停同步！目标文件夹不存在，请查看移动存储设备是否已挂载。",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Text("选择目标文件夹后，会在目标文件夹下创建与源文件夹同名的同步文件夹，同步任务将会在该新建同步文件夹中进行，目标文件夹下其他文件不受影响。")
        }
    }

    // MARK: 同步方式

    private var modeSection: some View {
        Section {
            SettingsRow(title: "方式") {
                // 和「频率」用同一种控件（系统弹出菜单）。
                // 不要给 Picker 加固定宽度：NSPopUpButton 自己会按最宽的一项算宽度，
                // 外面再套 .frame(width:) 多出来的部分就是右侧那块空白。
                Picker("", selection: $task.mode) {
                    ForEach(SyncMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        } header: {
            Text("同步方式")
        } footer: {
            if task.mode == .mirror {
                // 文案取自 SyncMode.summary（和上面那个分支同一个来源，避免两处各写一份）。
                //
                // 手写 HStack 而不是 Label：表单 footer 里 Label 的图文间距偏大（实测约 9pt），
                // 这里收到 4pt。图标圆形、且不上警示色 —— 这是一句提醒，不是报错。
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "exclamationmark.circle")
                    Text(task.mode.summary)
                }
            } else {
                Text(task.mode.summary)
            }
        }
    }

    // MARK: 自动同步

    /// 下拉里可选的间隔值
    private var intervalChoices: [Int] {
        let current = task.schedule.intervalMinutes
        return intervalPresets.contains(current)
            ? intervalPresets
            : (intervalPresets + [current]).sorted()
    }

    private var scheduleSection: some View {
        Section {
            SettingsRow(title: "频率") {
                Picker("", selection: $task.schedule.mode) {
                    ForEach(ScheduleMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            if task.schedule.mode == .interval {
                SettingsRow(title: "间隔") {
                    // 和「频率」用同一个组件（菜单式 Picker），去掉手动输入。
                    // 选项 = 常用值；若当前值不在常用值里（历史配置遗留的自定义分钟数），
                    // 把它自己也算进去，免得下拉显示空白。
                    Picker("", selection: $task.schedule.intervalMinutes) {
                        ForEach(intervalChoices, id: \.self) { minutes in
                            Text(intervalLabel(minutes)).tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            if task.schedule.mode == .daily {
                SettingsRow(title: "时间") {
                    // 原生时间控件（小时 + 分钟，带上下步进器），就是系统设置里那种。
                    // 之前用过 48 项的菜单下拉——列表长得拉不完，删掉。
                    // 注意 .field 那个变体会被 SwiftUI 自动设成第一响应者、且点空白处不会失焦，
                    // 表现为一进页面小时数就被蓝底选中；这里用 stepperField 并在出现后主动收回焦点。
                    DatePicker("", selection: dailyTimeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.stepperField)
                        .onAppear { clearTextFocus() }
                }
            }

            SettingsRow(title: "下次运行") {
                Text(nextRunDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("自动同步")
        }
    }

    private var nextRunDescription: String {
        guard task.enabled else { return "任务已暂停" }
        guard task.isConfigured else { return "还没配置完整" }
        guard let next = center.nextRunDate(for: task) else { return "仅手动同步" }
        return "\(Fmt.absolute(next))（\(Fmt.relative(next))）"
    }

    // MARK: 最近记录

    private var recentSection: some View {
        let runs = center.history.filter { $0.taskID == task.id }.prefix(5)
        return Section {
            if runs.isEmpty {
                Text("还没有同步记录。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(runs)) { run in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(for: run.outcome))
                            .frame(width: 7, height: 7)
                        Text(Fmt.absolute(run.startedAt))
                            .font(.system(size: 11, design: .monospaced))
                        Text(run.brief)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Fmt.duration(run.duration))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Button("查看全部记录") { showHistory = true }
                .controlSize(.small)
        } header: {
            Text("最近记录")
        }
    }

    private func color(for outcome: SyncOutcome) -> Color {
        switch outcome {
        case .success: return .green
        case .partial: return .orange
        case .failed: return .red
        case .cancelled: return .gray
        }
    }

    // MARK: 底部操作栏
    //
    // 玻璃胶囊（和右下角那两个按钮同一个做法）。
    // 必须自绘胶囊：系统玻璃按钮样式的高度由 controlSize 决定，无法精确对齐别处。

    /// 源/目标文件夹缺失、未配置或正在同步时，底部两个按钮都不可用。
    private var syncDisabled: Bool {
        isRunning || !task.isConfigured || !task.foldersAvailable
    }

    private var previewDisabled: Bool {
        syncDisabled || center.previewLoading.contains(task.id)
    }

    /// 置灰时的文字颜色：比 45% 整体透明度更深，浅色/深色背景下都能看清。
    private var disabledLabelColor: Color {
        Color.primary.opacity(0.55)
    }

    private var actionBar: some View {
        GlassGroup(spacing: 10) {
            VStack(alignment: .trailing, spacing: 10) {
                if isRunning, let progress {
                    progressCapsule(progress)
                }
                HStack(spacing: 10) {
                    // 顺序：取消（仅同步中）→ 预览改动 → 立即同步（最右，主行动）
                    if isRunning {
                        Button {
                            center.cancel(task.id)
                        } label: {
                            Label("取消", systemImage: "xmark")
                                .font(.system(size: 13))
                                .padding(.horizontal, 16)
                                .frame(height: 32)
                                .glassSurface(Capsule(), interactive: true)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        center.requestPreview(task.id)
                    } label: {
                        Label("预览改动", systemImage: "doc.text.magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(previewDisabled ? disabledLabelColor : Color.primary)
                            .padding(.horizontal, 16)
                            .frame(height: 32)
                            .glassSurface(Capsule(), interactive: !previewDisabled)
                    }
                    .buttonStyle(.plain)
                    .disabled(previewDisabled)
                    .help(task.foldersAvailable ? "预览改动" : "源文件夹或目标文件夹不存在，已暂停同步")

                    Button {
                        center.syncNow(task.id)
                    } label: {
                        Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13))
                            .foregroundStyle(syncDisabled ? disabledLabelColor : .white)
                            .padding(.horizontal, 16)
                            .frame(height: 32)
                            .glassSurface(Capsule(),
                                          tint: syncDisabled ? nil : Color.accentColor,
                                          interactive: !syncDisabled)
                    }
                    .buttonStyle(.plain)
                    .disabled(syncDisabled)
                    .help(task.foldersAvailable ? "立即同步" : "源文件夹或目标文件夹不存在，已暂停同步")
                }
            }
        }
        // 右下角：bottom 10 与左栏「同步全部任务」的 bottom 10 一致，
        // 两个按钮都是 32pt 高，所以左右底边严格齐平。
        //
        // 左右各留 16pt，与系统分组表单给分组框的内边距一致（实测左右都是约 16.5pt）：
        // 这样进度浮窗的左右边缘就与表单分组框对齐。按钮是右对齐的，不受左侧内边距影响。
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func progressCapsule(_ progress: SyncProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(progress.phase)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer(minLength: 12)
                Text("\(progress.completed)/\(progress.total)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                if progress.bytesTotal > 0 {
                    Text(Fmt.bytes(progress.bytesCopied))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            // 撑满胶囊宽度：原来写死 280pt，胶囊有 600+ 宽，右边会空掉一大块
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)
            if !progress.currentPath.isEmpty {
                Text(progress.currentPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: false)
    }

    // MARK: 绑定辅助

    /// 每天定时的时间（小时 + 分钟），交给原生 DatePicker
    private var dailyTimeBinding: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = task.schedule.dailyHour
                components.minute = task.schedule.dailyMinute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newValue in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                task.schedule.dailyHour = components.hour ?? 3
                task.schedule.dailyMinute = components.minute ?? 0
            }
        )
    }

    /// 把文本控件的焦点收回来。
    ///
    /// SwiftUI 在视图出现时会把第一个文本控件设成第一响应者，而点击 SwiftUI 的空白区域
    /// 又不会让它失焦 —— 表现为时间里的数字一直蓝底选中。出现后主动收一次焦点，
    /// 用户之后点它仍然可以正常编辑。
    private func clearTextFocus() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow else { return }
            if window.firstResponder is NSTextView {
                window.makeFirstResponder(nil)
            }
        }
    }

    // MARK: 选择文件夹
    //
    // 用 NSOpenPanel 不只是图方便 —— 用户在这里选过的路径会被系统授予访问权限
    // （powerbox 机制），所以选桌面 / 文稿 / 下载里的文件夹时不需要额外的权限弹窗。

    private func chooseSource() {
        FolderPicker.choose(title: "选择要同步的源文件夹",
                            message: "这个文件夹里的内容会被同步到目标文件夹。",
                            current: task.sourcePath) { url in
            if let url { task.sourcePath = url.path }
        }
    }

    private func chooseDestination() {
        FolderPicker.choose(title: "选择目标文件夹",
                            message: "通常选移动硬盘的根目录，App 会在里面自动创建同名文件夹。",
                            current: task.destinationRoot,
                            needsWrite: true) { url in
            if let url { task.destinationRoot = url.path }
        }
    }
}

enum FolderPicker {
    /// 选一个文件夹。
    ///
    /// 两条避坑（都踩过，表现都是「点『选择文件夹』没反应」）：
    /// 1. 不用 `runModal()`：它会自起模态会话，在已经有 sheet 时嵌套模态会让面板不出现；
    /// 2. 也不能往一个已经挂着 sheet 的窗口上再挂 sheet：AppKit 直接忽略
    ///    （报 "already has a sheet"）。首次欢迎页本身就是 sheet，就是这种情况。
    ///
    /// 所以按有没有 sheet 分流：没有 → `beginSheetModal`（原生 sheet，贴在窗口上）；
    /// 已有 sheet → `panel.begin`，不挂任何窗口，保证能弹到前台。
    static func choose(title: String,
                       message: String,
                       current: String?,
                       needsWrite: Bool = false,
                       completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        if let current, !current.isEmpty {
            let url = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) {
                panel.directoryURL = url
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { completion(nil); return }
            // 选完当场验权限：没权限就立刻触发系统授权框（首次访问会弹），
            // 弹不出/被拒绝时由 SynchroniCenter 弹我们自己的引导窗，而不是等同步失败。
            if !probeAccess(url, needsWrite: needsWrite) {
                SyncCenter.shared.reportPermissionIssue(folder: url.path, atPicker: true)
                completion(nil)
                return
            }
            completion(url)
        }
        // 关键：**不能**往一个已经挂着 sheet 的窗口上再挂 sheet ——
        // AppKit 会直接忽略（日志里报 "already has a sheet"），表现就是点了没反应。
        // 首次欢迎页就是一个 sheet，所以那种情况下改用不挂窗口的 panel.begin。
        let host = NSApp.keyWindow ?? NSApp.mainWindow
        let someoneHasSheet = NSApp.windows.contains { $0.attachedSheet != nil }
        if let host, !someoneHasSheet {
            panel.beginSheetModal(for: host, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// 当场探一下能不能读 / 能不能写。
    /// 这一步的目的不是「拦下用户」，而是**把系统授权框提前到选文件夹的瞬间** ——
    /// 用户刚选完就看到「允许 FolderSync 访问桌面文件夹吗」，而不是同步到一半才失败。
    private static func probeAccess(_ url: URL, needsWrite: Bool) -> Bool {
        let fm = FileManager.default
        if needsWrite {
            let probe = url.appendingPathComponent(".foldersync-write-probe-\(UUID().uuidString.prefix(8))")
            do {
                try Data("probe".utf8).write(to: probe)
                try? fm.removeItem(at: probe)
                return true
            } catch {
                return !Fmt.isPermissionError(error)
            }
        } else {
            do {
                _ = try fm.contentsOfDirectory(atPath: url.path)
                return true
            } catch {
                return !Fmt.isPermissionError(error)
            }
        }
    }
}

// MARK: - 历史记录

struct HistorySheet: View {
    let taskID: UUID?
    @EnvironmentObject private var center: SyncCenter
    @Environment(\.dismiss) private var dismiss
    /// 是否正在显示「确认清空」的原生弹窗
    @State private var isConfirmingClear = false
    /// 哪几次运行的「同步详情」是展开的。默认展开最新一次（改动不多时）。
    @State private var expandedChangeRuns: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // 标题只写「同步记录」—— 记录是从任务详情页打开的，不必在标题重复任务名
                Text("同步记录")
                    .font(.headline)
                Spacer()
                CloseButton { dismiss() }
            }
            .padding(14)

            Divider()

            let runs = taskID == nil ? center.history : center.history.filter { $0.taskID == taskID }
            Group {
                if runs.isEmpty {
                    Text("还没有记录")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(runs) { run in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Circle().fill(color(for: run.outcome)).frame(width: 8, height: 8)
                            // 任务名不再重复显示：记录是从某个任务的详情页打开的，上下文已经明确。
                            // 第一行直接放这次运行的结果，失败 / 无变动 / 新增 N 一眼就能看到。
                            Text(run.brief)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(run.outcome == .success ? Color.primary : color(for: run.outcome))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Fmt.absolute(run.startedAt))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            HStack(spacing: 12) {
                                Text("耗时 \(Fmt.duration(run.duration))")
                                Text("数据量 \(Fmt.bytes(run.bytesCopied))")
                                Text(triggerLabel(run.trigger))
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            Spacer(minLength: 8)
                            if run.hasChangeDetails {
                                syncDetailsToggle(for: run)
                            }
                        }
                        if run.hasChangeDetails, expandedChangeRuns.contains(run.id) {
                            // 超过 80 条改用 LazyVStack；一次同步几万条时也只创建可见的行。
                            // 条数少时框高按内容自适应，超过 180pt 后框内滚动。
                            if run.changes.count > syncDetailLazyThreshold {
                                ScrollViewReader { proxy in
                                    ScrollView(.vertical) {
                                        ChangeLogView(run: run, lazy: true)
                                            .padding(10)
                                            .id("syncDetailTop")
                                    }
                                    .defaultScrollAnchor(.top)
                                    .scrollIndicators(.visible)
                                    .onAppear {
                                        // 几万条时 LazyVStack 内容高度很大，首次布局可能落在中间；
                                        // 强制回到第一行，避免一展开就是 file-00160。
                                        DispatchQueue.main.async {
                                            proxy.scrollTo("syncDetailTop", anchor: .top)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 180)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(nsColor: .underPageBackgroundColor))
                                )
                            } else {
                                SyncDetailBox(maxHeight: 180) {
                                    ChangeLogView(run: run)
                                }
                            }
                        }
                        if !run.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(run.messages.prefix(5).enumerated()), id: \.offset) { _, message in
                                    Text(message)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.orange)
                                        .textSelection(.enabled)
                                }
                                if run.messages.count > 5 {
                                    Text("…… 还有 \(run.messages.count - 5) 条")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                        .padding(.vertical, 4)
                        // 记录之间的系统分隔线：0.5pt（Retina 1 物理像素），4% 黑
                        .listRowSeparatorTint(Color.black.opacity(0.04))
                    }
                }
            }
            // 给悬浮按钮让出滚动空间：不这么做，列表最后一条会被按钮永久压住
            .contentMargins(.bottom, 52, for: .scrollContent)
            .onAppear {
                // 打开记录时默认展开最新一次运行的明细：多数同步只改几个文件，
                // 直接就能看到改了什么。首次全量同步这种改动特别多的保持收起，
                // 避免一打开就是几百行。
                //
                // 必须等这一轮渲染结束（async）再改状态：在 onAppear 里同步插入时，
                // 行视图会保留插入前的 isExpanded=false，而 Set 里已经有这个 id，
                // 再点「同步详情」只是重复插入同一个 id、不产生状态变化，界面永远不展开（实测）。
                guard let latest = runs.first,
                      latest.hasChangeDetails,
                      latest.changeCount <= 30 else { return }
                let id = latest.id
                DispatchQueue.main.async {
                    expandedChangeRuns.insert(id)
                }
            }
            // 「清空」悬浮在列表上方、底部居中（不是在列表下面另占一行）。
            // 样式复用详情页「预览改动」那套玻璃胶囊 + icon + 文字。
            .overlay(alignment: .bottom) {
                Button {
                    // 不直接清：清空不可撤销，先弹原生确认框
                    isConfirmingClear = true
                } label: {
                    Label("清空", systemImage: "trash")
                        .font(.system(size: 13))
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .glassSurface(Capsule(), interactive: true)
                }
                .buttonStyle(.plain)
                .disabled(runs.isEmpty)
                .opacity(runs.isEmpty ? 0.45 : 1)
                .padding(.bottom, 14)
            }
        }
        .frame(width: 640, height: 480)
        // 清空记录不可撤销，走系统原生 alert 二次确认。
        // 说明里点明「只清这个任务」和「不影响已经同步出去的文件」——
        // 这两点是用户最容易误判的地方。
        .alert("清空后无法恢复，确定吗？", isPresented: $isConfirmingClear) {
            Button("取消", role: .cancel) { }
            Button("清空", role: .destructive) {
                center.clearHistory(for: taskID)
            }
        } message: {
            Text("只会删除这个任务的同步记录，已经同步出去的文件不受影响。")
        }
    }

    /// 触发方式只分两类：
    /// 手动点的算「手动同步」；定时到点、登录后自动跑的都算「自动同步」。
    /// 用户只关心「是我按的」还是「它自己跑的」，没必要区分是定时还是登录触发。
    private func triggerLabel(_ trigger: String) -> String {
        switch trigger {
        case "timer", "login": return "自动同步"
        default: return "手动同步"
        }
    }

    // MARK: 同步详情

    /// 记录第二行右侧的「同步详情」开关：点开在下方展示这次同步新建 / 修改 / 删除了哪些文件。
    @ViewBuilder
    private func syncDetailsToggle(for run: SyncRun) -> some View {
        let isExpanded = expandedChangeRuns.contains(run.id)
        Button {
            if isExpanded {
                expandedChangeRuns.remove(run.id)
            } else {
                expandedChangeRuns.insert(run.id)
            }
        } label: {
            HStack(spacing: 3) {
                Text("同步详情")
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "收起同步详情" : "展开这次同步新建、修改、删除了哪些文件")
    }

    private func color(for outcome: SyncOutcome) -> Color {
        switch outcome {
        case .success: return .green
        case .partial: return .orange
        case .failed: return .red
        case .cancelled: return .gray
        }
    }
}

// MARK: - 同步详情内容

/// 一次运行的明细超过这么多条时，用 LazyVStack 渲染，避免一次性创建几万个行视图。
private let syncDetailLazyThreshold = 80

/// 详情内容的高度测量：把内容自然高度上报给 `SyncDetailBox`。
private struct SyncDetailHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 同步详情的灰色圆角框。
/// 内容不高时贴合内容；超过 `maxHeight` 后高度封顶，超出部分在框内滚动。
private struct SyncDetailBox<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content
                .padding(10)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: SyncDetailHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        // 内容没超出时不显示滚动条，避免短列表旁边多一条无意义的滚动条
        .scrollIndicators(contentHeight > maxHeight ? .visible : .hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 初值给 1pt：内容还没量出高度时框高为 0，会让 GeometryReader 没有可布局空间
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))
        )
        .onPreferenceChange(SyncDetailHeightKey.self) { height in
            contentHeight = height
        }
    }
}

/// 一次同步的逐条变更清单，按「新建 / 修改 / 删除」分组。
/// 路径是相对同步文件夹的路径，鼠标悬停可看完整路径，也可以直接选中复制。
private struct ChangeLogView: View {
    let run: SyncRun
    /// 大列表走 LazyVStack，只创建可见的行。
    var lazy: Bool = false

    private enum Row: Identifiable {
        case divider(SyncChangeGroup)
        case header(SyncChangeGroup, count: Int)
        case change(SyncChange, group: SyncChangeGroup)
        case note(String)

        var id: String {
            switch self {
            case .divider(let group): return "divider-\(group.rawValue)"
            case .header(let group, _): return "header-\(group.rawValue)"
            case .change(let change, _): return "change-\(change.id)"
            case .note(let text): return "note-\(text)"
            }
        }
    }

    private var rows: [Row] {
        var result: [Row] = []
        let groups = SyncChangeGroup.allCases.filter { !run.changes(in: $0).isEmpty }
        for (index, group) in groups.enumerated() {
            if index > 0 {
                result.append(.divider(group))
            }
            let items = run.changes(in: group)
            result.append(.header(group, count: items.count))
            for item in items {
                result.append(.change(item, group: group))
            }
        }
        if run.changesOmitted > 0 {
            result.append(.note("这条记录由旧版本生成，另有 \(run.changesOmitted) 项变更没有保存。"))
        }
        return result
    }

    var body: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .divider:
            // 0.5pt ≈ Retina 屏 1 物理像素；4% 黑，比系统 Divider 更轻
            Rectangle()
                .fill(Color.black.opacity(0.04))
                .frame(height: 0.5)
                .padding(.vertical, 5)
        case .header(let group, let count):
            HStack(spacing: 5) {
                Text(group.title)
                    .font(.system(size: 10, weight: .semibold))
                    // 浅色下是 60% 黑，深色下自动变成 60% 白，避免在黑底上看不见
                    .foregroundStyle(Color.primary.opacity(0.60))
                Text("\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 4)
        case .change(let change, let group):
            HStack(spacing: 4) {
                changeIcon(for: change.kind)
                    .foregroundStyle(color(for: group).opacity(0.85))
                    .frame(width: 11)
                Text(displayPath(for: change))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(displayPath(for: change))
                Spacer(minLength: 8)
                if change.size > 0 {
                    Text(Fmt.bytes(change.size))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        case .note(let text):
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
        }
    }

    private func color(for group: SyncChangeGroup) -> Color {
        switch group {
        case .created: return .green
        case .updated: return .blue
        case .deleted: return .red
        }
    }

    private func icon(for kind: SyncChangeKind) -> String {
        switch kind {
        case .createdFolder: return "folder.badge.plus"
        case .modifiedFolder: return "folder.badge.gearshape"
        case .deletedFolder: return "folder.badge.minus"
        case .createdLink: return "link"
        case .createdFile: return "document.badge.plus"
        case .modifiedFile: return "document.badge.gearshape"
        case .deletedFile: return "doc"
        }
    }

    @ViewBuilder
    private func changeIcon(for kind: SyncChangeKind) -> some View {
        if kind == .deletedFile {
            // 自定义 SF Symbol：放在 Resources/Assets.xcassets 里，由 actool 编译进 Assets.car。
            // 用法和系统符号一致，.font / .symbolRenderingMode / 前景色都会生效。
            Image("document.badge.minus")
                .font(.system(size: 9))
                .symbolRenderingMode(.monochrome)
        } else {
            Image(systemName: icon(for: kind))
                .font(.system(size: 9))
        }
    }

    /// 文件夹改名显示成「旧路径 → 新路径」，普通文件只显示路径。
    private func displayPath(for change: SyncChange) -> String {
        if change.kind == .modifiedFolder,
           let fromPath = change.fromPath,
           !fromPath.isEmpty {
            return "\(fromPath) → \(change.path)"
        }
        return change.path
    }
}

// MARK: - 预览

struct PreviewSheet: View {
    let preview: PlanPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let plan = preview.plan {
                content(plan)
            } else {
                loading
            }
        }
        .frame(width: 700, height: 520)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("同步预览").font(.headline)
                // 路径来自任务本身，不等计划算完就能显示
                Text(preview.destinationPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            CloseButton { dismiss() }
        }
        .padding(14)
    }

    /// 计算中：弹窗已经出来了，这里给个进度指示（关闭按钮照样可用，随时能走）
    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("正在比较两个文件夹…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(_ plan: SyncPlan) -> some View {
        if let error = plan.blockingError {
            VStack(spacing: 10) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.red)
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
        } else {
            summaryBar(plan)
            Divider()
            if plan.items.isEmpty {
                Text("目标文件夹已经和源文件夹一致，没有需要改动的文件。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(plan.items.prefix(300), id: \.relativePath) { item in
                    HStack(spacing: 8) {
                        badge(for: item, in: plan)
                        Text(item.relativePath)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        if item.size > 0 {
                            Text(Fmt.bytes(item.size))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                if plan.items.count > 300 {
                    Text("只显示前 300 项，共 \(plan.items.count) 项")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
        }
    }

    private func summaryBar(_ plan: SyncPlan) -> some View {
        HStack(spacing: 16) {
            stat("复制文件", "\(plan.copies.count)", .blue)
            stat("新建文件夹", "\(plan.directories.count)", .secondary)
            stat("删除", "\(plan.deletions.count)", plan.deletions.isEmpty ? .secondary : .red)
            stat("无需改动", "\(plan.skippedFiles)", .secondary)
            Spacer()
            Text("预计写入 \(Fmt.bytes(plan.bytesToCopy))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 16, weight: .semibold)).foregroundStyle(color)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func badge(for item: SyncPlanItem, in plan: SyncPlan) -> some View {
        let isDelete = plan.deletions.contains { $0.relativePath == item.relativePath }
        let text: String = {
            if isDelete { return "删除" }
            switch item.kind {
            case .directory: return "新建"
            case .symlink: return "链接"
            case .file: return "复制"
            }
        }()
        let color: Color = isDelete ? .red : (item.kind == .directory ? .secondary : .blue)
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
            .frame(width: 34)
    }
}
