import Foundation

/// 配置与历史记录落盘在 ~/Library/Application Support/FolderSync/
struct ConfigStore {
    let directory: URL

    init() {
        // 默认放在 ~/Library/Application Support/FolderSync/；
        // 也可以用 FOLDERSYNC_CONFIG_DIR 指定别的目录（多套配置、自动化测试用）。
        if let override = ProcessInfo.processInfo.environment["FOLDERSYNC_CONFIG_DIR"], !override.isEmpty {
            directory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            directory = base.appendingPathComponent("FolderSync", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var configURL: URL { directory.appendingPathComponent("config.json") }
    var historyURL: URL { directory.appendingPathComponent("history.json") }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func loadConfig() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL) else { return AppConfig() }
        do {
            return try Self.makeDecoder().decode(AppConfig.self, from: data)
        } catch {
            // 配置损坏时备份一份，避免用户数据被直接覆盖丢失
            let backup = configURL.appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: configURL, to: backup)
            NSLog("FolderSync: 配置解析失败，已备份到 \(backup.path)：\(error)")
            return AppConfig()
        }
    }

    func save(_ config: AppConfig) {
        do {
            let data = try Self.makeEncoder().encode(config)
            try data.write(to: configURL, options: .atomic)
        } catch {
            NSLog("FolderSync: 保存配置失败 \(error)")
        }
    }

    func loadHistory() -> [SyncRun] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        return (try? Self.makeDecoder().decode([SyncRun].self, from: data)) ?? []
    }

    func saveHistory(_ runs: [SyncRun]) {
        do {
            let data = try Self.makeEncoder().encode(runs)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            NSLog("FolderSync: 保存历史失败 \(error)")
        }
    }
}
