import SwiftUI

/// macOS 26 引入的 Liquid Glass（液态玻璃）材质兼容层。
///
/// 最低支持 macOS 14，所以玻璃效果一律按可用性分支 ——
/// 新系统用真正的 `.glassEffect`，旧系统退回等价的原生材质，
/// 布局与交互完全一致，不会出现「旧系统上控件消失」。
///
/// 已核对的 SDK 签名（MacOSX27.0.sdk，均标注 @available(macOS 26.0, *)）：
///   func glassEffect(_ glass: Glass = .regular, in shape: some Shape) -> some View
///   struct GlassEffectContainer<Content: View>(spacing: CGFloat? = nil, content: () -> Content)
///
/// 注意：不要把 `if let` 套在 `#available` 里面写进 ViewBuilder ——
/// 当前 Swift 编译器会在这种嵌套上崩掉（failed to produce diagnostic）。
/// 所以玻璃参数先在外面算好、旧系统分支整块交给一个 ViewModifier，分支保持扁平。

@available(macOS 26.0, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint = tint {
        glass = glass.tint(tint)
    }
    if interactive {
        glass = glass.interactive()
    }
    return glass
}

/// 旧系统上的替身材质。给了着色就按「强调色实心 + 白字」画（等价于 .glassProminent 的观感），
/// 没给着色才用 regularMaterial —— 否则「立即同步」这类主按钮在旧系统上会丢掉强调色。
private struct FallbackGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color?

    func body(content: Content) -> some View {
        if let tint {
            content
                .background(shape.fill(tint))
                .overlay(shape.stroke(tint.opacity(0.55), lineWidth: 0.5))
                .foregroundStyle(.white)
        } else {
            content
                .background(shape.fill(.regularMaterial))
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }
}

extension View {

    /// 把控件放进一块液态玻璃里。interactive 打开后悬停/按下会有反应，适合按钮类控件；
    /// 给了 tint 就是主按钮（蓝色液态玻璃）。
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.modifier(FallbackGlassSurface(shape: shape, tint: tint))
        }
    }
}

/// 把相邻的玻璃控件放进同一个容器，让它们的玻璃能在视觉上互相融合、靠拢时连成一体。
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat?
    let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// 弹窗右上角的关闭按钮：只留一个 X 图标，不画背景。
///
/// 之前试过自绘圆钮（glassSurface(Circle())）和系统玻璃按钮样式（.buttonStyle(.glass)），
/// 在纯白的弹窗底上都读不出「液态玻璃」的质感（玻璃是半透明的，长什么样取决于背后是什么，
/// 弹窗底下没有工具栏那种带层次的背景可采）。既然做不像，就不做背景了。
///
/// 尺寸靠 frame + contentShape 撑出舒适的点击区域，X 本身保持图标大小。
struct CloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("关闭")
    }
}
