import Foundation

/// 生产用实现:真实文件系统。
public struct SystemFileSystem: FileSystem {
    public init() {}

    // FileManager 不是 Sendable,不能作为存储属性放进 Sendable 类型 ——
    // 这是 P0-03 严格并发检查的直接结果。改为每次调用时取用:
    // FileManager.default 对这里用到的这些操作是线程安全的,
    // 而且不跨隔离域传递实例,就不存在数据竞争。
    private var manager: FileManager { .default }

    public func exists(at url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    public func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        let found = manager.fileExists(atPath: url.path, isDirectory: &isDir)
        return found && isDir.boolValue
    }

    public func read(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw Self.map(error, url: url)
        }
    }

    public func write(_ data: Data, to url: URL) throws {
        do {
            // 这里刻意用非原子写。原子性由 replaceItem 提供,
            // 上层组合出「临时文件 + 替换」的完整语义(P1-05)。
            try data.write(to: url, options: [])
        } catch {
            throw Self.map(error, url: url)
        }
    }

    public func createDirectory(at url: URL) throws {
        do {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw Self.map(error, url: url)
        }
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        do {
            return try manager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw Self.map(error, url: url)
        }
    }

    public func removeItem(at url: URL) throws {
        do {
            try manager.removeItem(at: url)
        } catch {
            throw Self.map(error, url: url)
        }
    }

    public func replaceItem(at destination: URL, withItemAt source: URL) throws {
        // 直接用 POSIX rename(2):同一文件系统内原子,且目标已存在时会覆盖。
        // FileManager 没有对等语义 —— moveItem 在目标存在时失败,
        // replaceItemAt 会做备份腾挪并要求原件存在,两者都不是我们要的保证。
        let status = source.withUnsafeFileSystemRepresentation { src -> Int32 in
            guard let src else { return -1 }
            return destination.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let dst else { return -1 }
                return rename(src, dst)
            }
        }
        if status != 0 {
            throw Self.map(errno: errno, url: destination)
        }
    }

    // MARK: - 错误映射

    /// 把 Cocoa / POSIX 错误映射到 `FileSystemError`。
    ///
    /// 映射不全的一律落到 `.io`,并保留原始描述 —— 宁可信息粗糙,
    /// 也不要把未知错误伪装成已知类型,那会让上层做出错误的恢复决策。
    static func map(_ error: any Error, url: URL) -> FileSystemError {
        if let fsError = error as? FileSystemError { return fsError }
        let nsError = error as NSError

        if nsError.domain == NSPOSIXErrorDomain {
            return map(errno: Int32(nsError.code), url: url)
        }

        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .notFound(url)
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return .permissionDenied(url)
            case NSFileWriteOutOfSpaceError:
                return .diskFull(url)
            case NSFileWriteFileExistsError:
                return .alreadyExists(url)
            default:
                // Cocoa 常把底层 POSIX 错误藏在 underlying error 里。
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
                   underlying.domain == NSPOSIXErrorDomain {
                    return map(errno: Int32(underlying.code), url: url)
                }
            }
        }

        return .io(url: url, detail: nsError.localizedDescription)
    }

    static func map(errno code: Int32, url: URL) -> FileSystemError {
        switch code {
        case ENOENT: return .notFound(url)
        case EACCES, EPERM: return .permissionDenied(url)
        case ENOSPC, EDQUOT: return .diskFull(url)
        case ENOTDIR: return .notADirectory(url)
        case EEXIST: return .alreadyExists(url)
        default:
            return .io(url: url, detail: String(cString: strerror(code)))
        }
    }
}
