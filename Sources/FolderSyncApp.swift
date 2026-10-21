import SwiftUI
import AppKit
import Combine

/// 窗口和状态栏图标都由 AppDelegate 直接用 AppKit 管；App 入口是文件末尾的 SwiftUI `App`，
/// 因为设置窗要走 SwiftUI 的 `Settings { }` 场景（和 SketchSearch 一样）——
/// 只有那个场景才会创建真正的「设置」窗口：标签栏进标题栏、标题随当前页变化。
///
/// 为什么不用 SwiftUI 的 `MenuBarExtra`：它的 label 会被系统**快照成一张静态图片**贴进
/// NSStatusItem，任何动画都跑不起来 —— `.symbolEffect(.rotate)` 不行，按角度反复重画也不行。
/// （实测：定时器每秒 tick 10 次、角度确实在变，但状态栏图标一动不动。）
/// 要让图标真正旋转，只能用 AppKit 拿 NSStatusItem，给 button 的 layer 加 Core Animation。
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {

    /// SwiftUI 的 commands 里要调窗口方法，用它拿 delegate 实例
    static weak var shared: AppDelegate?

    private var windowController: NSWindowController?
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

/// 窗口关闭 = 收进菜单栏，而不是退出应用：
/// - 关窗后把激活策略切成 `.accessory`，程序坞不再显示图标，菜单栏图标继续驻留；
/// - 从菜单栏再打开主窗口时切回 `.regular`，图标跟着回来。
/// （`applicationShouldTerminateAfterLastWindowClosed` 返回 false，所以关窗本来就不会退出。）
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupStatusItem()
        observeSyncing()
        SyncCenter.shared.start()

        // 由 LaunchAgent 带 --autostart 拉起时，只驻留菜单栏、不弹窗口 ——
        // 没有窗口就对应没有程序坞图标，所以直接用 .accessory。
        if CommandLine.arguments.contains("--autostart") {
            NSApp.setActivationPolicy(.accessory)
        } else {
            showMainWindow()
        }
    }

    /// 主窗口被关掉（点红叉或 ⌘W）：不退出，只收进菜单栏
    func windowWillClose(_ notification: Notification) {
        // 等关闭动画走完再切策略，避免切换瞬间的闪烁
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        SyncCenter.shared.cancelAll()
        SyncCenter.shared.stop()
    }

    @objc func showMainWindow() {
        // 之前关窗时切成了 .accessory（无 Dock 图标），重新打开就切回来
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        buildWindowIfNeeded()
        // 菜单栏的动作是在 NSMenu 跟踪期间触发的：此时直接 order front，
        // 会被随后的菜单收尾流程吃掉 —— 表现就是点「打开主窗口」没反应。
        // 推到下一个 runloop（菜单已经关掉）再显示。
        DispatchQueue.main.async { [weak self] in
            self?.presentWindow()
        }
    }

    /// 真正把主窗口拿到台前。必须在菜单关闭之后调用（见 showMainWindow）。
    private func presentWindow() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)

        // 策略切换是异步生效的，首次激活可能被系统丢掉；补一次（这是已知的 AppKit 做法）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.windowController?.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func buildWindowIfNeeded() {
        if windowController == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered,
                                  defer: false)
            window.title = "FolderSync"
            window.minSize = NSSize(width: 880, height: 560)
            window.isReleasedWhenClosed = false
            // 需要在 windowWillClose 里收掉 Dock 图标
            window.delegate = self
            window.setFrameAutosaveName("FolderSyncMainWindow")
            window.center()
            window.contentView = NSHostingView(rootView: ContentView().environmentObject(SyncCenter.shared))
            windowController = NSWindowController(window: window)
        }
    }

    @objc private func syncAllNow() {
        SyncCenter.shared.syncAll(trigger: "manual")
    }

    @objc private func openConfigFolder() {
        NSWorkspace.shared.open(ConfigStore().directory)
    }

    /// 打开 SwiftUI 的「设置」窗口（⌘, 由系统菜单提供，这里给状态栏菜单用）
    @objc func openSettings() {
        SettingsOpener.shared.show()
    }

    /// 菜单里的「关于」直接打开设置窗的「关于」页 —— 一处维护，不再和系统关于面板重复
    @objc private func showAbout() {
        SettingsOpener.shared.show()
    }

    // MARK: - 状态栏图标

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // 图标外观固定，任何状态下都不换 —— 只有"转不转"的区别
            let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                accessibilityDescription: "FolderSync")
            image?.isTemplate = true
            button.image = image
            button.wantsLayer = true
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// 同步开始/结束时切换图标的旋转。
    ///
    /// 转的是 `statusItem.button` 的 layer：Core Animation 由系统驱动，
    /// 不用自己开定时器，也不会改变图标外观。这是 AppKit 里让状态栏图标旋转的标准做法。
    private func observeSyncing() {
        SyncCenter.shared.$runningTaskIDs
            .map { !$0.isEmpty }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] spinning in self?.setStatusIconSpinning(spinning) }
            .store(in: &cancellables)
    }

    private func setStatusIconSpinning(_ spinning: Bool) {
        guard let layer = statusItem?.button?.layer else { return }
        if spinning {
            guard layer.animation(forKey: "spin") == nil else { return }

            // 关键：AppKit 给「视图支撑的 layer」用的锚点是 (0,0)（左下角），
            // 直接加旋转会绕着左下角转，图标会被甩出状态栏。
            // 改成绕中心 (0.5, 0.5) 转，并同步 position —— anchorPoint 一变，
            // layer 的 frame 会跟着漂，必须把 position 重新设到原来的中心，
            // 图标才会「原地自转」而不是「平移着转」。
            let frame = layer.frame
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: frame.midX, y: frame.midY)

            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = 0
            animation.toValue = -2 * Double.pi
            animation.duration = 1.1
            animation.repeatCount = .infinity
            layer.add(animation, forKey: "spin")
        } else {
            layer.removeAnimation(forKey: "spin")
            // 交回 AppKit 的默认约定：锚点归位到左下角，position 同步跟上
            let frame = layer.frame
            layer.anchorPoint = CGPoint(x: 0, y: 0)
            layer.position = CGPoint(x: frame.minX, y: frame.minY)
        }
    }

    // MARK: - 状态栏菜单

    /// 每次弹出前重建整个菜单 —— 任务列表、进度、同步状态都是动态的
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let center = SyncCenter.shared

        // 状态栏菜单里不标快捷键（⌘O / ⌘R / ⌘,）—— 菜单一关它们也按不了，
        // 显示出来只是占地方；应用菜单栏里那几个仍然有效。
        menu.addItem(menuItem("打开主窗口", #selector(showMainWindow)))
        menu.addItem(menuItem("立即同步全部", #selector(syncAllNow),
                              enabled: !center.tasks.isEmpty))
        if center.isSyncingAnything {
            menu.addItem(menuItem("取消正在进行的同步", #selector(cancelAllNow)))
        }

        menu.addItem(.separator())

        if center.tasks.isEmpty {
            menu.addItem(disabledItem("还没有同步任务"))
        } else {
            for task in center.tasks {
                // 只显示任务名 —— 上次同步的结果（"新增 N" / "无变动"）不在这里重复，
                // 点开子菜单就能看到；⏳/⏸ 这些状态前缀同样去掉。
                let parent = NSMenuItem(title: task.displayName, action: nil, keyEquivalent: "")
                parent.submenu = statusSubmenu(for: task)
                menu.addItem(parent)
            }
        }

        menu.addItem(.separator())
        let settingsItem = menuItem("设置…", #selector(openSettings))
        // 系统会给「设置…」这类菜单项自动配一个齿轮图标；这里明确不要图标
        // （NSMenuItem 只有 image，没有 imagePosition —— 那是 NSCell 的）
        settingsItem.image = nil
        menu.addItem(settingsItem)
        menu.addItem(menuItem("退出", #selector(terminateApp), key: "q"))
    }

    private func statusSubmenu(for task: SyncTask) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(disabledItem(task.isConfigured
                                  ? Fmt.prettyPath(task.destinationURL.path)
                                  : "未配置源文件夹或目标文件夹"))
        menu.addItem(disabledItem(task.enabled ? task.schedule.summary : "任务已暂停"))
        menu.addItem(.separator())
        menu.addItem(menuItem("立即同步", #selector(syncTaskNow(_:)), represented: task.id))
        menu.addItem(menuItem("预览改动", #selector(previewTask(_:)), represented: task.id))
        let toggle = menuItem("启用任务", #selector(toggleTask(_:)), represented: task.id)
        toggle.state = task.enabled ? .on : .off
        menu.addItem(toggle)
        return menu
    }

    private func menuItem(_ title: String,
                          _ action: Selector,
                          key: String = "",
                          enabled: Bool = true,
                          represented: UUID? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        item.representedObject = represented
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func syncTaskNow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        SyncCenter.shared.syncNow(id)
    }

    @objc private func previewTask(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        showMainWindow()
        // 窗口是在下一个 runloop 才显示的，预览结果挂在窗口上，所以往后排一步
        DispatchQueue.main.async { SyncCenter.shared.requestPreview(id) }
    }

    @objc private func toggleTask(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        SyncCenter.shared.update(id) { $0.enabled.toggle() }
    }

    @objc private func cancelAllNow() { SyncCenter.shared.cancelAll() }

    @objc private func terminateApp() { NSApp.terminate(nil) }

}

/// App 入口。
///
/// 只声明 `Settings { }` 一个场景：主窗口与状态栏图标仍由 `AppDelegate` 用 AppKit 管，
/// 自定义毛玻璃工具栏、全屏处理、状态栏旋转动画都不受影响。
/// 设置窗交给系统，外观与 SketchSearch 完全一致。
@main
struct FolderSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(SyncCenter.shared)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("文件") {
                Button("打开主窗口") { AppDelegate.shared?.showMainWindow() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("立即同步全部") { SyncCenter.shared.syncAll() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("关闭窗口") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }
    }
}
