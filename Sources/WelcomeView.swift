import SwiftUI
import AppKit

/// 首次启动的欢迎页：引导用户选好「源文件夹 → 目标文件夹」，直接建好第一个任务。
///
/// 结构和间距完全照搬 SketchSearch 的 `FirstRunView`（同一套骨架）：
///
///     VStack(alignment: .leading, spacing: 16) {
///         header        // 图标 + 标题 + 副标题（居中）
///         hint          // 「文件夹」+ 说明（普通 VStack，占容器全宽）
///         folderList    // 自绘圆角框，两行「源 / 目标文件夹」
///         bottomBar     // 左「跳过」右「创建同步任务」
///     }
///     .padding(22)
///
/// 关键点：hint 和 folderList 在同一个 VStack 里、共用同一个容器留白，
/// 所以文字的显示宽度和下方控件**天然一致**，不需要任何补偿。
/// 之前用 `Form` + `Section` 时，分组框由系统绘制、横向内缩不受我们控制，
/// 才会出现「文字和框不一样宽、怎么调都差一点」的问题。
struct WelcomeView: View {
    /// 关闭（取消，或已经建好任务）
    var onClose: () -> Void
    @EnvironmentObject private var center: SyncCenter

    @State private var sourcePath = ""
    @State private var destinationPath = ""

    /// 与主界面底部按钮一致的高度（38）
    private static let barButtonHeight: CGFloat = 38

    /// 选好两个不同目录才能收尾
    private var canFinish: Bool {
        !sourcePath.isEmpty && !destinationPath.isEmpty && sourcePath != destinationPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            hint
            folderList

            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        onClose()
                    } label: {
                        Label("跳过", systemImage: "chevron.forward")
                            .font(.system(size: 13))
                            .padding(.horizontal, 14)
                            .frame(height: Self.barButtonHeight)
                            .glassSurface(Capsule(), interactive: true)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 8)

                    Button {
                        finish()
                    } label: {
                        Label("创建同步任务", systemImage: "checkmark")
                            .font(.system(size: 13, weight: .medium))
                            // 禁用时不着色、文字转灰 —— 玻璃不吃 .opacity，
                            // 光降透明度的话蓝色高亮仍在（SketchSearch 那边踩过）。
                            .foregroundStyle(canFinish ? Color.white : Color.secondary)
                            .padding(.horizontal, 16)
                            .frame(height: Self.barButtonHeight)
                            .glassSurface(Capsule(),
                                          tint: canFinish ? .accentColor : nil,
                                          interactive: canFinish)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canFinish)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    // MARK: - 头部（图标 + 标题 + 副标题，居中）

    private var header: some View {
        // 关闭按钮用 ZStack 浮在右上角，不参与居中布局（否则会把整块挤偏）。
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 10) {
                appIcon
                Text("欢迎使用FolderSync")
                    .font(.title3.bold())
                Text("将本地文件自动备份到移动存储设备")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 6)
            .padding(.bottom, 12)

            CloseButton { onClose() }
                .padding(.top, -4)
                .padding(.trailing, -6)
        }
    }

    private var appIcon: some View {
        AppIconImage(size: 64)
    }

    // MARK: - 说明（与下方列表共用同一个容器留白，故宽度一致）

    private var hint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("文件夹")
                .font(.headline)
            Text("选择需要备份的源文件夹和目标文件夹，FolderSync 会在目标文件夹下自动创建"
                 + "与源文件夹同名的同步文件夹。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 两个文件夹（自绘圆角框，同 SketchSearch 的 folderList）

    private var folderList: some View {
        VStack(spacing: 0) {
            folderRow(title: "源文件夹",
                      path: sourcePath,
                      add: { chooseSource() })
            // 分隔线：0.5pt 细线（2x 屏上就是 1 物理像素），两端与行内文字对齐（缩进 10pt）。
            // 用 Rectangle 而不是 Divider —— Divider 的粗细由系统决定，改不了。
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 0.5)
                .padding(.horizontal, 10)
            folderRow(title: "目标文件夹",
                      path: destinationPath,
                      add: { chooseDestination() })
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func folderRow(title: String,
                           path: String,
                           add: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 12)
            PathText(path: path)
            Button {
                add()
            } label: {
                Text("选择文件夹").frame(height: 16)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    // MARK: - 动作

    private func chooseSource() {
        FolderPicker.choose(title: "选择要同步的源文件夹",
                            message: "这个文件夹里的内容会被同步到目标文件夹。",
                            current: sourcePath) { url in
            if let url { sourcePath = url.path }
        }
    }

    private func chooseDestination() {
        FolderPicker.choose(title: "选择目标文件夹",
                            message: "通常选移动硬盘的根目录，App 会在里面自动创建同名文件夹。",
                            current: destinationPath,
                            needsWrite: true) { url in
            if let url { destinationPath = url.path }
        }
    }

    private func finish() {
        let task = center.addTask()
        center.update(task.id) {
            $0.sourcePath = sourcePath
            $0.destinationRoot = destinationPath
        }
        onClose()
    }
}
