import SwiftUI
import AppKit

// MARK: - 主界面
//
// 结构是「左列表 + 右详情」（和「系统设置」同一类骨架）：
//   左栏 = 搜索框 + 任务列表（NavigationSplitView 的侧栏，延伸到窗口最顶）
//   右栏 = 任务详情（标题与目标路径交给系统工具栏显示）
//   底部 = 浮在内容之上的玻璃胶囊操作栏（不占独立一行）
//
// 为什么用 NavigationSplitView 而不是自己拼 HStack：
// 苹果为 macOS 26 重做过它，侧栏会「穿透」到窗口最顶（交通灯落在侧栏里），
// 工具栏只覆盖右侧内容区 —— 这就是 Finder / 系统设置的结构，
// 不会出现一条横贯全宽的分隔区。

struct ContentView: View {
    /// 左栏固定理想宽度：写死 ideal 才能保证选中前后分栏线不动，
    /// 同时放开 min/max 让它还能手动拖拽。
    private static let sidebarWidth: CGFloat = 300

    @EnvironmentObject private var center: SyncCenter
    /// 多选：⌘ 点选加/减，⇧ 连选一段。
    @State private var selection: Set<UUID> = []
    /// ⇧ 连选的锚点（上一次普通点选的那一行）
    @State private var selectionAnchor: UUID?
    /// 等待二次确认的删除。为空表示没有弹窗。
    @State private var pendingDeletion: [SyncTask] = []
    /// 首次启动的欢迎页（一个任务都没有时出现）
    @State private var showWelcome = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240,
                                                ideal: Self.sidebarWidth,
                                                max: 460)
        } detail: {
            detailPane
        }
        .toolbar { toolbarContent }
        // 工具栏背景保持透明：
        // 系统那层材质横跨整窗，会在左侧栏顶部留一条底色。
        // 通透的毛玻璃由右栏自己用 NSVisualEffectView 画（见 detailPane）。
        .toolbarBackground(.hidden, for: .windowToolbar)
        // 操作结果气泡浮在内容之上、几秒后自动消失
        .overlay(alignment: .top) { toastOverlay }
        .frame(minWidth: 940, minHeight: 580)
        .background(WindowAccessor { window in
            center.adoptMainWindow(window)
        })
        .onAppear {
            if selection.isEmpty { selection = center.tasks.first.map { [$0.id] } ?? [] }
            // 一个任务都没有 = 首次使用，先给一页引导把源/目标两个目录选出来
            if center.tasks.isEmpty { showWelcome = true }
        }
        .onChange(of: center.tasks.count) { _, _ in
            // 干掉已删除的 id；一个都不剩时退回选中第一个
            selection = selection.intersection(Set(center.tasks.map(\.id)))
            if selection.isEmpty { selection = center.tasks.first.map { [$0.id] } ?? [] }
        }
        .sheet(item: $center.preview) { preview in
            PreviewSheet(preview: preview)
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeView { showWelcome = false }
                .environmentObject(center)
        }
        // 没有访问权限时：不只报错，弹原生 alert 引导去系统设置授权
        .alert("需要授权才能写入目标文件夹", isPresented: permissionAlertBinding,
               presenting: center.permissionRequest) { _ in
            Button("取消", role: .cancel) { center.permissionRequest = nil }
            Button("打开系统设置") {
                openPrivacySettings()
                center.permissionRequest = nil
            }
        } message: { request in
            Text("「\(Fmt.prettyPath(request.folder.isEmpty ? "目标文件夹" : request.folder))」现在写不进去。\n"
                 + "可能是系统还没允许 FolderSync 访问可移动宗卷，或这块磁盘本身不允许写入。\n"
                 + "在「系统设置 → 隐私与安全性 → 文件与文件夹」里勾选 FolderSync，然后回来重试。")
        }
        // 删除任务的二次确认：用系统原生 alert（标题 + 说明 + 取消/删除 两个按钮）。
        // pendingDeletion 非空即代表弹窗显示，所以 isPresented 由它推出来，不必再维护一个 Bool。
        .alert(deletionTitle(pendingDeletion),
               isPresented: Binding(get: { !pendingDeletion.isEmpty },
                                    set: { if !$0 { pendingDeletion = [] } }),
               presenting: pendingDeletion) { tasks in
            Button("取消", role: .cancel) { pendingDeletion = [] }
            Button("删除", role: .destructive) { performDeletion(tasks) }
        } message: { tasks in
            Text(deletionMessage(tasks))
        }
    }

    // MARK: - 工具栏

    /// 控件放进工具栏后，位置和间距由系统统一处理。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            settingsButton
        }
    }

    private var settingsButton: some View {
        Button {
            SettingsOpener.shared.show()
        } label: {
            Label("设置", systemImage: "gearshape")
                .labelStyle(.iconOnly)
        }
        .help("设置（⌘,）")
    }

    // MARK: - 左栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            newTaskButton
                .padding(.top, 8)
                .padding(.bottom, 10)
            taskList
                // 悬浮按钮不占布局，所以要给滚动内容留出底部内边距：
                // 静止时最后一行不会被压住，滚动时内容从玻璃下面经过。
                .contentMargins(.bottom, 52, for: .scrollContent)
                .overlay(alignment: .bottom) { syncAllButton }
        }
        // 水平内边距统一加在这一层：按钮和列表项在同一个坐标系里，宽度因此严格一致
        .padding(.horizontal, 12)
        // 空状态浮在**整个侧栏**上（含按钮区域），和右栏的覆盖范围完全一致，
        // 两边的图标/文字才会落在同一水平线。
        .overlay { sidebarEmptyState }
    }

    /// 左栏顶部的新建任务按钮：蓝色液态玻璃，icon + 文字，整栏宽度。
    ///
    /// 必须自绘玻璃：系统玻璃按钮样式的高度由 controlSize 决定，做不出这种
    /// 「整栏宽度的主行动按钮」，也没法和右栏底部那两个胶囊保持一致的观感。
    private var newTaskButton: some View {
        Button {
            let task = center.addTask()
            selection = [task.id]
            selectionAnchor = task.id
        } label: {
            Label("新建同步任务", systemImage: "plus")
                .font(.system(size: 13))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .glassSurface(Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
        .help("新建同步任务")
    }

    /// 悬浮在任务列表底部的「同步全部任务」。
    /// 样式跟右栏底部的「预览改动」一致：胶囊 + 液态玻璃 + icon + 文字。
    /// 用 overlay 浮在列表上而不是另占一行 —— 列表内容会从这层玻璃下面滚过去。
    private var syncAllButton: some View {
        let hasRunnableTask = center.tasks.contains {
            $0.enabled && $0.isConfigured && $0.foldersAvailable
        }
        let disabled = center.tasks.isEmpty || center.isSyncingAnything || !hasRunnableTask
        return Button {
            center.syncAll()
        } label: {
            Label("同步全部任务", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .medium))
                // 玻璃着色后系统不会自动把标签转成白字（实测蓝底上还是近黑的 label 色），
                // 这里显式指定，等价于 .glassProminent 的观感。
                .foregroundStyle(disabled ? Color.primary.opacity(0.55) : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .glassSurface(Capsule(),
                              tint: disabled ? nil : Color.accentColor,
                              interactive: !disabled)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(hasRunnableTask
              ? "立即同步全部任务（⌘R）"
              : "没有可同步的任务：请检查任务是否启用、源文件夹或目标文件夹是否存在")
        .padding(.bottom, 10)
    }

    private var taskList: some View {
        // 用 ScrollView + LazyVStack 而不是 List。
        //
        // 一是因为选中底色要自己画：系统侧栏的选中色跟着强调色（蓝）走，
            // 只有列表不是第一响应者时，macOS 才把选中画成灰的 —— 点一下让列表拿到焦点，它一样变蓝。
            // 本 App 的列表就是唯一能拿焦点的东西，永远显示强调态的蓝，所以只能自己画。
        //
        // 二是 List 除了 listRowInsets 之外还自带一层基础内缩（实测列表项比
        // 上面的「新建同步任务」按钮每侧多 10.5pt），靠调 rowInsets 压不平；
        // 换成 ScrollView 之后按钮和列表项共用外层的同一个水平内边距，宽度天然一致。
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(center.tasks) { task in
                    TaskRow(task: task,
                            isSelected: selection.contains(task.id),
                            isRunning: center.runningTaskIDs.contains(task.id),
                            progress: center.activeProgress[task.id],
                            folderAvailabilityRevision: center.folderAvailabilityRevision)
                    // 点选交给 onTapGesture（原来用 Button，但 Button 会吞掉拖动手势）
                    .onTapGesture { handleTap(task) }
                    // 原来这行是 Button；换成手势后补上按钮语义，读屏仍会念成可操作项
                    .accessibilityAddTraits(.isButton)
                    // 拖动排序：拖自己、放到目标行上即插到它的位置
                    .draggable(task.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first,
                              let draggedID = UUID(uuidString: raw),
                              draggedID != task.id,
                              let from = center.tasks.firstIndex(where: { $0.id == draggedID }),
                              let to = center.tasks.firstIndex(where: { $0.id == task.id })
                        else { return false }
                        center.moveTask(from: from, to: to)
                        return true
                    }
                    // 右键菜单只留三项。作用对象：右键点的那行**在选中集合里**就作用于
                    // 整个选中集合，否则只作用于它自己（macOS 的惯常行为）。
                    .contextMenu {
                        Button(contextSyncTitle(task)) { syncContextTargets(task) }
                            .disabled(!contextTargets(task).contains { $0.foldersAvailable })
                        Button(contextToggleTitle(task)) { toggleContextTargets(task) }
                        Divider()
                        Button("删除任务", role: .destructive) {
                            // 不直接删，先弹原生确认框；确认后才真正执行
                            pendingDeletion = contextTargets(task)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        // 侧栏列表不显示滚动条：这里通常只有一两个任务，滚动条基本用不上，
        // 露出来反而在侧栏右侧多一道竖线。
        .scrollIndicators(.hidden)
    }

    /// 左栏空状态。样式与右栏空状态严格一致：
    /// 图标 34pt、文字 13pt、`.primary.opacity(0.3)`、间距 12、四周留白 26。
    @ViewBuilder
    private var sidebarEmptyState: some View {
        if center.tasks.isEmpty {
            EmptyHint(icon: "arrow.triangle.2.circlepath",
                      title: "还没有同步任务")
        }
    }

    // MARK: - 右栏

    @ViewBuilder
    private var detailPane: some View {
        detailContent
            // 顶部压一条系统原生毛玻璃 —— 和系统工具栏一个原理。
            //
            // **顺序不能颠倒**：overlay 必须在 ignoresSafeArea 之前。
            // 先叠玻璃（此时这条还在安全区顶部）→ 再忽略顶部安全区，整块（含玻璃）一起被顶进
            // 工具栏区域，玻璃就正好落在工具栏那一层。
            // 反过来写（先 ignoresSafeArea 再 overlay）的话，玻璃会锚在安全区顶部，
            // 落到工具栏下面一格 —— 实测在距顶 52..104pt 的位置，白做。
            .overlay(alignment: .top) {
                if center.isFullScreen {
                    // 全屏：工具栏自动隐藏，窗口最顶那一条**没有任何内容覆盖** ——
                    // 分组表单的背景只画在安全区以内，露出来的是窗口底色。
                    // 它比表单页底色略暗（深色模式实测 #1E1E1E vs #28292B），于是与下面的内容
                    // 之间出现一条横向接缝。这里直接用页面底色把这条补齐。
                    //
                    // 用实色而不是再叠一层毛玻璃：实测那条材质在全屏下渲染后与窗口底色完全一样，
                    // 等于没画（它的 .withinWindow 混合在全屏时没有可采样的窗口内容）。
                    // 实色一定能画上去，只需保证颜色和页面一致。
                    fullScreenTopFill
                        .frame(height: center.toolbarHeight)
                        .allowsHitTesting(false)
                } else {
                    // 窗口模式：毛玻璃条，压住系统工具栏那一层
                    VisualEffectBackground(material: .headerView, blending: .withinWindow)
                        .frame(height: center.toolbarHeight)
                        .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let id = primarySelectionID, let binding = center.binding(for: id) {
            TaskDetailView(task: binding,
                           folderAvailabilityRevision: center.folderAvailabilityRevision)
                .id(id)
                // 任务名与路径交给系统工具栏显示 —— 材质和 SF Symbols 那种原生工具栏
                // 完全一致，比在内容里自绘一个大标题通透得多
                .navigationTitle(binding.wrappedValue.displayName)
                .navigationSubtitle(detailSubtitle(binding.wrappedValue))
        } else {
            EmptyHint(icon: "rectangle.on.rectangle.angled",
                      title: "选中左侧的任务查看详情")
                // 右栏现在铺到了窗口最顶，空状态的居中基准要让开工具栏高度
                // —— 让空状态的居中对齐到内容区（让开工具栏高度）
                .padding(.top, center.toolbarHeight)
                .navigationTitle("FolderSync")
                // 没选中任务时不写说明文案，只放一个「/」占住位置 ——
                // 选中任务时这里是源文件夹路径（形如 ~/Desktop），空着一块反而显得缺东西。
                .navigationSubtitle("/")
        }
    }

    /// 全屏时补在最顶那一条的底色，按外观分别取值，尽量贴住系统分组表单的页底色：
    /// 深色取 `underPageBackgroundColor`（实测比表单页只差 1/255），
    /// 浅色取 `windowBackgroundColor`（表单页在浅色下就是白）。
    /// 用 `NSColor(name:dynamicProvider:)` 定义，跟随系统外观自动切换。
    private var fullScreenTopFill: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .underPageBackgroundColor
                : .windowBackgroundColor
        })
    }

    // MARK: - 多选

    /// 当前选中的任务，**按列表顺序**（右栏靠它取"最上面那个"）
    private var selectedTasks: [SyncTask] {
        center.tasks.filter { selection.contains($0.id) }
    }

    /// 右栏显示哪个任务：选中项里最上面的一个；多选时也只显示这一个。
    private var primarySelectionID: UUID? {
        selectedTasks.first?.id
    }

    /// 普通点选 = 只选它；⌘ 点选 = 加/减一项；⇧ 点选 = 从上一次点选处连选一段。
    /// permissionRequest 非空即代表要弹窗（和删除确认同一种写法）
    private var permissionAlertBinding: Binding<Bool> {
        Binding(get: { center.permissionRequest != nil },
                set: { if !$0 { center.permissionRequest = nil } })
    }

    /// 打开「隐私与安全性 → 文件与文件夹」，用户在那里勾选本 App 即可授权
    private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    private func handleTap(_ task: SyncTask) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(task.id) {
                selection.remove(task.id)
            } else {
                selection.insert(task.id)
            }
            selectionAnchor = task.id
        } else if flags.contains(.shift),
                  let anchor = selectionAnchor,
                  let from = center.tasks.firstIndex(where: { $0.id == anchor }),
                  let to = center.tasks.firstIndex(where: { $0.id == task.id }) {
            let range = from <= to ? from...to : to...from
            selection = Set(center.tasks[range].map(\.id))
        } else {
            selection = [task.id]
            selectionAnchor = task.id
        }
    }

    /// 右键菜单作用于哪些任务
    private func contextTargets(_ task: SyncTask) -> [SyncTask] {
        guard selection.contains(task.id) else { return [task] }
        let picked = selectedTasks
        return picked.isEmpty ? [task] : picked
    }

    private func contextSyncTitle(_ task: SyncTask) -> String {
        contextTargets(task).count > 1 ? "同步选中任务" : "立即同步"
    }

    private func contextToggleTitle(_ task: SyncTask) -> String {
        contextTargets(task).allSatisfy(\.enabled) ? "暂停任务" : "启用任务"
    }

    private func syncContextTargets(_ task: SyncTask) {
        let targets = contextTargets(task)
        let runnable = targets.filter { $0.foldersAvailable }
        if runnable.count < targets.count {
            center.showToast("有 \(targets.count - runnable.count) 个任务的源文件夹或目标文件夹不存在，已跳过。",
                             kind: .warning)
        }
        for target in runnable {
            center.syncNow(target.id)
        }
    }

    private func toggleContextTargets(_ task: SyncTask) {
        let targets = contextTargets(task)
        let makeEnabled = !targets.allSatisfy(\.enabled)
        for target in targets {
            center.update(target.id) { $0.enabled = makeEnabled }
        }
    }

    private func deletionTitle(_ tasks: [SyncTask]) -> String {
        tasks.count > 1 ? "要删除这 \(tasks.count) 个任务吗？" : "要删除这个同步任务吗？"
    }

    /// 确认框里的说明文字。删除任务**不会动目标文件夹里的文件**，这点必须讲清楚。
    private func deletionMessage(_ tasks: [SyncTask]) -> String {
        if tasks.count == 1, let task = tasks.first {
            return "「\(task.displayName)」这个任务和它的同步记录会被删除。已经同步到目标文件夹的文件不受影响。"
        }
        return "这 \(tasks.count) 个任务和它们的同步记录会被删除。已经同步到目标文件夹的文件不受影响。"
    }

    /// 用户在确认框里点了「删除」
    private func performDeletion(_ tasks: [SyncTask]) {
        for task in tasks { center.removeTask(task.id) }
        selection.removeAll()
        selectionAnchor = nil
        pendingDeletion = []
    }

    /// 工具栏副标题：显示**源文件夹**路径（同步是从它出发的）。
    /// 目标路径在表单的「目标文件夹」一行里看得到，不必在这里重复。
    private func detailSubtitle(_ task: SyncTask) -> String {
        guard task.isConfigured else { return "还没有选好源文件夹和目标文件夹" }
        return Fmt.prettyPath(task.sourceURL.path)
    }

    // MARK: - 气泡提示

    /// 操作结果气泡：原生液态玻璃材质，浮在内容顶部居中，出现/消失有轻微动画。
    /// 两种语气共用同一个外形，只换图标和颜色。
    /// 注意：不要在 glassSurface 之后再叠 .shadow —— 那会强制离屏渲染，
    /// 把玻璃材质压平，看起来就成了一块实心的白色胶囊。
    @ViewBuilder
    private var toastOverlay: some View {
        Group {
            if let text = center.toast {
                HStack(spacing: 7) {
                    Image(systemName: center.toastKind == .warning
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(center.toastKind == .warning ? Color.orange : Color.green)
                    Text(text)
                        .font(.system(size: 12.5))
                        .lineLimit(2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassSurface(Capsule(), interactive: false)
                .padding(.top, center.toolbarHeight + 10)
                .padding(.horizontal, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { center.dismissToast() }
            }
        }
        .animation(.easeOut(duration: 0.18), value: center.toast)
    }
}

// MARK: - 通用空状态

/// 左右两栏共用的空状态。两边用同一组常量，图标才会落在同一水平线。
struct EmptyHint: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.quaternary)
            Text(title)
                .font(.system(size: 13))
                // 不要写「30% 黑」：深色模式下会变成白底上的浅灰，看不见。
                .foregroundStyle(.primary.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 26)
    }
}

// MARK: - 列表行

/// 左栏选中底的圆角，量自右栏系统分组框（实测约 9pt），两边保持一致。
/// 系统分组框的圆角由 macOS 定、SwiftUI 拿不到，只能量出来对齐。
private let rowCornerRadius: CGFloat = 9

struct TaskRow: View {
    let task: SyncTask
    let isSelected: Bool
    let isRunning: Bool
    let progress: SyncProgress?
    /// 仅用于让行在文件夹可用性变化时重新渲染；状态本身仍实时读 FileManager。
    let folderAvailabilityRevision: Int

    var body: some View {
        let _ = folderAvailabilityRevision
        content
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                // 中性灰：浅色下是"黑 10%"，深色下自动变成"白 10%"，跟随系统外观
                RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous))
    }

    // 只保留一行：图标 + 文件夹名。
    // 目标路径、「多久前 · 新增/跳过」这些明细都收进右栏详情，列表保持干净。
    // 唯一的例外是「未配置 / 已暂停 / 未启用」和同步进度 —— 都属于不给提示
    // 就会让人困惑的信息，所以并到同一行的右侧，不再占第二行。

    /// 只有「任务启用 + 配置完整 + 文件夹当前不可用」才算因缺盘暂停；
    /// 用户主动关闭的任务显示「未启用」，不改橙色图标。
    private var folderUnavailable: Bool {
        task.isConfigured && task.enabled && !task.foldersAvailable
    }

    /// 未启用用灰色实心；未配置保持灰色线框，和「还没选文件夹」的状态一致。
    private var folderIconActive: Bool {
        task.isConfigured && task.enabled
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: task.isConfigured ? "folder.fill" : "folder")
                    .foregroundStyle(folderUnavailable
                                     ? Color.orange
                                     : (folderIconActive ? Color.accentColor : Color.secondary))
                    .font(.system(size: 12))
                Text(task.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)

                if !task.isConfigured {
                    Text("未配置")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                } else if !task.enabled {
                    Text("未启用")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if !task.foldersAvailable {
                    Text("已暂停")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }

            if isRunning, let progress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                Text("\(progress.phase) \(progress.completed)/\(progress.total)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                // 保留"上次同步时间"（没同步过时显示"从未同步"）；
                // 后面的"新增 N · 跳过 M"明细收进右栏「最近记录」。
                Text(Fmt.relative(task.lastRunAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
