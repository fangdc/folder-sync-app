import Foundation

// ============================================================
//  FolderSync —— 同步引擎自动化测试
//  用 ./build.sh --test 运行
// ============================================================

var passed = 0
var failed = 0
var failures: [String] = []
var currentTest = ""
var createdRoots: [URL] = []

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        failures.append("[\(currentTest)] 第 \(line) 行：\(message)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    if actual == expected {
        passed += 1
    } else {
        failed += 1
        failures.append("[\(currentTest)] 第 \(line) 行：\(message) —— 实际 \(actual)，期望 \(expected)")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    let before = failed
    do {
        try body()
    } catch {
        failed += 1
        failures.append("[\(name)] 抛出异常：\(error)")
    }
    if failed == before {
        print("  ✓ \(name)")
    } else {
        print("  ✗ \(name)")
    }
}

// ============================================================
//  测试辅助
// ============================================================

let fm = FileManager.default
let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

func makeRoot(_ label: String) -> URL {
    let root = fm.temporaryDirectory
        .appendingPathComponent("foldersync-tests", isDirectory: true)
        .appendingPathComponent("\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    let resolved = root.resolvingSymlinksInPath()
    createdRoots.append(resolved)
    return resolved
}

@discardableResult
func makeFile(_ root: URL, _ relative: String, _ contents: String, date: Date = baseDate) -> URL {
    let url = root.appendingPathComponent(relative)
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(contents.utf8).write(to: url)
    try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    return url
}

@discardableResult
func makeDir(_ root: URL, _ relative: String) -> URL {
    let url = root.appendingPathComponent(relative)
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

func contents(_ url: URL) -> String {
    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

func setDate(_ url: URL, _ date: Date) {
    try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

func date(of url: URL) -> Date? {
    (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
}

func size(of url: URL) -> Int64 {
    Int64(((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0)
}

func allRelativePaths(_ root: URL) -> [String] {
    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var result: [String] = []
    let base = root.path
    while let url = enumerator.nextObject() as? URL {
        if url.path.hasPrefix(base + "/") {
            result.append(String(url.path.dropFirst(base.count + 1)))
        }
    }
    return result.sorted()
}

@discardableResult
func runSync(source: URL,
             destination: URL,
             destinationRoot: URL? = nil,
             options: SyncOptions = SyncOptions(),
             progress: ((SyncProgress) -> Void)? = nil,
             cancellation: SyncCancellation? = nil) -> SyncRun {
    var opts = options
    opts.trashDeletions = false   // 测试里直接删，避免往用户废纸篓里塞东西
    let request = SyncRequest(source: source,
                              destination: destination,
                              destinationRoot: destinationRoot ?? destination.deletingLastPathComponent(),
                              options: opts)
    return SyncEngine.run(request: request,
                          taskID: UUID(),
                          taskName: "测试任务",
                          trigger: "test",
                          cancellation: cancellation,
                          progress: progress)
}

func mirrorOptions(_ extra: (inout SyncOptions) -> Void = { _ in }) -> SyncOptions {
    var options = SyncOptions()
    options.mode = .mirror
    extra(&options)
    return options
}

// ============================================================
//  用例
// ============================================================

print("同步引擎测试\n")

// ---------------------------------------------------------- 基础复制

test("基础复制：递归建目录并复制全部文件") {
    let source = makeRoot("src")
    let destination = makeRoot("dst").appendingPathComponent("我的项目")

    makeFile(source, "readme.md", "hello")
    makeFile(source, "docs/guide.md", "guide")
    makeFile(source, "docs/images/a.png", "PNGDATA")
    makeFile(source, "src/main.swift", "print(1)")

    let run = runSync(source: source, destination: destination)
    checkEqual(run.outcome, .success, "结果应该是成功")
    checkEqual(run.failed, 0, "不应该有失败项")

    check(exists(destination.appendingPathComponent("readme.md")), "readme.md 应该被复制")
    check(exists(destination.appendingPathComponent("docs/guide.md")), "docs/guide.md 应该被复制")
    check(exists(destination.appendingPathComponent("docs/images/a.png")), "嵌套文件应该被复制")
    check(exists(destination.appendingPathComponent("src/main.swift")), "src/main.swift 应该被复制")
    checkEqual(contents(destination.appendingPathComponent("docs/images/a.png")), "PNGDATA", "内容应一致")
    checkEqual(run.copied, 4, "应该复制 4 个文件")
}

test("复制后修改时间保持不变") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "aaa")
    let run = runSync(source: source, destination: destination)
    checkEqual(run.copied, 1, "应复制 1 个文件")
    let sourceDate = date(of: source.appendingPathComponent("a.txt"))!
    let destDate = date(of: destination.appendingPathComponent("a.txt"))!
    check(abs(sourceDate.timeIntervalSince(destDate)) < 0.01, "修改时间应该被保留，实际差 \(sourceDate.timeIntervalSince(destDate)) 秒")
}

test("文件权限被保留") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    let file = makeFile(source, "secret.txt", "s")
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    runSync(source: source, destination: destination)
    let permissions = (try? fm.attributesOfItem(atPath: destination.appendingPathComponent("secret.txt").path))?[.posixPermissions] as? NSNumber
    checkEqual(permissions?.intValue, 0o600, "权限应该是 600")
}

test("空文件夹也会被创建") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeDir(source, "空的目录/里面也空")
    let run = runSync(source: source, destination: destination)
    check(exists(destination.appendingPathComponent("空的目录")), "空目录应该被创建")
    check(exists(destination.appendingPathComponent("空的目录/里面也空")), "嵌套空目录应该被创建")
    checkEqual(run.failed, 0, "不应该有失败")
}

test("中文、空格、特殊字符文件名") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "会议记录 2024.txt", "x")
    makeFile(source, "素材/图片 #1 (最终版).txt", "y")
    makeFile(source, "emoji 🎉.txt", "z")
    runSync(source: source, destination: destination)
    check(exists(destination.appendingPathComponent("会议记录 2024.txt")), "中文名应复制")
    check(exists(destination.appendingPathComponent("素材/图片 #1 (最终版).txt")), "带空格和括号应复制")
    check(exists(destination.appendingPathComponent("emoji 🎉.txt")), "emoji 应复制")
}

test("大文件内容完整") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    var data = Data(count: 400_000)
    for index in 0..<data.count { data[index] = UInt8((index &* 31) % 251) }
    let file = source.appendingPathComponent("big.bin")
    try? data.write(to: file)
    runSync(source: source, destination: destination)
    check(fm.contentsEqual(atPath: file.path, andPath: destination.appendingPathComponent("big.bin").path),
          "400KB 二进制内容应该完全一致")
}

test("深层嵌套目录") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a/b/c/d/e/f/g/deep.txt", "deep")
    let run = runSync(source: source, destination: destination)
    checkEqual(run.failed, 0, "不应该失败")
    check(exists(destination.appendingPathComponent("a/b/c/d/e/f/g/deep.txt")), "深层文件应复制")
}

// ---------------------------------------------------------- 增量行为

test("第二次运行：无改动时不重复复制") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "aaa")
    makeFile(source, "sub/b.txt", "bbb")

    let first = runSync(source: source, destination: destination)
    checkEqual(first.copied, 2, "第一次应复制 2 个")

    let second = runSync(source: source, destination: destination)
    checkEqual(second.copied, 0, "第二次不应再复制")
    checkEqual(second.updated, 0, "第二次不应更新")
    checkEqual(second.skipped, 2, "第二次应跳过 2 个")
    checkEqual(second.brief, "无变动", "提示应是无需改动")
}

test("修改文件内容后会被重新复制") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "old")
    runSync(source: source, destination: destination)
    checkEqual(contents(destination.appendingPathComponent("a.txt")), "old", "初始内容")

    makeFile(source, "a.txt", "new content", date: baseDate.addingTimeInterval(60))
    let run = runSync(source: source, destination: destination)
    checkEqual(run.updated, 1, "应记为修改 1 个文件")
    checkEqual(run.copied, 0, "不应算作新增")
    checkEqual(contents(destination.appendingPathComponent("a.txt")), "new content", "内容应更新")
}

test("只改大小不改时间也会被重新复制") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "short")
    runSync(source: source, destination: destination)
    makeFile(source, "a.txt", "much longer content here", date: baseDate)
    let run = runSync(source: source, destination: destination)
    checkEqual(run.updated, 1, "大小不同应重新复制")
}

test("增量同步：源里删掉文件，终点保留") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "keep.txt", "keep")
    makeFile(source, "remove.txt", "remove")
    runSync(source: source, destination: destination)
    check(exists(destination.appendingPathComponent("remove.txt")), "先确认已复制")

    try? fm.removeItem(at: source.appendingPathComponent("remove.txt"))
    let run = runSync(source: source, destination: destination)
    checkEqual(run.deleted, 0, "增量同步模式不应删除任何东西")
    check(exists(destination.appendingPathComponent("remove.txt")), "终点文件应该还在")
    check(exists(destination.appendingPathComponent("keep.txt")), "其他文件不受影响")
}

// ---------------------------------------------------------- 镜像模式

test("镜像模式：源里删除的文件在终点也被删除") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "a")
    makeFile(source, "gone.txt", "g")
    runSync(source: source, destination: destination)
    try? fm.removeItem(at: source.appendingPathComponent("gone.txt"))

    let run = runSync(source: source, destination: destination, options: mirrorOptions())
    checkEqual(run.deleted, 1, "应删除 1 个文件")
    check(!exists(destination.appendingPathComponent("gone.txt")), "终点文件应被删除")
    check(exists(destination.appendingPathComponent("a.txt")), "同期文件不应被误删")
    // 回归：执行器曾把 deletions 也当成"要复制"的项去源里找，源里已经没有 → 每删一个文件
    // 就多记一次「复制失败」，界面上表现为「删除 N · 失败 N」。
    checkEqual(run.failed, 0, "删除不该产生失败计数")
    check(!run.messages.contains { $0.hasPrefix("复制失败") }, "删除项不该被当成复制项：\(run.messages)")
    checkEqual(run.outcome, .success, "只有删除时结果应为成功")
}

test("镜像模式：删目录和删子文件都不产生失败计数") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "keep.txt", "k")
    makeFile(source, "dir/inner.txt", "i")
    makeFile(source, "dir/sub/deep.txt", "d")
    runSync(source: source, destination: destination)
    check(exists(destination.appendingPathComponent("dir/sub/deep.txt")), "初次同步应复制子目录")

    // 删掉子目录里的一个文件
    try? fm.removeItem(at: source.appendingPathComponent("dir/inner.txt"))
    let first = runSync(source: source, destination: destination, options: mirrorOptions())
    checkEqual(first.deleted, 1, "应删除 1 个子文件")
    checkEqual(first.failed, 0, "删子文件不该产生失败")
    check(!exists(destination.appendingPathComponent("dir/inner.txt")), "子文件应被删除")
    check(exists(destination.appendingPathComponent("dir/sub/deep.txt")), "同目录其他文件应保留")

    // 删掉整个目录
    try? fm.removeItem(at: source.appendingPathComponent("dir"))
    let second = runSync(source: source, destination: destination, options: mirrorOptions())
    check(second.deleted >= 1, "应删除目录（含内容），实际 deleted=\(second.deleted)")
    checkEqual(second.failed, 0, "删目录不该产生失败")
    check(!exists(destination.appendingPathComponent("dir")), "目录应被整棵删掉")
    check(exists(destination.appendingPathComponent("keep.txt")), "源里还有的文件应保留")
    checkEqual(second.outcome, .success, "只删不复制时结果应为成功")
}

test("镜像模式：终点多出来的文件和目录被清理") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "a")
    makeFile(destination, "extra.txt", "x")
    makeFile(destination, "extraDir/inner.txt", "y")
    runSync(source: source, destination: destination, options: mirrorOptions())
    check(!exists(destination.appendingPathComponent("extra.txt")), "多余文件应删除")
    check(!exists(destination.appendingPathComponent("extraDir")), "多余目录应删除")
    check(exists(destination.appendingPathComponent("a.txt")), "正常文件应保留")
}

test("镜像模式安全检查：源为空时不清空终点") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(destination, "important.txt", "非常珍贵的数据")
    let run = runSync(source: source, destination: destination, options: mirrorOptions())
    check(exists(destination.appendingPathComponent("important.txt")), "源为空时不应清空终点")
    checkEqual(run.deleted, 0, "不应有删除")
    check(run.messages.contains { $0.contains("跳过镜像删除") }, "应该给出警告：\(run.messages)")
}

test("镜像模式：终点目录本身永远不会被删除") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "a")
    makeFile(destination, "junk.txt", "j")
    runSync(source: source, destination: destination, options: mirrorOptions())
    check(exists(destination), "终点目录本身必须保留")
}

// ---------------------------------------------------------- 时间戳容差

test("外接盘时间取整：1.5 秒误差不触发重拷") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "same size")
    runSync(source: source, destination: destination)
    let destinationFile = destination.appendingPathComponent("a.txt")
    setDate(destinationFile, baseDate.addingTimeInterval(1.5))
    let run = runSync(source: source, destination: destination)
    checkEqual(run.copied + run.updated, 0, "1.5 秒误差应被容忍，不应重拷")
    checkEqual(run.skipped, 1, "应跳过")
}

test("真正的时间差异仍然会重拷") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "same size")
    runSync(source: source, destination: destination)
    let destinationFile = destination.appendingPathComponent("a.txt")
    setDate(destinationFile, baseDate.addingTimeInterval(30))
    let run = runSync(source: source, destination: destination)
    checkEqual(run.updated, 1, "30 秒差异应触发更新")
}

// ---------------------------------------------------------- 安全防护

test("拒绝：终点目录在源文件夹内部") {
    let source = makeRoot("src")
    makeDir(source, "backup")
    let run = runSync(source: source, destination: source.appendingPathComponent("backup"))
    checkEqual(run.outcome, .failed, "应该失败")
    check(run.messages.contains { $0.contains("无限递归") }, "应说明原因：\(run.messages)")
}

test("拒绝：源文件夹在终点目录内部") {
    let root = makeRoot("root")
    let source = root.appendingPathComponent("inner")
    makeDir(source, "data")
    let run = runSync(source: source, destination: root)
    checkEqual(run.outcome, .failed, "应该失败")
    check(run.messages.contains { $0.contains("误删源文件") }, "应说明原因：\(run.messages)")
}

test("拒绝：终点和源是同一个文件夹") {
    let source = makeRoot("src")
    makeFile(source, "a.txt", "a")
    let run = runSync(source: source, destination: source)
    checkEqual(run.outcome, .failed, "应该失败")
    check(run.messages.contains { $0.contains("同一个文件夹") }, "应说明原因：\(run.messages)")
}

test("终点目录不存在时给出挂载提示") {
    let source = makeRoot("src")
    makeFile(source, "a.txt", "a")
    let destination = URL(fileURLWithPath: "/Volumes/不存在的硬盘/备份")
    let run = runSync(source: source, destination: destination)
    checkEqual(run.outcome, .failed, "应该失败")
    check(run.messages.contains { $0.contains("移动硬盘可能没有挂载") }, "应提示挂载：\(run.messages)")
}

test("源文件夹不存在时给出明确错误") {
    let destination = makeRoot("dst")
    let run = runSync(source: URL(fileURLWithPath: "/tmp/根本没有这个目录-\(UUID())"), destination: destination)
    checkEqual(run.outcome, .failed, "应该失败")
    check(run.messages.contains { $0.contains("源文件夹不存在") }, "应提示源不存在：\(run.messages)")
}

test("终点目录会自动创建（含多层）") {
    let source = makeRoot("src")
    let root = makeRoot("dst")
    // 终点目录本身（用户选的）必须先存在，这里模拟硬盘上已经有的深层目录
    let deepRoot = root.appendingPathComponent("盘/备份")
    try? fm.createDirectory(at: deepRoot, withIntermediateDirectories: true)
    let destination = deepRoot.appendingPathComponent("项目")
    makeFile(source, "a.txt", "a")
    let run = runSync(source: source, destination: destination, destinationRoot: deepRoot)
    checkEqual(run.outcome, .success, "应该成功：\(run.messages)")
    check(exists(destination.appendingPathComponent("a.txt")), "文件应该复制到新建的目录里")
}

test("终点目录不存在时绝不自动创建（防止误写到本机磁盘）") {
    let source = makeRoot("src")
    let root = makeRoot("dst")
    makeFile(source, "a.txt", "a")
    let missingRoot = root.appendingPathComponent("没挂载的硬盘")
    let destination = missingRoot.appendingPathComponent("项目")
    let run = runSync(source: source, destination: destination, destinationRoot: missingRoot)
    checkEqual(run.outcome, .failed, "终点目录不存在时应失败")
    check(!exists(missingRoot), "绝不能在本机磁盘上凭空造出终点目录")
    check(run.messages.contains { $0.contains("移动硬盘可能没有挂载") }, "应提示挂载：\(run.messages)")
}

// ---------------------------------------------------------- 排除规则

test("排除规则：* 通配符") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "keep.txt", "k")
    makeFile(source, "cache.tmp", "t")
    makeFile(source, "sub/also.tmp", "t2")
    var options = SyncOptions()
    options.excludePatterns = ["*.tmp"]
    runSync(source: source, destination: destination, options: options)
    check(exists(destination.appendingPathComponent("keep.txt")), "未匹配的文件应复制")
    check(!exists(destination.appendingPathComponent("cache.tmp")), "*.tmp 应被排除")
    check(!exists(destination.appendingPathComponent("sub/also.tmp")), "子目录里的 *.tmp 也应排除")
}

test("排除规则：目录名匹配时整个目录跳过") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "keep.txt", "k")
    makeFile(source, "node_modules/foo/index.js", "js")
    makeFile(source, "node_modules/foo/deep/bar.js", "js2")
    var options = SyncOptions()
    options.excludePatterns = ["node_modules"]
    runSync(source: source, destination: destination, options: options)
    check(!exists(destination.appendingPathComponent("node_modules")), "整个目录应被跳过")
    check(exists(destination.appendingPathComponent("keep.txt")), "其他文件应复制")
}

test("排除规则：带路径的 ** 匹配") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "build/out/app.bin", "b")
    makeFile(source, "build/keep.txt", "k")
    makeFile(source, "other/out/app.bin", "o")
    var options = SyncOptions()
    options.excludePatterns = ["build/**/*.bin"]
    runSync(source: source, destination: destination, options: options)
    check(!exists(destination.appendingPathComponent("build/out/app.bin")), "build 下的 .bin 应排除")
    check(exists(destination.appendingPathComponent("build/keep.txt")), "build 下的其他文件应保留")
    check(exists(destination.appendingPathComponent("other/out/app.bin")), "其他目录不受影响")
}

test("镜像模式不会删除终点里被排除规则保护的文件") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "a")
    makeFile(destination, "local-only.keep", "本地文件")
    var options = mirrorOptions()
    options.excludePatterns = ["*.keep"]
    let run = runSync(source: source, destination: destination, options: options)
    check(exists(destination.appendingPathComponent("local-only.keep")), "被排除的文件不应被镜像删除")
    checkEqual(run.deleted, 0, "不应有删除")
}

test("跳过隐藏文件") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "visible.txt", "v")
    makeFile(source, ".hidden", "h")
    makeFile(source, ".hiddendir/inside.txt", "i")
    makeFile(source, ".DS_Store", "d")
    var options = SyncOptions()
    options.skipHiddenFiles = true
    options.ignoreSystemFiles = false
    runSync(source: source, destination: destination, options: options)
    check(exists(destination.appendingPathComponent("visible.txt")), "普通文件应复制")
    check(!exists(destination.appendingPathComponent(".hidden")), "隐藏文件应跳过")
    check(!exists(destination.appendingPathComponent(".hiddendir")), "隐藏目录应跳过")
}

test("默认忽略 .DS_Store 等系统文件") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "a")
    makeFile(source, ".DS_Store", "junk")
    makeFile(source, ".Spotlight-V100/index", "junk")
    makeFile(source, ".document", "隐藏但有用")
    let run = runSync(source: source, destination: destination)
    check(!exists(destination.appendingPathComponent(".DS_Store")), ".DS_Store 应被忽略")
    check(!exists(destination.appendingPathComponent(".Spotlight-V100")), "Spotlight 索引应被忽略")
    check(exists(destination.appendingPathComponent(".document")), "普通隐藏文件默认不跳过")
    checkEqual(run.copied, 2, "应复制 a.txt 和 .document")
}

// ---------------------------------------------------------- 特殊条目

test("符号链接按链接本身复制") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "real.txt", "real")
    try? fm.createSymbolicLink(atPath: source.appendingPathComponent("link.txt").path,
                               withDestinationPath: "real.txt")
    let run = runSync(source: source, destination: destination)
    checkEqual(run.failed, 0, "不应失败：\(run.messages)")
    let linkPath = destination.appendingPathComponent("link.txt").path
    check(exists(URL(fileURLWithPath: linkPath)), "链接应存在")
    let target = try? fm.destinationOfSymbolicLink(atPath: linkPath)
    checkEqual(target, "real.txt", "链接指向应保持")
}

test("终点是文件但源是目录时能正确覆盖") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "thing/inner.txt", "inner")
    makeFile(destination, "thing", "我是一个文件")
    let run = runSync(source: source, destination: destination)
    checkEqual(run.failed, 0, "不应失败：\(run.messages)")
    check(exists(destination.appendingPathComponent("thing/inner.txt")), "目录结构应建立")
}

test("终点是目录但源是文件时能正确覆盖") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "thing", "我是文件")
    makeDir(destination, "thing/inside")
    let run = runSync(source: source, destination: destination)
    checkEqual(run.failed, 0, "不应失败：\(run.messages)")
    checkEqual(contents(destination.appendingPathComponent("thing")), "我是文件", "应替换为文件")
}

test("同步后不留下临时文件") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "a")
    makeFile(source, "sub/b.txt", "b")
    runSync(source: source, destination: destination)
    let leftovers = allRelativePaths(destination).filter { $0.contains(SyncOptions.temporaryPrefix) }
    checkEqual(leftovers.count, 0, "不应残留临时文件：\(leftovers)")
}

test("覆盖已有文件时不留临时文件") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "version 1")
    runSync(source: source, destination: destination)
    makeFile(source, "a.txt", "version 2 is longer", date: baseDate.addingTimeInterval(60))
    runSync(source: source, destination: destination)
    checkEqual(contents(destination.appendingPathComponent("a.txt")), "version 2 is longer", "内容应更新")
    let leftovers = allRelativePaths(destination).filter { $0.contains(SyncOptions.temporaryPrefix) }
    checkEqual(leftovers.count, 0, "不应残留临时文件：\(leftovers)")
}

// ---------------------------------------------------------- 进度与取消

test("进度回调单调推进并最终完成") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    for index in 0..<12 {
        makeFile(source, "dir\(index)/file\(index).txt", "content \(index)")
    }
    var snapshots: [SyncProgress] = []
    let run = runSync(source: source, destination: destination) { snapshots.append($0) }
    checkEqual(run.outcome, .success, "应该成功")
    check(!snapshots.isEmpty, "应该有进度回调")
    checkEqual(snapshots.last?.completed, snapshots.last?.total, "最后应全部完成")
    checkEqual(snapshots.last?.fraction, 1.0, "最后进度应为 100%")
    checkEqual(snapshots.last?.total, 24, "总数应为 24 项（12 个目录 + 12 个文件）")
    var monotonic = true
    for index in 1..<snapshots.count where snapshots[index].completed < snapshots[index - 1].completed {
        monotonic = false
    }
    check(monotonic, "完成数不应回退")
    checkEqual(snapshots.last?.bytesTotal, snapshots.last?.bytesCopied, "字节数应一致")
}

test("取消后立即停止且标记为已取消") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    for index in 0..<30 {
        makeFile(source, "file\(index).txt", "content \(index)")
    }
    let cancellation = SyncCancellation()
    cancellation.cancel()
    let run = runSync(source: source, destination: destination, cancellation: cancellation)
    checkEqual(run.outcome, .cancelled, "应标记为已取消")
    checkEqual(run.copied, 0, "取消后不应复制任何文件")
    check(!exists(destination.appendingPathComponent("file0.txt")), "终点应该是空的")
}

test("取消令牌被正确传递") {
    let token = SyncCancellation()
    check(!token.isCancelled, "初始不应是取消状态")
    token.cancel()
    check(token.isCancelled, "调用 cancel 后应为取消状态")
    check(token.isCancelled, "多次读取应保持稳定")
}

// ---------------------------------------------------------- 计划预览

test("预览计划统计正确且不落盘") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "aaa")
    makeFile(source, "b/c.txt", "cccc")
    makeFile(source, "newdir/d.txt", "dd")

    var options = SyncOptions()
    options.trashDeletions = false
    let plan = SyncPlanner.makePlan(source: source, destination: destination, options: options)
    checkEqual(plan.blockingError, nil, "不应有阻塞错误")
    checkEqual(plan.copies.count, 3, "应计划复制 3 个文件")
    checkEqual(plan.directories.count, 2, "应计划新建 2 个目录（b 和 newdir）")
    checkEqual(plan.deletions.count, 0, "不应有删除")
    checkEqual(plan.bytesToCopy, 9, "预计字节数应为 9")
    checkEqual(plan.skippedFiles, 0, "不应有跳过")
    check(!exists(destination.appendingPathComponent("a.txt")), "预览不应真正写入文件")
}

test("预览能看出镜像模式要删除的内容") {
    let source = makeRoot("src")
    let destination = makeRoot("dst")
    makeFile(source, "a.txt", "a")
    makeFile(destination, "zombie.txt", "z")
    var options = SyncOptions()
    options.mode = .mirror
    let plan = SyncPlanner.makePlan(source: source, destination: destination, options: options)
    checkEqual(plan.deletions.count, 1, "应计划删除 1 项")
    checkEqual(plan.deletions.first?.relativePath, "zombie.txt", "应指向 zombie.txt")
    check(plan.isDestructive, "应标记为破坏性操作")
    check(exists(destination.appendingPathComponent("zombie.txt")), "预览本身不应删除文件")
}

test("预览报告阻塞错误而不是抛出") {
    let plan = SyncPlanner.makePlan(source: URL(fileURLWithPath: "/tmp/nope-\(UUID())"),
                                    destination: makeRoot("dst"),
                                    options: SyncOptions())
    check(plan.blockingError != nil, "应返回阻塞错误")
    check(!plan.hasWork, "不应有计划项")
}

// ---------------------------------------------------------- 模型

test("任务：终点路径按规则拼接") {
    var task = SyncTask()
    task.sourcePath = "/Users/me/Documents/我的项目"
    task.destinationRoot = "/Volumes/Backup"
    task.createSubfolder = true
    checkEqual(task.destinationURL.path, "/Volumes/Backup/我的项目", "应自动创建同名子文件夹")
    checkEqual(task.effectiveSubfolderName, "我的项目", "子文件夹名应与源同名")

    task.subfolderName = "自定义名字"
    checkEqual(task.destinationURL.path, "/Volumes/Backup/自定义名字", "应使用自定义名字")

    task.createSubfolder = false
    checkEqual(task.destinationURL.path, "/Volumes/Backup", "关闭子文件夹时直接写入终点目录")

    checkEqual(task.displayName, "我的项目", "任务名固定取源文件夹名")
}

test("任务：排除规则会去掉空行和注释") {
    var task = SyncTask()
    task.excludePatterns = ["*.tmp", "", "   ", "# 这是注释", "node_modules"]
    checkEqual(task.exclusionPatterns, ["*.tmp", "node_modules"],
               "空行和 # 注释行都应被忽略")
}

test("计划：间隔模式到点判断") {
    let schedule = SyncSchedule(mode: .interval, intervalMinutes: 30)
    let now = Date()
    checkEqual(schedule.dueState(lastRun: now.addingTimeInterval(-60), now: now).due, false, "刚同步过不应触发")
    checkEqual(schedule.dueState(lastRun: now.addingTimeInterval(-1801), now: now).due, true, "超过 30 分钟应触发")
    checkEqual(schedule.dueState(lastRun: nil, now: now).due, false, "从未同步过时从此刻开始计时")
    checkEqual(schedule.summary, "每 30 分钟自动同步", "描述文案")
}

test("计划：每天定时到点判断") {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let schedule = SyncSchedule(mode: .daily, dailyHour: 3, dailyMinute: 0)

    let today = calendar.date(from: DateComponents(year: 2024, month: 5, day: 20, hour: 10, minute: 0))!
    let yesterday = calendar.date(from: DateComponents(year: 2024, month: 5, day: 19, hour: 10, minute: 0))!
    checkEqual(schedule.dueState(lastRun: nil, now: today, calendar: calendar).due, true, "今天 3 点已过且从未同步，应触发")
    checkEqual(schedule.dueState(lastRun: today, now: today, calendar: calendar).due, false, "今天已同步过，不应再触发")
    checkEqual(schedule.dueState(lastRun: yesterday, now: today, calendar: calendar).due, true, "昨天同步过，今天应触发")

    let before = calendar.date(from: DateComponents(year: 2024, month: 5, day: 20, hour: 1, minute: 0))!
    checkEqual(schedule.dueState(lastRun: yesterday, now: before, calendar: calendar).due, false, "还没到 3 点不应触发")
    checkEqual(schedule.summary, "每天 03:00 自动同步", "描述文案")
}

test("运行记录：摘要文案") {
    var run = SyncRun(taskID: UUID(), taskName: "t", trigger: "manual")
    checkEqual(run.brief, "无变动", "无改动时的文案")
    run.copied = 3
    run.updated = 2
    run.deleted = 1
    run.skipped = 10
    checkEqual(run.brief, "新增 3 · 修改 2 · 删除 1", "摘要应包含各项（跳过的不再显示）")
    checkEqual(run.skipped, 10, "跳过的数量仍然记录着，只是不显示")
    checkEqual(run.changedCount, 6, "改动计数")
}

test("配置：JSON 往返与缺字段兼容") {
    var task = SyncTask()
    task.sourcePath = "/Users/me/照片"
    task.destinationRoot = "/Volumes/Photo"
    task.mode = .mirror
    task.schedule = SyncSchedule(mode: .interval, intervalMinutes: 120)
    task.excludePatterns = ["*.tmp"]

    var config = AppConfig()
    config.tasks = [task]
    config.runAtLogin = true

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    guard let data = try? encoder.encode(config),
          let decoded = try? decoder.decode(AppConfig.self, from: data) else {
        check(false, "配置应能编码解码")
        return
    }
    checkEqual(decoded.tasks.count, 1, "任务数量")
    checkEqual(decoded.tasks[0].displayName, "照片", "任务名取自源文件夹名")
    checkEqual(decoded.tasks[0].mode, .mirror, "同步模式")
    checkEqual(decoded.tasks[0].schedule.intervalMinutes, 120, "间隔")
    checkEqual(decoded.runAtLogin, true, "开机自启")

    // 老版本配置里没有的字段不应导致解析失败
    let legacy = """
    {"tasks":[{"id":"\(UUID().uuidString)","sourcePath":"/a","destinationRoot":"/b","mode":"additive"}]}
    """.data(using: .utf8)!
    let legacyDecoded = try? decoder.decode(AppConfig.self, from: legacy)
    check(legacyDecoded != nil, "缺少新字段的旧配置应能解析")
    checkEqual(legacyDecoded?.tasks.first?.createSubfolder, true, "缺失字段应取默认值")
    checkEqual(legacyDecoded?.tasks.first?.schedule.mode, .manual, "缺失计划应默认手动")
}

test("展示文案：时间与体积") {
    checkEqual(Fmt.relative(nil), "从未同步", "没有记录时的文案")
    checkEqual(Fmt.relative(Date()), "刚刚", "刚同步完不该显示「0 秒后」")
    checkEqual(Fmt.relative(Date().addingTimeInterval(-30)), "刚刚", "一分钟内都算刚刚")
    check(Fmt.relative(Date().addingTimeInterval(-7200)).contains("小时"), "两小时前应提到小时")
    check(!Fmt.bytes(0).isEmpty, "0 字节能正常格式化")
    check(!Fmt.bytes(5_000_000).isEmpty, "大体积能正常格式化")
    checkEqual(Fmt.prettyPath(NSHomeDirectory() + "/Documents"), "~/Documents", "家目录缩写成 ~")
}

test("通配符编译") {    checkEqual(GlobMatcher.regexPattern(from: "*.tmp"), "^[^/]*\\.tmp$", "*.tmp")
    checkEqual(GlobMatcher.regexPattern(from: "a?c"), "^a[^/]c$", "a?c")
    checkEqual(GlobMatcher.regexPattern(from: "node_modules"), "^node_modules$", "目录名")
    checkEqual(GlobMatcher.regexPattern(from: "build/**/*.bin"), "^build/(?:.*/)?[^/]*\\.bin$", "**/ 前缀")
    check(GlobMatcher.matches(pattern: "*.tmp", name: "x.tmp", relativePath: "a/x.tmp"), "应匹配")
    check(!GlobMatcher.matches(pattern: "*.tmp", name: "x.txt", relativePath: "a/x.txt"), "不应匹配")
    check(GlobMatcher.matches(pattern: "sub/*.txt", name: "a.txt", relativePath: "sub/a.txt"), "带路径应匹配相对路径")
    check(!GlobMatcher.matches(pattern: "sub/*.txt", name: "a.txt", relativePath: "other/a.txt"), "带路径不应跨目录匹配")
    check(GlobMatcher.matches(pattern: "*.TMP", name: "x.tmp", relativePath: "x.tmp"), "匹配应忽略大小写")
}

// ============================================================
//  汇总
// ============================================================

// 清理临时目录
for root in createdRoots {
    try? fm.removeItem(at: root)
}
if let container = fm.temporaryDirectory.appendingPathComponent("foldersync-tests") as URL? {
    try? fm.removeItem(at: container)
}

print("")
if failures.isEmpty {
    print("全部通过：\(passed) 项断言")
    exit(0)
} else {
    print("失败 \(failed) 项，通过 \(passed) 项：\n")
    for failure in failures {
        print("  ✗ \(failure)")
    }
    exit(1)
}
