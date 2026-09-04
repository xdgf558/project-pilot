import Darwin
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
        // 契约限定为文件(见协议文档)。这里先拒绝目录,让真假两个实现在
        // 同一个点上失败,而不是各自走进 POSIX 的目录 rename 分支。
        // 代价是多一次 stat —— 相对于随后的写入加 fsync 可以忽略。
        if isDirectory(at: source) { throw FileSystemError.isDirectory(source) }
        if isDirectory(at: destination) { throw FileSystemError.isDirectory(destination) }

        // rename(2) 的 ENOENT 既可能是源不存在,也可能是目标的父目录不存在,
        // 而 errno 不区分。下面统一按目标路径报错,所以这里先把「源不存在」
        // 单独挑出来 —— 源缺失却指着目标路径喊 notFound,会把排查引向错误的地方。
        if !exists(at: source) { throw FileSystemError.notFound(source) }

        // 直接用 POSIX rename(2):同一文件系统内原子,且目标已存在时会覆盖。
        // FileManager 没有对等语义 —— moveItem 在目标存在时失败,
        // replaceItemAt 会做备份腾挪并要求原件存在,两者都不是我们要的保证。
        let status = source.withUnsafeFileSystemRepresentation { src -> Int32 in
            // 路径无法转成文件系统表示时必须自己设 errno,
            // 否则下面读到的是上一次系统调用留下的陈旧值。
            guard let src else { errno = EINVAL; return -1 }
            return destination.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let dst else { errno = EINVAL; return -1 }
                return rename(src, dst)
            }
        }
        if status != 0 {
            throw Self.map(errno: errno, url: destination)
        }
    }

    public func withExclusiveLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        // 锁文件是稳定路径:state.json.lock 永远不被 rename,
        // 所有进程打开的都是同一个 inode,flock 才有跨进程意义。
        let lockPath = URL(fileURLWithPath: url.path + ".lock")
        let fd = open(lockPath.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw Self.map(errno: errno, url: lockPath)
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw Self.map(errno: errno, url: lockPath)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
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
        case EISDIR: return .isDirectory(url)
        case EEXIST: return .alreadyExists(url)
        default:
            return .io(url: url, detail: String(cString: strerror(code)))
        }
    }
}
