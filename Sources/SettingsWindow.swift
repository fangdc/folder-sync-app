import SwiftUI
import AppKit

/// 打开「设置」窗口。
///
/// 窗口由 SwiftUI 的 `Settings { }` 场景创建（和 SketchSearch 一样），所以要「触发系统那条
/// 打开设置的动作」而不是自己开窗。
///
/// 注意：`NSApp.showSettingsWindow(_:)` 这个 selector **不存在**（运行时查证过，
/// NSApplication 不响应该 selector），`sendAction("showSettingsWindow:")` 会静默失败 ——
/// 之前点齿轮毫无反应就是这个原因。
/// 可靠的做法是直接触发应用菜单里系统生成的「设置…」项（就是 ⌘, 那一项）。
final class SettingsOpener {
    static let shared = SettingsOpener()

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if triggerSettingsMenuItem() { return }
        // 兜底：少数系统上菜单还没建好，退回到响应链
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// 在应用菜单里找「设置…」项并执行它（系统保证这一项存在且带 ⌘,）。
    @discardableResult
    private func triggerSettingsMenuItem() -> Bool {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return false }
        for item in appMenu.items {
            let isSettings = item.keyEquivalent == ","
                && item.keyEquivalentModifierMask.contains(.command)
            guard isSettings, let action = item.action else { continue }
            return NSApp.sendAction(action, to: item.target, from: item)
        }
        return false
    }
}
