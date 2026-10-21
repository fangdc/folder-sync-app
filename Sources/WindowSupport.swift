import AppKit
import SwiftUI

// MARK: - 拿到承载本视图的窗口
//
// 这个文件里只留真正被用到的那个组件。
// 早先还放过 measureBarHeight / NativeSearchField 之类的辅助件，
// 现在都用不到（顶部气泡走 GlassSupport 的 glassSurface，侧栏也没有搜索框），已删掉。

/// 把承载当前视图的 NSWindow 回传给调用方，用来做标题栏 / 工具栏定制。
///
/// 视图刚创建时通常还没挂到窗口上，所以要隔一段时间重试几次。
struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        retry(for: view, attempt: 0)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.callback(nsView.window) }
    }

    private func retry(for view: NSView, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.25)) {
            if let window = view.window {
                self.callback(window)
            } else if attempt < 8 {
                self.retry(for: view, attempt: attempt + 1)
            }
        }
    }
}

// MARK: - 系统原生毛玻璃

/// 系统原生毛玻璃（`NSVisualEffectView`）—— 标准包装。
///
/// 为什么不用 SwiftUI 的 Material：SwiftUI 的 Material 只能采样**窗口内部**的内容，
/// 底色一铺就采出一片灰；AppKit 的 `NSVisualEffectView` 配合 `blendingMode`
/// 才能做出 Finder / SF Symbols 工具栏那种通透感。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .headerView
    var blending: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
