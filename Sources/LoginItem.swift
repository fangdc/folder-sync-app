import Foundation

/// 通过 LaunchAgent 实现「登录时自动启动」。
///
/// 没有用 SMAppService：那个接口要求 App 位于 /Applications 且签名完整，
/// 本地自编译的 App 用 LaunchAgent 更稳。缺点是被移动位置后需要重新注册，
/// 所以每次启动都会校验一次路径。
enum LoginItem {
    static let label = "local.foldersync.autostart"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static var registeredExecutablePath: String? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let arguments = dictionary["ProgramArguments"] as? [String],
              let first = arguments.first else { return nil }
        return first
    }

    static var currentExecutablePath: String {
        if let path = Bundle.main.executablePath { return path }
        return CommandLine.arguments.first ?? ""
    }

    @discardableResult
    static func enable() -> String? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [currentExecutablePath, "--autostart"],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
                "LimitLoadToSessionType": "Aqua"
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            reload()
            return nil
        } catch {
            return Fmt.errorText(error)
        }
    }

    static func disable() {
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// App 被移动过（或注册项被系统清理）时重新写入。
    static func refreshIfNeeded() {
        guard isEnabled else { return }
        if registeredExecutablePath != currentExecutablePath {
            _ = enable()
        } else {
            reload()
        }
    }

    private static func reload() {
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())", plistURL.path])
        _ = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return -1 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
