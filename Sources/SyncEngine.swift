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

/// 检测到的一次文件夹改名（目标里的旧路径 → 新路径）。
struct SyncPlanMove: Sendable, Hashable {
    var fromRelativePath: String
    var toRelativePath: String
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
        // 只统计「真正的内容文件」：不管用户是否关闭了「忽略系统文件」，
        // .DS_Store / .VolumeIcon.icns 这类挂载点残留都不算源内容。
        // 移动硬盘没挂载时，/Volumes/xxx 可能只剩一个带 .DS_Store 的空目录，
        // 不能因为这一个文件就允许镜像删除。
        var sourceRealFileCount = 0
        var sourceByteCount: Int64 = 0
        var bytesToCopy: Int64 = 0
        var warnings: [String] = []
        var unresolvedEntries = 0
        var permissionDenied = false
        var scanHadErrors = false

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
            scanHadErrors = true
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
                // 系统残留不只看文件名，也要看路径里是否经过 .Spotlight-V100、
                // .Trashes 这类系统目录 —— 空挂载点里可能只剩这些目录和文件。
                let isSystemItem = relative.split(separator: "/").contains { component in
                    let part = String(component)
                    return SyncOptions.systemFileNames.contains(part)
                        || part == ".localized"
                        || part.hasPrefix("._")
                        || part.hasPrefix(SyncOptions.temporaryPrefix)
                }

                if GlobMatcher.isExcluded(name: name, relativePath: relative, options: options) {
                    if isDir, !isSymlink { enumerator.skipDescendants() }
                    skipped += 1
                    continue
                }

                sourceEntries.insert(relative)

                if isSymlink {
                    sourceFileCount += 1
                    if !isSystemItem { sourceRealFileCount += 1 }
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
                if !isSystemItem { sourceRealFileCount += 1 }
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
        } else {
            scanHadErrors = true
        }

        if unresolvedEntries > 0 {
            scanHadErrors = true
            warnings.append("有 \(unresolvedEntries) 个条目无法确定相对路径，已跳过。")
        }

        // 扫描期间源目录被卸载/移除：直接判定为不可同步，避免把「空源」当成真实状态。
        var sourceStillDirectory: ObjCBool = false
        if !fm.fileExists(atPath: source.path, isDirectory: &sourceStillDirectory)
            || !sourceStillDirectory.boolValue {
            plan.blockingError = "源文件夹在扫描过程中不可用：\(Fmt.prettyPath(source.path))"
            return plan
        }

        // ---- 镜像模式：找出目标文件夹里多出来的内容 ----
        var deletions: [SyncPlanItem] = []
        if options.mode == .mirror {
            // 只有「扫描到了真实内容、且扫描过程没有错误」才允许镜像删除。
            // 移动硬盘没挂载时，源路径可能还残留挂载点目录（甚至带 .DS_Store），
            // 不能把这种空壳当成用户真的清空了源文件夹，否则会把目标文件全删光。
            let sourceIsSafeForMirror = sourceFileCount > 0
                && sourceRealFileCount > 0
                && !scanHadErrors
                && !permissionDenied
            if !sourceIsSafeForMirror {
                warnings.append("源文件夹为空、不可读或扫描不完整，为避免误删已跳过镜像删除。")
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

    // MARK: - 文件夹改名检测

    /// 找出「源里换了名字、目标里还是旧名字」的文件夹。
    ///
    /// 只匹配同一个父目录下、内容结构（文件 / 子目录的相对路径）相同或高度相似的候选。
    /// 这样改名会被识别成「移动文件夹」，而不是「删掉旧文件夹 + 重新复制所有文件」；
    /// 内容完全不同的新文件夹不会误判。
    ///
    /// - Parameter missingDirectories: 源里有、目标里没有的文件夹相对路径（来自同步计划）。
    static func folderMoves(source: URL,
                            destination: URL,
                            missingDirectories: [String],
                            options: SyncOptions) -> [SyncPlanMove] {
        guard !missingDirectories.isEmpty else { return [] }
        let extras = extraDestinationDirectories(source: source, destination: destination, options: options)
        guard !extras.isEmpty else { return [] }

        let missing = Set(missingDirectories)
        let topMissing = missing.filter { !missing.contains(parentPath($0)) }
        let topExtra = extras.filter { !extras.contains(parentPath($0)) }
        guard !topMissing.isEmpty, !topExtra.isEmpty else { return [] }

        // 候选太多时不做推断：内容签名比较会变慢，也更容易把普通的新建/保留误配成改名。
        guard topMissing.count <= 300, topExtra.count <= 300 else { return [] }

        let missingByParent = Dictionary(grouping: topMissing, by: parentPath)
        let extraByParent = Dictionary(grouping: topExtra, by: parentPath)

        var moves: [SyncPlanMove] = []
        for (parent, newDirectories) in missingByParent {
            guard let oldDirectories = extraByParent[parent] else { continue }
            guard isDirectoryURL(destination.appendingPathComponent(parent)) else { continue }

            var newCandidates: [(path: String, signature: Set<String>)] = []
            for path in newDirectories.sorted() {
                guard let signature = contentSignature(of: path, root: source, options: options) else { continue }
                newCandidates.append((path, signature))
            }
            var oldCandidates: [(path: String, signature: Set<String>)] = []
            for path in oldDirectories.sorted() {
                guard let signature = contentSignature(of: path, root: destination, options: options) else { continue }
                oldCandidates.append((path, signature))
            }
            guard !newCandidates.isEmpty, !oldCandidates.isEmpty else { continue }

            var usedNew: Set<String> = []
            var usedOld: Set<String> = []

            // 先按内容签名精确配对：最常见的情况是只改了文件夹名，里面一个字节都没动。
            let newBySignature = Dictionary(grouping: newCandidates, by: { $0.signature })
            let oldBySignature = Dictionary(grouping: oldCandidates, by: { $0.signature })
            for (signature, newItems) in newBySignature {
                guard let oldItems = oldBySignature[signature] else { continue }
                let newPaths = newItems.map(\.path).sorted()
                let oldPaths = oldItems.map(\.path).sorted()
                for index in 0..<min(newPaths.count, oldPaths.count) {
                    let newPath = newPaths[index]
                    let oldPath = oldPaths[index]
                    moves.append(SyncPlanMove(fromRelativePath: oldPath, toRelativePath: newPath))
                    usedNew.insert(newPath)
                    usedOld.insert(oldPath)
                }
            }

            // 剩下的多半是「改名同时改了里面的东西」：按内容相似度配对。
            let remainingNew = newCandidates.filter { !usedNew.contains($0.path) }
            let remainingOld = oldCandidates.filter { !usedOld.contains($0.path) }
            for newCandidate in remainingNew {
                var best: (path: String, score: Double)?
                for oldCandidate in remainingOld where !usedOld.contains(oldCandidate.path) {
                    let score = signatureSimilarity(newCandidate.signature, oldCandidate.signature)
                    if score > (best?.score ?? 0) {
                        best = (oldCandidate.path, score)
                    }
                }
                guard let best, best.score >= 0.6 else { continue }
                moves.append(SyncPlanMove(fromRelativePath: best.path, toRelativePath: newCandidate.path))
                usedNew.insert(newCandidate.path)
                usedOld.insert(best.path)
            }
        }

        return moves.sorted { $0.toRelativePath < $1.toRelativePath }
    }

    private static func parentPath(_ path: String) -> String {
        guard let index = path.lastIndex(of: "/") else { return "" }
        return String(path[..<index])
    }

    private static func isDirectoryURL(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isFolder(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// 目标里存在、源里同路径不存在的文件夹。
    private static func extraDestinationDirectories(source: URL,
                                                    destination: URL,
                                                    options: SyncOptions) -> Set<String> {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var enumerationOptions: FileManager.DirectoryEnumerationOptions = [.producesRelativePathURLs]
        if options.skipHiddenFiles { enumerationOptions.insert(.skipsHiddenFiles) }
        guard let enumerator = fm.enumerator(at: destination,
                                             includingPropertiesForKeys: keys,
                                             options: enumerationOptions) else { return [] }
        var extras: Set<String> = []
        while let url = enumerator.nextObject() as? URL {
            let relative = relativePath(for: url, base: destination.path)
            guard !relative.isEmpty else { continue }
            let name = url.lastPathComponent
            if GlobMatcher.isExcluded(name: name, relativePath: relative, options: options) {
                if isFolder(url) { enumerator.skipDescendants() }
                continue
            }
            guard isFolder(url) else { continue }
            if isFolder(source.appendingPathComponent(relative)) { continue }
            extras.insert(relative)
        }
        return extras
    }

    /// 文件夹内容的「结构签名」：每个后代文件/子目录的相对路径。
    /// 空文件夹得到空集合；比较时用原始大小/时间之外的结构，改名同时改内容也能匹配。
    private static func contentSignature(of folderPath: String,
                                         root: URL,
                                         options: SyncOptions) -> Set<String>? {
        let folder = root.appendingPathComponent(folderPath)
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        var enumerationOptions: FileManager.DirectoryEnumerationOptions = [.producesRelativePathURLs]
        if options.skipHiddenFiles { enumerationOptions.insert(.skipsHiddenFiles) }
        guard let enumerator = fm.enumerator(at: folder,
                                             includingPropertiesForKeys: keys,
                                             options: enumerationOptions) else { return nil }
        var signature: Set<String> = []
        while let url = enumerator.nextObject() as? URL {
            let inner = relativePath(for: url, base: folder.path)
            guard !inner.isEmpty else { continue }
            let name = url.lastPathComponent
            if GlobMatcher.isExcluded(name: name, relativePath: inner, options: options) {
                if isFolder(url) { enumerator.skipDescendants() }
                continue
            }
            signature.insert((isFolder(url) ? "d:" : "f:") + inner)
        }
        return signature
    }

    private static func signatureSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        if lhs.isEmpty && rhs.isEmpty { return 1 }
        let union = lhs.union(rhs).count
        guard union > 0 else { return 1 }
        return Double(lhs.intersection(rhs).count) / Double(union)
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
        var plan = SyncPlanner.makePlan(source: source,
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

        // 硬性前置条件：计划生成后、写入任何内容之前再确认一次。
        // 源盘在计划阶段被拔掉，或目标盘刚好卸载时，绝不能继续创建目录/删除文件。
        var sourceIsDirectoryNow: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &sourceIsDirectoryNow),
              sourceIsDirectoryNow.boolValue else {
            run.outcome = .failed
            run.messages.append("源文件夹不存在：\(Fmt.prettyPath(source.path))。本次未同步，目标文件没有被改动。")
            run.finishedAt = Date()
            progress?(SyncProgress(phase: "失败", currentPath: "", completed: 0, total: 0))
            return run
        }
        let targetRoot = request.destinationRoot.standardizedFileURL
        var targetRootIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: targetRoot.path, isDirectory: &targetRootIsDirectory),
              targetRootIsDirectory.boolValue else {
            run.outcome = .failed
            run.messages.append("目标文件夹不存在：\(Fmt.prettyPath(targetRoot.path))（移动硬盘可能没有挂载）。本次未同步。")
            run.finishedAt = Date()
            progress?(SyncProgress(phase: "失败", currentPath: "", completed: 0, total: 0))
            return run
        }

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

        // 先处理文件夹改名：把目标里的旧文件夹整体移成新名字，再重新生成计划。
        // 这样里面的文件不会被当成「新增」重新复制一遍；空文件夹也会被算作一次修改。
        if !plan.permissionDenied {
            let moves = SyncPlanner.folderMoves(source: source,
                                                destination: destination,
                                                missingDirectories: plan.directories.map(\.relativePath),
                                                options: request.options)
            if !moves.isEmpty {
                var movedAny = false
                for move in moves {
                    let oldURL = destination.appendingPathComponent(move.fromRelativePath)
                    let newURL = destination.appendingPathComponent(move.toRelativePath)
                    if fm.fileExists(atPath: newURL.path) { continue }
                    do {
                        try fm.createDirectory(at: newURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
                        try fm.moveItem(at: oldURL, to: newURL)
                        run.updated += 1
                        run.recordChange(.modifiedFolder,
                                         path: move.toRelativePath,
                                         fromPath: move.fromRelativePath)
                        movedAny = true
                    } catch {
                        run.failed += 1
                        if Fmt.isPermissionError(error) { run.needsAuthorization = true }
                        if run.messages.count < 60 {
                            run.messages.append("重命名文件夹失败 \(move.fromRelativePath) → \(move.toRelativePath)：\(Fmt.errorText(error))")
                        }
                    }
                }
                if movedAny {
                    plan = SyncPlanner.makePlan(source: source,
                                                destination: destination,
                                                options: request.options,
                                                requiredRoot: request.destinationRoot)
                    if let blockingError = plan.blockingError {
                        run.outcome = .failed
                        run.messages.append(blockingError)
                        run.finishedAt = Date()
                        progress?(SyncProgress(phase: "失败", currentPath: "", completed: 0, total: 0))
                        return run
                    }
                }
            }
        }

        run.destinationPath = plan.destinationPath
        run.skipped = plan.skippedFiles
        if plan.permissionDenied { run.needsAuthorization = true }
        run.messages.append(contentsOf: plan.warnings.prefix(20))

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
                    // 目录也记一条：首次同步时能看出到底建了哪些文件夹
                    run.recordChange(.createdFolder, path: item.relativePath)
                    consecutiveFailures = 0
                case .file, .symlink:
                    let existed = try copyItem(source: sourceURL,
                                               destination: destinationURL,
                                               fm: fm,
                                               temporaryPrefix: SyncOptions.temporaryPrefix)
                    if existed {
                        run.updated += 1
                        run.recordChange(.modifiedFile, path: item.relativePath, size: item.size)
                    } else {
                        run.copied += 1
                        run.recordChange(item.kind == .symlink ? .createdLink : .createdFile,
                                         path: item.relativePath,
                                         size: item.size)
                    }
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
            // 删除前最后一道闸：复制期间源盘/目标盘可能被拔掉。
            // 只要任意一端不可用，就停止删除并标记失败，绝不清空目标。
            var sourceStillThere: ObjCBool = false
            var targetRootStillThere: ObjCBool = false
            let targetRoot = request.destinationRoot.standardizedFileURL
            if !fm.fileExists(atPath: source.path, isDirectory: &sourceStillThere)
                || !sourceStillThere.boolValue
                || !fm.fileExists(atPath: targetRoot.path, isDirectory: &targetRootStillThere)
                || !targetRootStillThere.boolValue {
                run.outcome = .failed
                run.messages.append("源文件夹或目标文件夹已不可用，已停止同步；没有删除任何目标文件。")
                run.finishedAt = Date()
                progress?(SyncProgress(phase: "失败", currentPath: "", completed: state.completed, total: totalItems))
                return run
            }
            state.phase = "清理目标文件夹里多余的文件"
            report(force: true)
            for item in plan.deletions {
                if cancellation?.isCancelled == true { cancelled = true; break }
                let destinationURL = destination.appendingPathComponent(item.relativePath)
                state.currentPath = item.relativePath
                let isFolder = item.kind == .directory
                // 删除仍按整个文件夹一次完成；这里先把里面的内容枚举出来，
                // 只用于「同步详情」逐条展示，否则日志里只能看到一个文件夹名。
                let contents = isFolder
                    ? contentsForDeletionLog(of: destinationURL,
                                             relativePath: item.relativePath,
                                             options: request.options,
                                             fm: fm)
                    : []
                do {
                    try deleteItem(destinationURL, fm: fm, trash: request.options.trashDeletions)
                    run.deleted += 1
                    run.recordChange(isFolder ? .deletedFolder : .deletedFile,
                                     path: item.relativePath,
                                     size: item.size)
                    for child in contents {
                        run.deleted += 1
                        run.recordChange(child.kind == .directory ? .deletedFolder : .deletedFile,
                                         path: child.relativePath,
                                         size: child.size)
                    }
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

    /// 列出即将删除的文件夹里的内容（相对同步根目录），只用于同步详情的逐条记录。
    ///
    /// 删除本身仍然一次删掉整个文件夹（进废纸篓 / removeItem），这里只是额外枚举一遍；
    /// 系统垃圾文件会跟着文件夹一起被删掉，但不写进日志，避免满屏 `.DS_Store`。
    private static func contentsForDeletionLog(of folder: URL,
                                               relativePath: String,
                                               options: SyncOptions,
                                               fm: FileManager) -> [SyncPlanItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let keySet = Set(keys)
        guard let enumerator = fm.enumerator(at: folder,
                                             includingPropertiesForKeys: keys,
                                             options: [.producesRelativePathURLs]) else {
            return []
        }
        var items: [SyncPlanItem] = []
        while let url = enumerator.nextObject() as? URL {
            let name = url.lastPathComponent
            if name.hasPrefix(SyncOptions.temporaryPrefix) { continue }
            if options.ignoreSystemFiles, SyncOptions.systemFileNames.contains(name) { continue }
            let inner = SyncPlanner.relativePath(for: url, base: folder.path)
            guard !inner.isEmpty else { continue }
            let values = try? url.resourceValues(forKeys: keySet)
            let isDirectory = values?.isDirectory ?? false
            let isSymlink = values?.isSymbolicLink ?? false
            items.append(SyncPlanItem(relativePath: relativePath + "/" + inner,
                                      kind: isDirectory && !isSymlink ? .directory : .file,
                                      size: Int64(values?.fileSize ?? 0)))
        }
        return items.sorted { $0.relativePath < $1.relativePath }
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
