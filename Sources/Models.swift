import Foundation

// MARK: - 同步模式

/// 目标目录中「源里没有」的文件如何处理。
enum SyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 只复制新增 / 修改过的文件，绝不在目标删除任何东西。
    case additive
    /// 目标与源严格一致，源里删掉的文件在目标也会被删除。
    case mirror

    var id: String { rawValue }

    var title: String {
        switch self {
        case .additive: return "增量同步"
        case .mirror: return "镜像同步"
        }
    }

    var summary: String {
        switch self {
        case .additive:
            return "只对新增或修改的内容进行同步，源文件夹删除内容，目标文件夹不会同步删除。"
        case .mirror:
            return "对新增、修改或删除的内容都进行同步，源文件夹删除内容，目标文件夹也会同步删除，请注意备份！"
        }
    }
}

// MARK: - 同步计划

enum ScheduleMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual
    case interval
    case daily

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "仅手动"
        case .interval: return "按间隔"
        case .daily: return "每天定时"
        }
    }
}

struct SyncSchedule: Codable, Hashable, Sendable {
    var mode: ScheduleMode = .manual
    var intervalMinutes: Int = 30
    var dailyHour: Int = 3
    var dailyMinute: Int = 0

    init() {}

    init(mode: ScheduleMode, intervalMinutes: Int = 30, dailyHour: Int = 3, dailyMinute: Int = 0) {
        self.mode = mode
        self.intervalMinutes = intervalMinutes
        self.dailyHour = dailyHour
        self.dailyMinute = dailyMinute
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? container.decodeIfPresent(ScheduleMode.self, forKey: .mode)) .flatMap { $0 } ?? .manual
        intervalMinutes = (try? container.decodeIfPresent(Int.self, forKey: .intervalMinutes)).flatMap { $0 } ?? 30
        dailyHour = (try? container.decodeIfPresent(Int.self, forKey: .dailyHour)).flatMap { $0 } ?? 3
        dailyMinute = (try? container.decodeIfPresent(Int.self, forKey: .dailyMinute)).flatMap { $0 } ?? 0
    }

    var summary: String {
        switch mode {
        case .manual:
            return "仅手动同步"
        case .interval:
            if intervalMinutes >= 60, intervalMinutes % 60 == 0 {
                return "每 \(intervalMinutes / 60) 小时自动同步"
            }
            return "每 \(intervalMinutes) 分钟自动同步"
        case .daily:
            return String(format: "每天 %02d:%02d 自动同步", dailyHour, dailyMinute)
        }
    }

    /// 下一次应该触发的时刻（仅用于界面展示）。
    func nextFireDate(after date: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch mode {
        case .manual:
            return nil
        case .interval:
            return date.addingTimeInterval(TimeInterval(max(1, intervalMinutes) * 60))
        case .daily:
            var components = DateComponents()
            components.hour = dailyHour
            components.minute = dailyMinute
            components.second = 0
            return calendar.nextDate(after: date, matching: components,
                                     matchingPolicy: .nextTime,
                                     repeatedTimePolicy: .first,
                                     direction: .forward)
        }
    }

    /// 判断现在是否到了该同步的时间。
    func dueState(lastRun: Date?, now: Date = Date(), calendar: Calendar = .current) -> (due: Bool, next: Date?) {
        switch mode {
        case .manual:
            return (false, nil)
        case .interval:
            let interval = TimeInterval(max(1, intervalMinutes) * 60)
            guard let last = lastRun else { return (false, now.addingTimeInterval(interval)) }
            let fire = last.addingTimeInterval(interval)
            if now >= fire { return (true, now.addingTimeInterval(interval)) }
            return (false, fire)
        case .daily:
            var components = DateComponents()
            components.hour = dailyHour
            components.minute = dailyMinute
            components.second = 0
            let previous = calendar.nextDate(after: now, matching: components,
                                             matchingPolicy: .nextTime,
                                             repeatedTimePolicy: .first,
                                             direction: .backward)
            let next = calendar.nextDate(after: now, matching: components,
                                         matchingPolicy: .nextTime,
                                         repeatedTimePolicy: .first,
                                         direction: .forward)
            guard let previous else { return (false, next) }
            let due = (lastRun ?? Date.distantPast) < previous
            return (due, next)
        }
    }
}

// MARK: - 同步任务

struct SyncTask: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var sourcePath: String = ""
    /// 目标文件夹（例如移动硬盘根目录）。
    var destinationRoot: String = ""
    /// 是否在目标文件夹下自动创建与源同名的文件夹。
    var createSubfolder: Bool = true
    /// 自定义子文件夹名，留空则用源文件夹名。
    var subfolderName: String = ""
    var mode: SyncMode = .additive
    var skipHiddenFiles: Bool = false
    /// 忽略 .DS_Store / .Spotlight-V100 之类的系统垃圾文件。
    var ignoreSystemFiles: Bool = true
    /// 排除规则，支持 * 与 ? 通配符；不含 / 时匹配文件名，含 / 时匹配相对路径。
    var excludePatterns: [String] = []
    var enabled: Bool = true
    var schedule: SyncSchedule = SyncSchedule()
    /// 上次同步结束时间（用于计算下一次触发）。
    var lastRunAt: Date?
    /// 上次同步结果的一句话描述。
    var lastSummary: String?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)).flatMap { $0 } ?? UUID()
        sourcePath = (try? container.decodeIfPresent(String.self, forKey: .sourcePath)).flatMap { $0 } ?? ""
        destinationRoot = (try? container.decodeIfPresent(String.self, forKey: .destinationRoot)).flatMap { $0 } ?? ""
        createSubfolder = (try? container.decodeIfPresent(Bool.self, forKey: .createSubfolder)).flatMap { $0 } ?? true
        subfolderName = (try? container.decodeIfPresent(String.self, forKey: .subfolderName)).flatMap { $0 } ?? ""
        mode = (try? container.decodeIfPresent(SyncMode.self, forKey: .mode)).flatMap { $0 } ?? .additive
        skipHiddenFiles = (try? container.decodeIfPresent(Bool.self, forKey: .skipHiddenFiles)).flatMap { $0 } ?? false
        ignoreSystemFiles = (try? container.decodeIfPresent(Bool.self, forKey: .ignoreSystemFiles)).flatMap { $0 } ?? true
        excludePatterns = (try? container.decodeIfPresent([String].self, forKey: .excludePatterns)).flatMap { $0 } ?? []
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)).flatMap { $0 } ?? true
        schedule = (try? container.decodeIfPresent(SyncSchedule.self, forKey: .schedule)).flatMap { $0 } ?? SyncSchedule()
        lastRunAt = (try? container.decodeIfPresent(Date.self, forKey: .lastRunAt)).flatMap { $0 }
        lastSummary = (try? container.decodeIfPresent(String.self, forKey: .lastSummary)).flatMap { $0 }
    }
}

extension SyncTask {
    var sourceURL: URL {
        URL(fileURLWithPath: (sourcePath as NSString).expandingTildeInPath).standardizedFileURL
    }

    var destinationRootURL: URL {
        URL(fileURLWithPath: (destinationRoot as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// 最终在目标文件夹下使用的文件夹名。
    var effectiveSubfolderName: String {
        let trimmed = subfolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let derived = sourceURL.lastPathComponent
        return derived.isEmpty ? "同步文件夹" : derived
    }

    /// 最终同步写入的目录。
    var destinationURL: URL {
        if createSubfolder {
            return destinationRootURL.appendingPathComponent(effectiveSubfolderName, isDirectory: true)
        }
        return destinationRootURL
    }

    /// 任务名固定取源文件夹名 —— 不提供自定义名称，少一个要填的字段。
    var displayName: String {
        let derived = sourceURL.lastPathComponent
        return derived.isEmpty ? "未命名任务" : derived
    }

    var isConfigured: Bool { !sourcePath.isEmpty && !destinationRoot.isEmpty }

    var exclusionPatterns: [String] {
        excludePatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

// MARK: - 运行记录

enum SyncOutcome: String, Codable, Sendable {
    case success
    case partial
    case failed
    case cancelled

    var title: String {
        switch self {
        case .success: return "成功"
        case .partial: return "部分失败"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

struct SyncRun: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var taskID: UUID
    var taskName: String
    var startedAt: Date = Date()
    var finishedAt: Date?
    /// manual / timer / login
    var trigger: String = "manual"
    var outcome: SyncOutcome = .success
    var copied: Int = 0
    var updated: Int = 0
    var skipped: Int = 0
    var deleted: Int = 0
    var failed: Int = 0
    var bytesCopied: Int64 = 0
    var destinationPath: String = ""
    var messages: [String] = []

    /// 这次运行是否因为「没有访问权限」失败。
    /// 用可选而不是 Bool = false：history.json 里的老记录没有这个键，
    /// 非可选会让整份历史解码失败。
    var needsAuthorization: Bool?

    var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    var changedCount: Int { copied + updated + deleted }

    var brief: String {
        guard outcome != .failed, outcome != .cancelled else {
            // 只说结论，具体原因由下面的 messages 逐条列出 —— 否则同一句话会出现两遍
            return outcome.title
        }
        if changedCount == 0 && failed == 0 { return "无变动" }
        var parts: [String] = []
        if copied > 0 { parts.append("新增 \(copied)") }
        if updated > 0 { parts.append("修改 \(updated)") }
        if deleted > 0 { parts.append("删除 \(deleted)") }
        // 「跳过 N」不显示：跳过的是本来就已同步过的文件，属正常现象，
        // 每次都报一遍反而让人以为出了问题。计数仍然记在 run.skipped 里。
        if failed > 0 { parts.append("失败 \(failed)") }
        return parts.joined(separator: " · ")
    }

    init(taskID: UUID, taskName: String, trigger: String) {
        self.taskID = taskID
        self.taskName = taskName
        self.trigger = trigger
    }
}

// MARK: - 应用配置

struct AppConfig: Codable {
    var tasks: [SyncTask] = []
    var runAtLogin: Bool = false
    var notificationsEnabled: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = (try? container.decodeIfPresent([SyncTask].self, forKey: .tasks)).flatMap { $0 } ?? []
        runAtLogin = (try? container.decodeIfPresent(Bool.self, forKey: .runAtLogin)).flatMap { $0 } ?? false
        notificationsEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)).flatMap { $0 } ?? true
    }
}
