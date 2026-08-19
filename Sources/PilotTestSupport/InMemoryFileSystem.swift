import Foundation
import PilotInfrastructure

/// 内存文件系统,支持故障注入。
///
/// 存在的理由是 P1-12:「覆盖 10 个并发 command、写到一半崩溃、磁盘满、
/// 权限拒绝、文件被替换和迁移失败」。这些场景在真实磁盘上要么造不出来,
/// 要么造出来就毁了开发机 —— 你没法真的把 CI 机器的盘写满来测一条错误分支。
///
/// 它必须通过与 `SystemFileSystem` 完全相同的契约测试。
/// 一个只跟自己一致的假实现,证明不了任何关于真实环境的事。
public final class InMemoryFileSystem: FileSystem, @unchecked Sendable {

    /// 可被注入故障的操作。
    public enum Operation: String, Sendable, CaseIterable {
        case read, write, createDirectory, contentsOfDirectory, removeItem, replaceItem
    }

    /// 注入的故障类型。
    public enum Fault: Sendable, Equatable {
        case diskFull
        case permissionDenied
        case notFound
        /// 写入前 `bytes` 个字节后失败。用于「写到一半崩溃」——
        /// 崩溃恢复最难的不是文件没了,而是文件在那儿但只有半截。
        case partialWrite(bytes: Int)
        case io(String)
    }

    private enum Node {
        case file(Data)
        case directory
    }

    private struct FaultRule {
        let operation: Operation
        let path: String?
        let fault: Fault
        var remaining: Int
    }

    // 用递归锁,这样 onOperation 回调里可以再调用本对象 ——
    // 「文件被替换」场景正需要在一次操作中途改动文件系统。
    private let lock = NSRecursiveLock()
    private var nodes: [String: Node] = ["/": .directory]
    private var faults: [FaultRule] = []
    private var hook: (@Sendable (Operation, URL) -> Void)?

    public init() {}

    // MARK: - 故障注入

    /// 让接下来 `times` 次匹配的操作失败。
    /// - Parameter url: 传 nil 表示匹配任意路径。
    public func failNext(
        _ operation: Operation,
        at url: URL? = nil,
        with fault: Fault,
        times: Int = 1
    ) {
        lock.lock()
        defer { lock.unlock() }
        faults.append(
            FaultRule(operation: operation, path: url.map(Self.key), fault: fault, remaining: times)
        )
    }

    /// 清除所有未触发的故障规则。
    public func clearFaults() {
        lock.lock()
        defer { lock.unlock() }
        faults.removeAll()
    }

    /// 每次操作执行**之前**调用。回调内可以再操作本文件系统,
    /// 用来构造「读到一半文件被换掉」这类竞态。
    public func onOperation(_ hook: (@Sendable (Operation, URL) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        self.hook = hook
    }

    // MARK: - 测试观察点

    /// 当前所有路径,已排序。
    public var allPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return nodes.keys.sorted()
    }

    /// 直接读取文件内容,不经过故障注入 —— 用于断言,不用于被测代码。
    public func storedContents(at url: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if case .file(let data) = nodes[Self.key(url)] { return data }
        return nil
    }

    // MARK: - FileSystem

    public func exists(at url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nodes[Self.key(url)] != nil
    }

    public func isDirectory(at url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .directory = nodes[Self.key(url)] { return true }
        return false
    }

    public func read(at url: URL) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try begin(.read, url)

        switch nodes[Self.key(url)] {
        case .file(let data): return data
        case .directory: throw FileSystemError.io(url: url, detail: "是目录,不是文件")
        case nil: throw FileSystemError.notFound(url)
        }
    }

    public func write(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }

        let path = Self.key(url)
        // 故障要在参数校验之后判断:真实文件系统也是先解析路径再遇到 ENOSPC。
        try requireParentDirectory(of: path, url: url)
        if case .directory = nodes[path] {
            throw FileSystemError.alreadyExists(url)
        }
        try begin(.write, url, partialWrite: { prefix in
            self.nodes[path] = .file(data.prefix(prefix))
        })

        nodes[path] = .file(data)
    }

    public func createDirectory(at url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try begin(.createDirectory, url)

        let path = Self.key(url)
        switch nodes[path] {
        case .directory: return          // 已存在,幂等,与 withIntermediateDirectories: true 一致
        case .file: throw FileSystemError.alreadyExists(url)
        case nil: break
        }

        // 逐层建立中间目录。
        var components: [String] = []
        var cursor: String? = path
        while let current = cursor, current != "/" {
            components.append(current)
            cursor = Self.parent(of: current)
        }
        for component in components.reversed() {
            if case .file = nodes[component] {
                throw FileSystemError.alreadyExists(URL(fileURLWithPath: component))
            }
            nodes[component] = .directory
        }
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        try begin(.contentsOfDirectory, url)

        let path = Self.key(url)
        switch nodes[path] {
        case .directory: break
        case .file: throw FileSystemError.notADirectory(url)
        case nil: throw FileSystemError.notFound(url)
        }

        return nodes.keys
            .filter { $0 != path && Self.parent(of: $0) == path }
            .map { URL(fileURLWithPath: $0) }
    }

    public func removeItem(at url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try begin(.removeItem, url)

        let path = Self.key(url)
        guard nodes[path] != nil else { throw FileSystemError.notFound(url) }

        // 连同全部后代一起删。
        let prefix = path == "/" ? "/" : path + "/"
        for key in nodes.keys where key == path || key.hasPrefix(prefix) {
            nodes.removeValue(forKey: key)
        }
    }

    public func replaceItem(at destination: URL, withItemAt source: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        try begin(.replaceItem, destination)

        let sourcePath = Self.key(source)
        let destinationPath = Self.key(destination)
        guard let node = nodes[sourcePath] else { throw FileSystemError.notFound(source) }
        try requireParentDirectory(of: destinationPath, url: destination)

        nodes[destinationPath] = node
        nodes.removeValue(forKey: sourcePath)
    }

    // MARK: - 内部

    /// 检查并消耗一条匹配的故障规则。
    private func begin(
        _ operation: Operation,
        _ url: URL,
        partialWrite: ((Int) -> Void)? = nil
    ) throws {
        hook?(operation, url)

        let path = Self.key(url)
        guard let index = faults.firstIndex(where: {
            $0.operation == operation && $0.remaining > 0 && ($0.path == nil || $0.path == path)
        }) else { return }

        faults[index].remaining -= 1
        switch faults[index].fault {
        case .diskFull: throw FileSystemError.diskFull(url)
        case .permissionDenied: throw FileSystemError.permissionDenied(url)
        case .notFound: throw FileSystemError.notFound(url)
        case .io(let detail): throw FileSystemError.io(url: url, detail: detail)
        case .partialWrite(let bytes):
            // 先落下半截数据,再报盘满 —— 这才是崩溃恢复真正要面对的现场。
            partialWrite?(bytes)
            throw FileSystemError.diskFull(url)
        }
    }

    private func requireParentDirectory(of path: String, url: URL) throws {
        guard let parent = Self.parent(of: path) else { return }
        switch nodes[parent] {
        case .directory: return
        case .file: throw FileSystemError.notADirectory(URL(fileURLWithPath: parent))
        case nil: throw FileSystemError.notFound(url)
        }
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func parent(of path: String) -> String? {
        guard path != "/" else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}
