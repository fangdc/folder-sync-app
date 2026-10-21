import Foundation

// MARK: - 进度

struct SyncProgress: Sendable, Equatable {
    var phase: String = ""
    var currentPath: String = ""
    var completed: Int = 0
    var total: Int = 0
    var bytesCopied: Int64 = 0
    var bytesTotal: Int64 = 0

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }
}

// MARK: - 取消令牌

final class SyncCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }
}

// MARK: - 选项

struct SyncOptions: Sendable {
    var mode: SyncMode = .additive
    var skipHiddenFiles: Bool = false
    var ignoreSystemFiles: Bool = true
    var excludePatterns: [String] = []
    /// 镜像模式下删除的文件优先放进废纸篓，放不进去才真正删除。
    var trashDeletions: Bool = true
    /// 时间戳容差：外接盘常见 exFAT / FAT32，修改时间会被取整，
    /// 容差太小会导致每次都全量重拷。
    var modificationTolerance: TimeInterval = 2.5

    static let systemFileNames: Set<String> = [
        ".DS_Store", ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd",
        ".DocumentRevisions-V100", ".TemporaryItems", ".VolumeIcon.icns",
        ".apdisk", ".AppleDouble", ".LSOverride", ".AppleDB", ".AppleDesktop",
        ".com.apple.timemachine.donotpresent"
    ]

    static let temporaryPrefix = ".foldersync-tmp-"
}

// MARK: - 计划

enum SyncItemKind: Sendable {
    case directory
    case file
    case symlink

    var label: String {
        switch self {
        case .directory: return "新建文件夹"
        case .file: return "复制"
        case .symlink: return "符号链接"
        }
    }
}

struct SyncPlanItem: Sendable {
    var relativePath: String
    var kind: SyncItemKind
    var size: Int64
}

struct SyncPlan: Sendable {
    var sourcePath: String = ""
    var destinationPath: String = ""
    var directories: [SyncPlanItem] = []
    var copies: [SyncPlanItem] = []
    var deletions: [SyncPlanItem] = []
    var skippedFiles: Int = 0
    var sourceFileCount: Int = 0
    var sourceByteCount: Int64 = 0
    var bytesToCopy: Int64 = 0
    var warnings: [String] = []
    var blockingError: String?
    /// 扫描时是否遇到「没有访问权限」——界面据此弹窗引导用户去授权
    var permissionDenied: Bool = false

    var items: [SyncPlanItem] { directories + copies + deletions }
    var itemCount: Int { directories.count + copies.count + deletions.count }
    var isDestructive: Bool { !deletions.isEmpty }
    var hasWork: Bool { itemCount > 0 }

    var summaryLine: String {
        var parts: [String] = []
        if !directories.isEmpty { parts.append("新建文件夹 \(directories.count)") }
        if !copies.isEmpty { parts.append("复制文件 \(copies.count)") }
        if !deletions.isEmpty { parts.append("删除 \(deletions.count)") }
        if parts.isEmpty { parts.append("无需改动") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 请求

struct SyncRequest {
    var source: URL
    /// 最终写入的目录（目标文件夹下与源同名的子文件夹）。
    var destination: URL
    /// 用户选择的目标文件夹，必须已经存在；只有它下面的子文件夹允许自动创建。
    /// 这样移动硬盘没挂载时不会把数据误写到本机磁盘上。
    var destinationRoot: URL
    var options: SyncOptions
}

// MARK: - 通配符匹配

enum GlobMatcher {
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: NSRegularExpression] = [:]

        func regex(for pattern: String) -> NSRegularExpression? {
            lock.lock(); defer { lock.unlock() }
            if let cached = storage[pattern] { return cached }
            guard let expression = try? NSRegularExpression(pattern: GlobMatcher.regexPattern(from: pattern),
                                                            options: [.caseInsensitive]) else { return nil }
            storage[pattern] = expression
            return expression
        }
    }

    private static let cache = Cache()

    static func regexPattern(from glob: String) -> String {
        var output = "^"
        var index = glob.startIndex
        while index < glob.endIndex {
            let character = glob[index]
            switch character {
            case "*":
                let next = glob.index(after: index)
                if next < glob.endIndex, glob[next] == "*" {
                    let afterNext = glob.index(after: next)
                    if afterNext < glob.endIndex, glob[afterNext] == "/" {
                        output += "(?:.*/)?"
                        index = glob.index(after: afterNext)
                        continue
                    }
                    output += ".*"
                    index = glob.index(after: next)
                    continue
                }
                output += "[^/]*"
            case "?":
                output += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                output += "\\" + String(character)
            default:
                output += String(character)
            }
            index = glob.index(after: index)
        }
        output += "$"
        return output
    }

    static func matches(pattern: String, name: String, relativePath: String) -> Bool {
        let target = pattern.contains("/") ? relativePath : name
        guard let expression = cache.regex(for: pattern) else { return false }
        let range = NSRange(target.startIndex..<target.endIndex, in: target)
        return expression.firstMatch(in: target, options: [], range: range) != nil
    }

    static func isExcluded(name: String, relativePath: String, options: SyncOptions) -> Bool {
        if name.hasPrefix(SyncOptions.temporaryPrefix) { return true }
        if options.ignoreSystemFiles, SyncOptions.systemFileNames.contains(name) { return true }
        if options.skipHiddenFiles, name.hasPrefix(".") { return true }
        for pattern in options.excludePatterns where matches(pattern: pattern, name: name, relativePath: relativePath) {
            return true
        }
        return false
    }
}

// MARK: - 计划生成

enum SyncPlanner {
    /// 把 /private/var、/private/tmp 之类的前缀还原成 /var、/tmp。
    ///
    /// Foundation 的 `resolvingSymlinksInPath()` 故意不展开这两个前缀，而目录枚举器
    /// 返回的却是 `/private/...`。两边不一致会让路径前缀比对全部落空（文件被静默跳过），
    /// 所以比对前统一一下。
    static func normalizeSystemPrefix(_ path: String) -> String {
        for prefix in ["/private/var/", "/private/tmp/", "/private/etc/"] {
            if path.hasPrefix(prefix) {
                return String(path.dropFirst("/private".count))
            }
        }
        return path
    }

    static func relativePath(of path: String, base: String) -> String {
        let normalizedPath = normalizeSystemPrefix(path)
        let normalizedBase = normalizeSystemPrefix(base)
        if normalizedPath == normalizedBase { return "" }
        guard normalizedPath.hasPrefix(normalizedBase + "/") else { return "" }
        return String(normalizedPath.dropFirst(normalizedBase.count + 1))
    }

    /// 优先使用枚举器给出的相对路径（配合 .producesRelativePathURLs），
    /// 拿不到时再退回前缀比对。
    static func relativePath(for url: URL, base: String) -> String {
        let produced = url.relativePath
        if !produced.isEmpty, produced != ".", !produced.hasPrefix("/") {
            return produced
        }
        return relativePath(of: url.path, base: base)
    }

    static func makePlan(source rawSource: URL,
                         destination rawDestination: URL,
                         options: SyncOptions,
                         requiredRoot: URL? = nil) -> SyncPlan {
        var plan = SyncPlan()
        let fm = FileManager.default
        let source = rawSource.resolvingSymlinksInPath().standardizedFileURL
        let destination = rawDestination.standardizedFileURL
        plan.sourcePath = source.path
        plan.destinationPath = destination.path

        // ---- 源检查 ----
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            plan.blockingError = "源文件夹不存在：\(Fmt.prettyPath(source.path))"
            return plan
        }
        guard isDirectory.boolValue else {
            plan.blockingError = "源路径不是文件夹：\(Fmt.prettyPath(source.path))"
            return plan
        }

        // ---- 目标文件夹检查 ----
        // root 是用户选的「目标文件夹」，必须真实存在（比如移动硬盘已经挂载）。
        // destination 本身（目标文件夹下与源同名的子文件夹）允许不存在，会自动创建。
        let root = (requiredRoot ?? destination.deletingLastPathComponent()).standardizedFileURL
        var rootIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &rootIsDirectory), rootIsDirectory.boolValue else {
            plan.blockingError = "目标文件夹不存在：\(Fmt.prettyPath(root.path))（移动硬盘可能没有挂载）"
            return plan
        }
        var destinationIsDirectory: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory),
           !destinationIsDirectory.boolValue {
            plan.blockingError = "目标路径已存在且不是文件夹：\(Fmt.prettyPath(destination.path))"
            return plan
        }

        // ---- 嵌套保护 ----
        let sourcePath = source.path
        let destinationPath = destination.path
        if destinationPath == sourcePath {
            plan.blockingError = "目标文件夹和源文件夹是同一个文件夹"
            return plan
        }
        if destinationPath.hasPrefix(sourcePath + "/") {
            plan.blockingError = "目标文件夹位于源文件夹内部，会造成无限递归，已拒绝执行"
            return plan
        }
        if sourcePath.hasPrefix(destinationPath + "/") {
            plan.blockingError = "源文件夹位于目标文件夹内部，镜像模式下可能误删源文件，已拒绝执行"
            return plan
        }

        // ---- 扫描源 ----
        var sourceEntries = Set<String>()
        var directories: [SyncPlanItem] = []
        var copies: [SyncPlanItem] = []
        var skipped = 0
        var sourceFileCount = 0
        var sourceByteCount: Int64 = 0
        var bytesToCopy: Int64 = 0
        var warnings: [String] = []
        var unresolvedEntries = 0
        var permissionDenied = false

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                      .fileSizeKey, .contentModificationDateKey]
        let keySet = Set(keys)
        var enumerationOptions: FileManager.DirectoryEnumerationOptions = [.producesRelativePathURLs]
        if options.skipHiddenFiles { enumerationOptions.insert(.skipsHiddenFiles) }

        let enumerator = fm.enumerator(at: source,
                                       includingPropertiesForKeys: keys,
                                       options: enumerationOptions,
                                       errorHandler: { url, error in
            if Fmt.isPermissionError(error) { permissionDenied = true }
            warnings.append("无法读取 \(Fmt.prettyPath(url.path))：\(Fmt.errorText(error))")
            return true
        })

        if let enumerator {
            while let url = enumerator.nextObject() as? URL {
                let relative = relativePath(for: url, base: sourcePath)
                guard !relative.isEmpty else { unresolvedEntries += 1; continue }
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: keySet)
                let isSymlink = values?.isSymbolicLink ?? false
                let isDir = values?.isDirectory ?? false
                let destinationItem = destination.appendingPathComponent(relative)

                if GlobMatcher.isExcluded(name: name, relativePath: relative, options: options) {
                    if isDir, !isSymlink { enumerator.skipDescendants() }
                    skipped += 1
                    continue
                }

                sourceEntries.insert(relative)

                if isSymlink {
                    sourceFileCount += 1
                    if fm.fileExists(atPath: destinationItem.path) {
                        skipped += 1
                    } else {
                        copies.append(SyncPlanItem(relativePath: relative, kind: .symlink, size: 0))
                    }
                    continue
                }

                if isDir {
                    var destinationIsDirectory: ObjCBool = false
                    let destinationExists = fm.fileExists(atPath: destinationItem.path,
                                                          isDirectory: &destinationIsDirectory)
                    if !destinationExists || !destinationIsDirectory.boolValue {
                        directories.append(SyncPlanItem(relativePath: relative, kind: .directory, size: 0))
                    }
                    continue
                }

                sourceFileCount += 1
                let size = Int64(values?.fileSize ?? 0)
                sourceByteCount += size
                if needsCopy(sourceURL: url,
                             destinationURL: destinationItem,
                             sourceSize: size,
                             sourceDate: values?.contentModificationDate,
                             tolerance: options.modificationTolerance,
                             fm: fm) {
                    copies.append(SyncPlanItem(relativePath: relative, kind: .file, size: size))
                    bytesToCopy += size
                } else {
                    skipped += 1
                }
            }
        }

        if unresolvedEntries > 0 {
            warnings.append("有 \(unresolvedEntries) 个条目无法确定相对路径，已跳过。")
        }

        // ---- 镜像模式：找出目标文件夹里多出来的内容 ----
        var deletions: [SyncPlanItem] = []
        if options.mode == .mirror {
            if sourceFileCount == 0 {
                warnings.append("源文件夹里没有扫描到任何文件，为避免误删已跳过镜像删除。")
            } else {
                let destinationEnumerator = fm.enumerator(at: destination,
                                                          includingPropertiesForKeys: keys,
                                                          options: [.producesRelativePathURLs],
                                                          errorHandler: { url, error in
                    if Fmt.isPermissionError(error) { permissionDenied = true }
                    warnings.append("无法读取 \(Fmt.prettyPath(url.path))：\(Fmt.errorText(error))")
                    return true
                })
                if let destinationEnumerator {
                    while let url = destinationEnumerator.nextObject() as? URL {
                        let relative = relativePath(for: url, base: destinationPath)
                        guard !relative.isEmpty else { continue }
                        let name = url.lastPathComponent
                        let values = try? url.resourceValues(forKeys: keySet)
                        let isDir = values?.isDirectory ?? false
                        let isSymlink = values?.isSymbolicLink ?? false

                        if GlobMatcher.isExcluded(name: name, relativePath: relative, options: options) {
                            if isDir, !isSymlink { destinationEnumerator.skipDescendants() }
                            continue
                        }
                        if sourceEntries.contains(relative) { continue }
                        deletions.append(SyncPlanItem(relativePath: relative,
                                                      kind: isDir && !isSymlink ? .directory : .file,
                                                      size: Int64(values?.fileSize ?? 0)))
                        // 目录整体要删，里面的东西不用再单独列
                        if isDir, !isSymlink { destinationEnumerator.skipDescendants() }
                    }
                }
            }
        }

        plan.directories = directories.sorted { $0.relativePath < $1.relativePath }
        plan.copies = copies.sorted { $0.relativePath < $1.relativePath }
        // 深层优先：先删子项再删父目录
        plan.deletions = deletions.sorted { $0.relativePath > $1.relativePath }
        plan.skippedFiles = skipped
        plan.sourceFileCount = sourceFileCount
        plan.sourceByteCount = sourceByteCount
        plan.bytesToCopy = bytesToCopy
        plan.warnings = warnings
        plan.permissionDenied = permissionDenied
        return plan
    }

    /// 判断目标文件是否需要重新复制。大小一致 + 修改时间在容差内 → 认为相同。
    static func needsCopy(sourceURL: URL,
                          destinationURL: URL,
                          sourceSize: Int64,
                          sourceDate: Date?,
                          tolerance: TimeInterval,
                          fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) else { return true }
        if isDirectory.boolValue { return true }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard let values = try? destinationURL.resourceValues(forKeys: keys) else { return true }
        if values.isSymbolicLink == true { return true }
        guard values.isRegularFile == true else { return true }
        if Int64(values.fileSize ?? 0) != sourceSize { return true }
        guard let sourceDate else { return true }
        guard let destinationDate = values.contentModificationDate else { return true }
        return abs(sourceDate.timeIntervalSince(destinationDate)) > tolerance
    }
}

// MARK: - 执行

enum SyncEngine {
    @discardableResult
    static func run(request: SyncRequest,
                    taskID: UUID,
                    taskName: String,
                    trigger: String,
                    cancellation: SyncCancellation? = nil,
                    progress: ((SyncProgress) -> Void)? = nil) -> SyncRun {
        let fm = FileManager.default
        var run = SyncRun(taskID: taskID, taskName: taskName, trigger: trigger)

        let source = request.source.resolvingSymlinksInPath().standardizedFileURL
        let destination = request.destination.standardizedFileURL
        let plan = SyncPlanner.makePlan(source: source,
                                        destination: destination,
                                        options: request.options,
                                        requiredRoot: request.destinationRoot)

        run.destinationPath = plan.destinationPath
        run.skipped = plan.skippedFiles

        if let blockingError = plan.blockingError {
            run.outcome = .failed
            run.messages.append(blockingError)
            run.finishedAt = Date()
            progress?(SyncProgress(phase: "失败", currentPath: "", completed: 0, total: 0))
            return run
        }

        if plan.permissionDenied { run.needsAuthorization = true }
        run.messages.append(contentsOf: plan.warnings.prefix(20))

        // 目标文件夹本身不存在就创建（例如 /Volumes/Backup/我的项目）
        if !fm.fileExists(atPath: destination.path) {
            do {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                run.outcome = .failed
                // 这里最常见的失败是「移动硬盘没挂载 / 只读 / 没有写权限」，
                // 所以除了中文原因，还给一句能照做的提示。
                if Fmt.isPermissionError(error) { run.needsAuthorization = true }
                let reason = Fmt.errorText(error)
                run.messages.append("无法创建目标文件夹「\(Fmt.prettyPath(destination.path))」：\(reason)。"
                                    + "请确认目标磁盘已挂载、不是只读且还有剩余空间，"
                                    + "或者先在访达里把同名文件夹建好再同步。")
                run.finishedAt = Date()
                return run
            }
        }

        // 注意：这里**不能**用 plan.items —— 它等于 directories + copies + deletions。
        // 删除项由下面单独的「镜像删除」循环处理；如果混进来，每一项都会被当成"要复制的文件"
        // 去源里找，源里已经没有它 → 记一次「复制失败」；目录还会被 ensureDirectory 又建回来。
        // 这正是「删掉一个文件后总是显示 删除 N · 失败 N」的来源。
        let items = plan.directories + plan.copies
        // 进度总数仍要覆盖三段（新建目录 + 复制 + 删除），否则删除阶段的推进会超过 100%
        let totalItems = items.count + plan.deletions.count
        var state = SyncProgress(phase: "准备中", currentPath: "", completed: 0,
                                 total: totalItems, bytesCopied: 0, bytesTotal: plan.bytesToCopy)
        progress?(state)

        var lastReport = Date.distantPast
        func report(force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.05 {
                lastReport = now
                progress?(state)
            }
        }

        var consecutiveFailures = 0
        var cancelled = false

        for item in items {
            if cancellation?.isCancelled == true {
                cancelled = true
                run.messages.append("已被手动取消，剩余 \(totalItems - state.completed) 项未处理。")
                break
            }
            if consecutiveFailures >= 8 {
                run.messages.append("连续 \(consecutiveFailures) 次写入失败，目标磁盘可能已断开，已中止同步。")
                run.outcome = .failed
                run.finishedAt = Date()
                report(force: true)
                return run
            }

            let sourceURL = source.appendingPathComponent(item.relativePath)
            let destinationURL = destination.appendingPathComponent(item.relativePath)
            state.currentPath = item.relativePath
            state.phase = item.kind == .directory ? "新建文件夹" : "复制文件"

            do {
                switch item.kind {
                case .directory:
                    try ensureDirectory(destinationURL, fm: fm)
                    consecutiveFailures = 0
                case .file, .symlink:
                    let existed = try copyItem(source: sourceURL,
                                               destination: destinationURL,
                                               fm: fm,
                                               temporaryPrefix: SyncOptions.temporaryPrefix)
                    if existed { run.updated += 1 } else { run.copied += 1 }
                    run.bytesCopied += item.size
                    state.bytesCopied += item.size
                    consecutiveFailures = 0
                }
            } catch {
                run.failed += 1
                consecutiveFailures += 1
                if run.messages.count < 60 {
                    if Fmt.isPermissionError(error) { run.needsAuthorization = true }
                    run.messages.append("复制失败 \(item.relativePath)：\(Fmt.errorText(error))")
                }
            }

            state.completed += 1
            report()
        }

        // ---- 镜像删除 ----
        if !cancelled {
            state.phase = "清理目标文件夹里多余的文件"
            report(force: true)
            for item in plan.deletions {
                if cancellation?.isCancelled == true { cancelled = true; break }
                let destinationURL = destination.appendingPathComponent(item.relativePath)
                state.currentPath = item.relativePath
                do {
                    try deleteItem(destinationURL, fm: fm, trash: request.options.trashDeletions)
                    run.deleted += 1
                    consecutiveFailures = 0
                } catch {
                    run.failed += 1
                    consecutiveFailures += 1
                    if run.messages.count < 60 {
                        if Fmt.isPermissionError(error) { run.needsAuthorization = true }
                        run.messages.append("删除失败 \(item.relativePath)：\(Fmt.errorText(error))")
                    }
                }
                state.completed += 1
                report()
            }
        }

        if cancelled {
            run.outcome = .cancelled
        } else if run.failed > 0 {
            run.outcome = (run.copied + run.updated + run.deleted) > 0 ? .partial : .failed
        } else {
            run.outcome = .success
        }

        run.finishedAt = Date()
        state.phase = run.outcome.title
        state.currentPath = ""
        state.completed = state.total
        report(force: true)
        return run
    }

    /// 保证某个路径是目录：不存在就建，是文件就先删掉再建。
    static func ensureDirectory(_ url: URL, fm: FileManager) throws {
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// 复制单个条目：先写临时文件，再用原子替换落地，避免中途失败留下半个文件。
    static func copyItem(source: URL,
                         destination: URL,
                         fm: FileManager,
                         temporaryPrefix: String) throws -> Bool {
        try ensureDirectory(destination.deletingLastPathComponent(), fm: fm)
        let parent = destination.deletingLastPathComponent()
        let temporaryURL = parent.appendingPathComponent(temporaryPrefix + UUID().uuidString)
        try? fm.removeItem(at: temporaryURL)

        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .contentModificationDateKey]
        let values = try? source.resourceValues(forKeys: keys)
        let isSymlink = values?.isSymbolicLink ?? false

        if isSymlink {
            let target = try fm.destinationOfSymbolicLink(atPath: source.path)
            try fm.createSymbolicLink(atPath: temporaryURL.path, withDestinationPath: target)
        } else {
            try fm.copyItem(at: source, to: temporaryURL)
            var attributes: [FileAttributeKey: Any] = [:]
            if let date = values?.contentModificationDate { attributes[.modificationDate] = date }
            if let permissions = try? fm.attributesOfItem(atPath: source.path)[.posixPermissions] {
                attributes[.posixPermissions] = permissions
            }
            if !attributes.isEmpty {
                try? fm.setAttributes(attributes, ofItemAtPath: temporaryURL.path)
            }
        }

        let existed = fm.fileExists(atPath: destination.path)
        if existed {
            do {
                _ = try fm.replaceItemAt(destination, withItemAt: temporaryURL)
                return true
            } catch {
                // 部分外接盘 / 网络盘不支持原子替换，退回「先删后移动」
                try? fm.removeItem(at: destination)
                do {
                    try fm.moveItem(at: temporaryURL, to: destination)
                    return true
                } catch {
                    try? fm.removeItem(at: temporaryURL)
                    throw error
                }
            }
        } else {
            do {
                try fm.moveItem(at: temporaryURL, to: destination)
                return false
            } catch {
                try? fm.removeItem(at: temporaryURL)
                throw error
            }
        }
    }

    static func deleteItem(_ url: URL, fm: FileManager, trash: Bool) throws {
        guard url.path != "/" else { return }
        if trash {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                return
            } catch {
                // 外接盘没有废纸篓时退回直接删除
            }
        }
        try fm.removeItem(at: url)
    }

    /// 清理上次异常中断留下的临时文件。
    static func cleanTemporaryFiles(in directory: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return }
        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent.hasPrefix(SyncOptions.temporaryPrefix) {
                try? fm.removeItem(at: url)
            }
        }
    }
}
