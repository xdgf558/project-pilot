import Foundation

/// 文件系统操作的错误。
///
/// 真实实现必须把 POSIX / Cocoa 错误映射到这些 case,假实现直接抛出对应 case ——
/// 这样「磁盘满时状态机怎么办」这类测试写一次,对两种实现都成立。
/// 没有这层映射,故障注入测试只能验证假实现自己的行为,证明不了真实环境。
public enum FileSystemError: Error, Equatable, Sendable {
    case notFound(URL)
    case permissionDenied(URL)
    case diskFull(URL)
    case notADirectory(URL)
    /// 目标是目录,但这个操作只接受文件。对应 POSIX 的 `EISDIR`。
    case isDirectory(URL)
    case alreadyExists(URL)
    case io(url: URL, detail: String)
}

/// 文件系统抽象。
///
/// 只暴露 ProjectStore 真正需要的原语。**原子写不在这里** —— 那是
/// 「同目录唯一临时文件 → 写 → flush → 原子替换」的组合动作,属于 P1-05,
/// 由上层用 `write` 加 `replaceItem` 拼出来。这一层只保证每个原语本身的语义。
///
/// 任何实现都必须通过 `FileSystemContractTests` 里的全部用例。
public protocol FileSystem: Sendable {
    func exists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool

    func read(at url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws

    /// 创建目录,包含所有中间层级。目录已存在时不报错。
    func createDirectory(at url: URL) throws

    /// 列出目录直接子项。顺序不保证,调用方要排序。
    func contentsOfDirectory(at url: URL) throws -> [URL]

    func removeItem(at url: URL) throws

    /// 原子替换:把 `source` 移动到 `destination`,覆盖已存在的目标。
    ///
    /// 这是整个数据层的地基。真实实现用 POSIX `rename(2)` —— 同一文件系统内它是原子的,
    /// 要么完全生效要么完全不生效,不存在「替换到一半」的中间态。
    /// 崩溃恢复能成立就靠这个保证。
    ///
    /// **契约限定为文件。** source 或 destination 是目录时抛 `.isDirectory`。
    ///
    /// 在与 `url` 关联的**跨进程**排他锁下执行 `body`。
    ///
    /// ProjectStore 用它把「读盘校验 → 临时写 → rename」包成一个事务:
    /// check-then-act 的窗口必须被锁住,否则两个进程都能通过校验、
    /// 后写的覆盖先写的 —— rename 的原子性只保证单次替换没有半成品,
    /// 保证不了「确认 r1 之后 r1 还是 r1」。
    ///
    /// 锁落在稳定路径上(`url` + ".lock"),**从不被 rename** ——
    /// flock 建立在 inode 上,锁一个会被替换的文件,
    /// 后续的锁请求会被引到新 inode 上去,等于没锁。
    /// 进程崩溃时内核自动释放,不存在陈旧锁。
    ///
    /// 阻塞语义:拿不到就等。乐观并发的冲突由 body 内部的 revision
    /// 校验负责,不该由锁把合法的顺序写入变成错误。
    /// 读操作不需要加锁 —— replace 的原子性保证读不到半截文件。
    func withExclusiveLock<T>(at url: URL, _ body: () throws -> T) throws -> T

    /// 这是刻意收窄的。目录 rename 的 POSIX 语义有一串交叉规则 ——
    /// 目标是非空目录报 `ENOTEMPTY`、目录覆盖到文件报 `ENOTDIR`、
    /// 反向报 `EISDIR` —— 在内存实现里把这些全补齐,是为一个当前没人需要的能力
    /// 造出三个新的真假分歧面。数据层的原子写(P1-05)只动文件。
    /// 将来真需要移动目录时,再作为一个明确的决定加进来。
    func replaceItem(at destination: URL, withItemAt source: URL) throws
}
