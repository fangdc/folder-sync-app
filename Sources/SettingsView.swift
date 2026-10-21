import SwiftUI
import AppKit

// 设置窗。结构和 SketchSearch 的 SettingsView 完全一致：
// 一个 struct + 两个 private var 计算属性（每页一个 `.formStyle(.grouped)` 的 Form）
// + 裸 `TabView { }`（不绑 selection）。窗口由 SwiftUI 的 `Settings { }` 场景创建，
// 所以 TabView 在这里就是真正的「标签栏进标题栏」样式（图标 + 文字，标题随页变化）。

struct SettingsView: View {
    @EnvironmentObject private var center: SyncCenter

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("通用", systemImage: "gearshape") }
            aboutTab
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 460)
    }

    // MARK: - 通用（启动与通知 + 本机数据）

    private var configDirectory: URL { ConfigStore().directory }

    private var generalTab: some View {
        Form {
            Section {
                Toggle("登录时自动启动", isOn: $center.runAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Toggle("同步完成后发送系统通知", isOn: $center.notificationsEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            } header: {
                Text("启动与通知")
            } footer: {
                Text("开启「登录时自动启动」后，App 会常驻菜单栏；关掉主窗口也不会退出，"
                     + "各任务仍按自己的频率同步。")
            }

            Section {
                SettingsRow(title: "配置文件目录") {
                    // 必须限定 1 行：设成 lineLimit(2) 时 Text 的「理想宽度」是两行均衡的宽度
                    // （约 150pt），于是它主动折行；限定 1 行后理想宽度变回整串（约 290pt），
                    // 这一行右边可用宽度够放，既是一行也不会被截断。
                    Text(Fmt.prettyPath(configDirectory.path))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                SettingsRow(title: "内容") {
                    Text("\(center.tasks.count) 个任务 · \(center.history.count) 条记录")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button("打开配置文件目录") {
                        NSWorkspace.shared.open(configDirectory)
                    }
                    .controlSize(.small)

                    Button("复制路径") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configDirectory.path, forType: .string)
                        center.showToast("配置目录路径已复制")
                    }
                    .controlSize(.small)

                    Spacer()
                }
            } header: {
                Text("本机数据")
            } footer: {
                Text("config.json 是任务配置，history.json 是同步记录。"
                     + "换电脑时把这两个文件拷过去，任务就都回来了。")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 关于

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var aboutTab: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    AppIconImage(size: 64)
                    Text("FolderSync")
                        .font(.title3.weight(.semibold))
                    Text("版本 \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }

            Section {
                SettingsRow(title: "开发者") {
                    valueText("DACONG")
                }
                SettingsRow(title: "许可") {
                    valueText("MIT License")
                }
            } header: {
                Text("信息")
            }
        }
        .formStyle(.grouped)
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}
