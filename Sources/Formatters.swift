import Foundation

enum Fmt {
    static func bytes(_ value: Int64) -> String {
        // 0 字节时 ByteCountFormatter 会输出本地化的「Zero KB / 零 KB」这种词，
        // 放在「数据量」后面很怪，直接给「0 KB」。
        if value == 0 { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: value)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "从未同步" }
        let interval = Date().timeIntervalSince(date)
        // 刚刚同步完时 RelativeDateTimeFormatter 会输出「0 秒后」，读起来很怪
        if abs(interval) < 60 { return "刚刚" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func absolute(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        if seconds < 1 { return String(format: "%.0f 毫秒", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1f 秒", seconds) }
        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        return "\(minutes) 分 \(rest) 秒"
    }

    /// 把系统错误翻成中文。
    ///
    /// 系统给的 `localizedDescription` 是英文（例如「You don't have permission to save the
    /// file …」），直接显示在界面上既看不懂也没帮助。这里按错误码给中文说明；
    /// 认不出的错误只报「错误码 N」，**不把英文原文抛给用户**。
    static func errorText(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return "没有访问权限"
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return "文件不存在"
            case NSFileWriteOutOfSpaceError:
                return "磁盘空间不足"
            case NSFileWriteVolumeReadOnlyError:
                return "目标磁盘是只读的"
            case NSFileWriteFileExistsError:
                return "同名文件已存在"
            case NSFileWriteInvalidFileNameError:
                return "文件名不合法"
            case NSFileWriteUnknownError, NSFileReadUnknownError:
                return "读写失败（原因未知）"
            default:
                break
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            switch Int32(ns.code) {
            case EACCES: return "没有访问权限"
            case EPERM: return "操作被系统拒绝"
            case ENOENT: return "文件不存在"
            case ENOSPC: return "磁盘空间不足"
            case EROFS: return "目标磁盘是只读的"
            case EBUSY: return "文件正被其他程序占用"
            case EDQUOT: return "已超出磁盘配额"
            default: break
            }
        }
        return "错误码 \(ns.code)"
    }

    /// 是不是「没有访问权限」这类错误。
    /// 这类失败不该只报错了事 —— 界面要弹窗引导用户去授权。
    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            return ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError
        }
        if ns.domain == NSPOSIXErrorDomain {
            return Int32(ns.code) == EACCES || Int32(ns.code) == EPERM
        }
        return false
    }

    /// 把路径压缩成 ~/Documents/xxx 的形式，方便阅读。
    static func prettyPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
