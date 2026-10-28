import Foundation
import Combine
import SwiftUI
import AppKit

struct PlanPreview: Identifiable {
    let id: UUID
    /// 目标路径弹出时就能确定，先显示出来 —— 不必等计划算完。
    var destinationPath: String
    /// nil 表示**还在计算中**：弹窗先出来显示进度，算完再回填。
    /// 之前是"算完才弹窗"，同步大目录时要等好几秒，用户点了会以为没反应。
    var plan: SyncPlan?
    var createdAt: Date
}

enum ToastKind {
    case success
    case warning
}

/// 全局状态中心。
///
/// 约定：所有对 `@Published` 属性的读写都发生在主线程。
/// 后台线程只负责跑 `SyncEngine`，结果通过 `DispatchQueue.main.async` 回传。
final class SyncCenter: ObservableObject {
    static let shared = SyncCenter()

    @Published private(set) var tasks: [SyncTask] = []
    @Published private(set) var history: [SyncRun] = []
    /// 同步时遇到「没有访问权限」→ 界面弹窗引导用户去系统设置授权。
    @Published var permissionRequest: PermissionRequest?

    @Published private(set) var runningTaskIDs: Set<UUID> = []
    @Published private(set) var activeProgress: [UUID: SyncProgress] = [:]
    @Published private(set) var previewLoading: Set<UUID> = []
    @Published private(set) var recentRun: SyncRun?

    /// 文件系统变化（挂载/卸载外接盘、删除文件夹）不会自动触发 SwiftUI 更新。
    /// 这个版本号在文件夹可用性变化时递增，让左侧列表和右侧详情重新读取状态。
    @Published private(set) var folderAvailabilityRevision = 0
    private var folderAvailabilityTimer: Timer?
    private var lastFolderAvailability: [UUID: Bool] = [:]
    private var folderAvailabilityObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []


    /// 是否处于全屏。右栏顶部那条毛玻璃在全屏时不画（见 ContentView.detailPane）。
    @Published private(set) var isFullScreen = false

    @Published var preview: PlanPreview?
    @Published var toast: String?
    @Published private(set) var toastKind: ToastKind = .success
    /// 设置弹窗的显示开关。主窗口工具栏的齿轮、菜单「设置…」（⌘,）、菜单栏图标都改这个值。

    /// 标题栏 + 工具栏的总高度。用来给内容留白、也是左右两块空状态的居中基准，
    /// 这样两边的图标才能落在同一水平线上。
    @Published private(set) var toolbarHeight: CGFloat = 52

    private weak var mainWindow: NSWindow?
    private var toastWorkItem: DispatchWorkItem?
    private var windowObservers: [NSObjectProtocol] = []

    @Published var runAtLogin: Bool = false {
        didSet {
            guard !isLoading else { return }
            if runAtLogin {
                if let error = LoginItem.enable() {
                    showToast("设置开机自启失败：\(error)", kind: .warning)
                    runAtLogin = false
                    return
                }
                showToast("已开启登录时自动启动")
            } else {
                LoginItem.disable()
                showToast("已关闭登录时自动启动")
            }
            saveConfig()
        }
    }

    @Published var notificationsEnabled: Bool = true {
        didSet {
            guard !isLoading else { return }
            saveConfig()
        }
    }

    private let store = ConfigStore()
    private var checkTimer: Timer?
    private var cancellations: [UUID: SyncCancellation] = [:]
    private var isLoading = false

    private init() {
        isLoading = true
        let config = store.loadConfig()
        tasks = config.tasks
        runAtLogin = config.runAtLogin
        notificationsEnabled = config.notificationsEnabled
        history = store.loadHistory()
        isLoading = false
    }

    // MARK: - 生命周期

    func start() {
        LoginItem.refreshIfNeeded()
        scheduleTimer()
        startFolderAvailabilityMonitor()
        Notifier.shared.prepare()
    }

    func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
        folderAvailabilityTimer?.invalidate()
        folderAvailabilityTimer = nil
        for entry in folderAvailabilityObservers {
            entry.center.removeObserver(entry.token)
        }
        folderAvailabilityObservers.removeAll()
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    // MARK: - 文件夹可用性

    /// 2 秒轮询一次文件夹状态，并额外监听外接盘挂载/卸载和 App 激活，
    /// 让左侧任务列表不必切换任务就能显示「已暂停」。
    private func startFolderAvailabilityMonitor() {
        guard folderAvailabilityTimer == nil else { return }
        refreshFolderAvailability(force: true)

        folderAvailabilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshFolderAvailability() }
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshFolderAvailability(force: true)
            }
            folderAvailabilityObservers.append((workspaceCenter, token))
        }
        let appToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshFolderAvailability(force: true)
        }
        folderAvailabilityObservers.append((NotificationCenter.default, appToken))
    }

    private func refreshFolderAvailability(force: Bool = false) {
        var snapshot: [UUID: Bool] = [:]
        snapshot.reserveCapacity(tasks.count)
        for task in tasks {
            snapshot[task.id] = task.foldersAvailable
        }
        guard force || snapshot != lastFolderAvailability else { return }
        lastFolderAvailability = snapshot
        folderAvailabilityRevision &+= 1
    }

    // MARK: - 窗口接管

    /// 拿到主窗口后做几件事（每一条都是实测结论）：
    ///
    /// - `titlebarSeparatorStyle = .none`：去掉工具栏底部那条分隔线；
    /// - `fullSizeContentView` + `titlebarAppearsTransparent`：内容铺满整个窗口，
    ///   侧栏才能真正延伸到窗口最顶（交通灯落在侧栏里），工具栏材质不会在它上面留一条底色；
    /// - `backgroundColor = .textBackgroundColor`：全屏时工具栏隐藏，内容万一没盖满，
    ///   露出来的就是这层底色 —— 用系统窗口灰会和内容区形成一条色差带；
    /// - `toolbarHeight`（= 窗口高 - contentLayoutRect 高）是标题栏+工具栏的总高度，
    ///   注意允许归零：以前写成「大于 0 才更新」，一旦某个窗口状态真的返回 0
    ///   就会永远残留旧值，把内容与居中基准整体推偏。
    func adoptMainWindow(_ window: NSWindow?) {
        guard let window else { return }
        mainWindow = window
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .textBackgroundColor
        refreshToolbarHeight()


        // 全屏切换后 AppKit 会重建工具栏，所以要重新设一遍并重新测量
        guard windowObservers.isEmpty else { return }
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification
        ]
        for name in names {
            let observer = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.reapplyChrome()
                // 工具栏重建是异步的，过一小会儿再设一次
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.reapplyChrome()
                }
            }
            windowObservers.append(observer)
        }
    }

    private func reapplyChrome() {
        guard let window = mainWindow else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        if fullScreen != isFullScreen { isFullScreen = fullScreen }
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .textBackgroundColor
        refreshToolbarHeight()

    }

    private func refreshToolbarHeight() {
        guard let window = mainWindow else { return }
        let chrome = max(0, window.frame.height - window.contentLayoutRect.height)
        if abs(chrome - toolbarHeight) > 0.5 {
            toolbarHeight = chrome
        }
    }

    // MARK: - 气泡提示

    func showToast(_ text: String, kind: ToastKind = .success) {
        toastWorkItem?.cancel()
        toastKind = kind
        toast = text
        let item = DispatchWorkItem { [weak self] in
            self?.toast = nil
        }
        toastWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (kind == .warning ? 8 : 3), execute: item)
    }

    func dismissToast() {
        toastWorkItem?.cancel()
        toast = nil
    }

    private func scheduleTimer() {
        checkTimer?.invalidate()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            self?.evaluateSchedules()
        }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    private func evaluateSchedules() {
        let now = Date()
        for task in tasks where task.enabled && task.isConfigured && task.schedule.mode != .manual {
            if runningTaskIDs.contains(task.id) { continue }
            if task.schedule.dueState(lastRun: task.lastRunAt, now: now).due {
                syncNow(task.id, trigger: "timer")
            }
        }
    }

    // MARK: - 任务管理

    func addTask() -> SyncTask {
        let task = SyncTask()
        if let first = tasks.first(where: { $0.sourcePath.isEmpty }) {
            return first
        }
        tasks.append(task)
        saveConfig()
        return task
    }

    /// 选文件夹时当场发现没有权限：立刻弹授权引导（不必等到同步失败）
    func reportPermissionIssue(folder: String, atPicker: Bool = false) {
        permissionRequest = PermissionRequest(taskID: nil, taskName: "", folder: folder, atPicker: atPicker)
    }

    /// 拖动排序：把第 from 个任务移到第 to 个位置。
    /// 列表顺序即任务顺序，改完立即写回 config.json，重启后保持。
    func moveTask(from: Int, to: Int) {
        guard tasks.indices.contains(from), tasks.indices.contains(to), from != to else { return }
        var list = tasks
        let task = list.remove(at: from)
        // 删掉之后目标下标最多越界 1 位（拖到最后），夹一下即可
        list.insert(task, at: min(to, list.count))
        tasks = list
        saveConfig()
    }

    func removeTask(_ id: UUID) {
        cancel(id)
        tasks.removeAll { $0.id == id }
        history.removeAll { $0.taskID == id }
        if preview?.id == id { preview = nil }
        saveConfig()
        store.saveHistory(history)
    }

    func duplicate(_ id: UUID) {
        guard var copy = tasks.first(where: { $0.id == id }) else { return }
        copy.id = UUID()
        copy.lastRunAt = nil
        copy.lastSummary = nil
        tasks.append(copy)
        saveConfig()
    }

    func task(with id: UUID) -> SyncTask? {
        tasks.first { $0.id == id }
    }

    func binding(for id: UUID) -> Binding<SyncTask>? {
        guard tasks.contains(where: { $0.id == id }) else { return nil }
        let getter: () -> SyncTask = { [weak self] in
            guard let self, let current = self.tasks.first(where: { $0.id == id }) else { return SyncTask() }
            return current
        }
        let setter: (SyncTask) -> Void = { [weak self] value in
            guard let self, let index = self.tasks.firstIndex(where: { $0.id == id }) else { return }
            self.tasks[index] = value
            self.saveConfig()
        }
        return Binding(get: getter, set: setter)
    }

    /// 直接改任务（用于详情页里的各种开关）。
    func update(_ id: UUID, _ mutate: (inout SyncTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tasks[index])
        saveConfig()
    }

    // MARK: - 同步

    func options(for task: SyncTask) -> SyncOptions {
        SyncOptions(mode: task.mode,
                    skipHiddenFiles: task.skipHiddenFiles,
                    ignoreSystemFiles: task.ignoreSystemFiles,
                    excludePatterns: task.exclusionPatterns)
    }

    func syncNow(_ id: UUID, trigger: String = "manual") {
        guard !runningTaskIDs.contains(id) else { return }
        guard let task = task(with: id) else { return }
        guard task.isConfigured else {
            showToast("这个任务还没选好源文件夹和目标文件夹。", kind: .warning)
            return
        }
        // 源/目标文件夹任意一端不存在时，只提示异常，不创建运行记录也不碰目标文件。
        guard task.foldersAvailable else {
            if trigger == "manual" {
                showToast("\(task.displayName)：源文件夹或目标文件夹不存在，已暂停同步。", kind: .warning)
            }
            return
        }

        let request = SyncRequest(source: task.sourceURL,
                                  destination: task.destinationURL,
                                  destinationRoot: task.destinationRootURL,
                                  options: options(for: task))
        let displayName = task.displayName
        let cancellation = SyncCancellation()

        runningTaskIDs.insert(id)
        cancellations[id] = cancellation
        activeProgress[id] = SyncProgress(phase: "准备中…", currentPath: "", completed: 0, total: 0)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let run = SyncEngine.run(request: request,
                                     taskID: id,
                                     taskName: displayName,
                                     trigger: trigger,
                                     cancellation: cancellation) { progress in
                DispatchQueue.main.async {
                    self?.activeProgress[id] = progress
                }
            }
            DispatchQueue.main.async {
                self?.finish(run)
            }
        }
    }

    func syncAll(trigger: String = "manual") {
        let candidates = tasks.filter { $0.enabled && $0.isConfigured }
        let runnable = candidates.filter(\.foldersAvailable)
        let blocked = candidates.filter { !$0.foldersAvailable }
        if trigger == "manual", !blocked.isEmpty {
            showToast("有 \(blocked.count) 个任务的源文件夹或目标文件夹不存在，已暂停同步。", kind: .warning)
        }
        for task in runnable {
            syncNow(task.id, trigger: trigger)
        }
    }

    func cancel(_ id: UUID) {
        cancellations[id]?.cancel()
    }

    func cancelAll() {
        for cancellation in cancellations.values { cancellation.cancel() }
    }

    private func finish(_ run: SyncRun) {
        runningTaskIDs.remove(run.taskID)
        cancellations.removeValue(forKey: run.taskID)
        activeProgress.removeValue(forKey: run.taskID)
        recentRun = run

        // 权限问题：不只是记一条失败，而是弹窗让用户去授权
        if run.needsAuthorization == true {
            permissionRequest = PermissionRequest(taskID: run.taskID,
                                                 taskName: run.taskName,
                                                 folder: run.destinationPath)
        }

        history.insert(run, at: 0)
        if history.count > 300 { history.removeLast(history.count - 300) }

        if let index = tasks.firstIndex(where: { $0.id == run.taskID }) {
            tasks[index].lastRunAt = run.finishedAt ?? Date()
            tasks[index].lastSummary = run.brief
        }

        saveConfig()
        store.saveHistory(history)

        // 出问题用橙色警告气泡（停留更久），正常完成用绿色气泡；都不打断用户
        switch run.outcome {
        case .failed:
            showToast("\(run.taskName)：\(run.brief)", kind: .warning)
        case .partial:
            showToast("\(run.taskName)：\(run.brief)", kind: .warning)
        case .success:
            showToast("\(run.taskName)：\(run.brief)")
        case .cancelled:
            showToast("\(run.taskName)：已取消", kind: .warning)
        }

        if notificationsEnabled, run.trigger != "manual" || run.outcome != .success {
            Notifier.shared.post(title: run.outcome == .failed ? "同步失败：\(run.taskName)" : "同步完成：\(run.taskName)",
                                 body: run.brief)
        }
    }

    // MARK: - 预览

    func requestPreview(_ id: UUID) {
        guard let task = task(with: id), task.isConfigured else {
            showToast("这个任务还没选好源文件夹和目标文件夹。", kind: .warning)
            return
        }
        guard !previewLoading.contains(id) else { return }
        previewLoading.insert(id)

        // 先把弹窗弹出来（plan 为 nil = 计算中），别让用户点了没反应
        preview = PlanPreview(id: id,
                              destinationPath: task.destinationURL.path,
                              plan: nil,
                              createdAt: Date())

        let source = task.sourceURL
        let destination = task.destinationURL
        let destinationRoot = task.destinationRootURL
        let options = options(for: task)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plan = SyncPlanner.makePlan(source: source,
                                            destination: destination,
                                            options: options,
                                            requiredRoot: destinationRoot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.previewLoading.remove(id)
                // 只在这个弹窗还开着、而且仍是同一个任务时才回填
                guard var current = self.preview, current.id == id else { return }
                current.plan = plan
                self.preview = current
            }
        }
    }

    // MARK: - 辅助

    func nextRunDate(for task: SyncTask) -> Date? {
        guard task.enabled else { return nil }
        return task.schedule.dueState(lastRun: task.lastRunAt).next
    }

    func lastRun(for taskID: UUID) -> SyncRun? {
        history.first { $0.taskID == taskID }
    }

    /// 清空同步记录。
    ///
    /// 传 `taskID` 只清那个任务的记录；不传（nil）才清空全部。
    /// 之前是无条件 `history.removeAll()`，所以在单个任务的「同步记录」弹窗里点清空，
    /// 会把**所有任务**的记录一起删掉。
    func clearHistory(for taskID: UUID? = nil) {
        if let taskID {
            history.removeAll { $0.taskID == taskID }
        } else {
            history.removeAll()
        }
        store.saveHistory(history)
    }

    private func saveConfig() {
        guard !isLoading else { return }
        var config = AppConfig()
        config.tasks = tasks
        config.runAtLogin = runAtLogin
        config.notificationsEnabled = notificationsEnabled
        store.save(config)
    }

    var isSyncingAnything: Bool { !runningTaskIDs.isEmpty }
}

/// 一次「需要用户授权」的请求：目标文件夹不可写，界面据此弹窗引导去系统设置。
struct PermissionRequest: Identifiable {
    let id = UUID()
    let taskID: UUID?
    let taskName: String
    let folder: String
    /// true = 选文件夹时当场探到的（还没建任务）
    var atPicker: Bool = false
}
