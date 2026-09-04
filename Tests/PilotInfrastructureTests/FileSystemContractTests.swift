import Foundation
import Testing
import PilotInfrastructure
import PilotTestSupport

/// FileSystem 的契约测试。
///
/// **每个用例都对 `InMemoryFileSystem` 和 `SystemFileSystem` 各跑一遍。**
/// 这是这套替身能不能被信任的全部依据 —— 一个只跟自己一致的假实现,
/// 证明不了任何关于真实环境的事。真实实现的错误映射错了、
/// 假实现的语义偏了,都会在这里暴露。
@Suite("FileSystem 契约")
struct FileSystemContractTests {

    enum Implementation: String, CaseIterable, Sendable {
        case inMemory
        case system
    }

    /// 每个用例拿到一个干净的根目录和对应实现。
    private func makeSubject(_ implementation: Implementation) throws
        -> (fileSystem: any FileSystem, root: URL, cleanup: @Sendable () -> Void)
    {
        let root = URL(fileURLWithPath: "/pilot-test-\(UUID().uuidString)")
        switch implementation {
        case .inMemory:
            let fileSystem = InMemoryFileSystem()
            try fileSystem.createDirectory(at: root)
            return (fileSystem, root, {})
        case .system:
            let real = FileManager.default.temporaryDirectory
                .appendingPathComponent("pilot-test-\(UUID().uuidString)", isDirectory: true)
            let fileSystem = SystemFileSystem()
            try fileSystem.createDirectory(at: real)
            return (fileSystem, real, { try? FileManager.default.removeItem(at: real) })
        }
    }

    // MARK: - 读写

    @Test("写入后读回内容一致", arguments: Implementation.allCases)
    func writeThenRead(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let file = root.appendingPathComponent("state.json")
        let payload = Data("{\"revision\":1}".utf8)
        try fs.write(payload, to: file)

        #expect(fs.exists(at: file))
        #expect(fs.isDirectory(at: file) == false)
        #expect(try fs.read(at: file) == payload)
    }

    @Test("覆盖写替换全部内容", arguments: Implementation.allCases)
    func overwriteReplacesContent(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let file = root.appendingPathComponent("a.txt")
        try fs.write(Data("aaaaaaaaaa".utf8), to: file)
        try fs.write(Data("bb".utf8), to: file)

        // 覆盖写必须是替换而不是叠加 —— 若残留旧内容尾巴,JSON 会解析失败。
        #expect(try fs.read(at: file) == Data("bb".utf8))
    }

    @Test("读不存在的文件报 notFound", arguments: Implementation.allCases)
    func readMissingThrowsNotFound(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let missing = root.appendingPathComponent("nope.json")
        #expect(throws: FileSystemError.notFound(missing)) {
            _ = try fs.read(at: missing)
        }
    }

    @Test("写入父目录不存在的路径会失败", arguments: Implementation.allCases)
    func writeWithoutParentFails(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let nested = root.appendingPathComponent("missing-dir/file.json")
        // 断言到具体 case 而不是 (any Error).self ——
        // 弱断言下,错误映射改坏了这条路径照样绿,等于没测。
        #expect(throws: FileSystemError.notFound(nested)) {
            try fs.write(Data("x".utf8), to: nested)
        }
        #expect(fs.exists(at: nested) == false)
    }

    // MARK: - 目录

    @Test("创建目录含中间层级", arguments: Implementation.allCases)
    func createDirectoryWithIntermediates(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let deep = root.appendingPathComponent("projects/abc/backups", isDirectory: true)
        try fs.createDirectory(at: deep)

        #expect(fs.isDirectory(at: deep))
        #expect(fs.isDirectory(at: root.appendingPathComponent("projects", isDirectory: true)))
    }

    @Test("重复创建同一目录不报错", arguments: Implementation.allCases)
    func createDirectoryIsIdempotent(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let dir = root.appendingPathComponent("jobs", isDirectory: true)
        try fs.createDirectory(at: dir)
        try fs.createDirectory(at: dir)   // 不应抛错

        #expect(fs.isDirectory(at: dir))
    }

    @Test("列目录只返回直接子项", arguments: Implementation.allCases)
    func contentsListsDirectChildrenOnly(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        try fs.write(Data("1".utf8), to: root.appendingPathComponent("a.txt"))
        try fs.write(Data("2".utf8), to: root.appendingPathComponent("b.txt"))
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try fs.createDirectory(at: sub)
        try fs.write(Data("3".utf8), to: sub.appendingPathComponent("deep.txt"))

        let names = try fs.contentsOfDirectory(at: root)
            .map(\.lastPathComponent)
            .sorted()
        #expect(names == ["a.txt", "b.txt", "sub"])
    }

    @Test("列不存在的目录报 notFound", arguments: Implementation.allCases)
    func contentsOfMissingDirectoryThrows(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let missing = root.appendingPathComponent("nope", isDirectory: true)
        #expect(throws: FileSystemError.notFound(missing)) {
            _ = try fs.contentsOfDirectory(at: missing)
        }
    }

    // MARK: - 删除

    @Test("删除目录会连同后代一起删", arguments: Implementation.allCases)
    func removeDirectoryRemovesDescendants(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let dir = root.appendingPathComponent("worktree", isDirectory: true)
        let file = dir.appendingPathComponent("nested.txt")
        try fs.createDirectory(at: dir)
        try fs.write(Data("x".utf8), to: file)

        try fs.removeItem(at: dir)

        #expect(fs.exists(at: dir) == false)
        #expect(fs.exists(at: file) == false)
    }

    @Test("删除不存在的项报 notFound", arguments: Implementation.allCases)
    func removeMissingThrowsNotFound(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let missing = root.appendingPathComponent("ghost")
        #expect(throws: FileSystemError.notFound(missing)) {
            try fs.removeItem(at: missing)
        }
    }

    // MARK: - 原子替换(数据层的地基)

    @Test("替换到不存在的目标", arguments: Implementation.allCases)
    func replaceIntoEmptySlot(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let temp = root.appendingPathComponent("state.json.tmp")
        let final = root.appendingPathComponent("state.json")
        try fs.write(Data("new".utf8), to: temp)

        try fs.replaceItem(at: final, withItemAt: temp)

        #expect(try fs.read(at: final) == Data("new".utf8))
        #expect(fs.exists(at: temp) == false, "临时文件必须消失,否则会残留垃圾")
    }

    @Test("替换会覆盖已存在的目标", arguments: Implementation.allCases)
    func replaceOverwritesExisting(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let temp = root.appendingPathComponent("state.json.tmp")
        let final = root.appendingPathComponent("state.json")
        try fs.write(Data("old".utf8), to: final)
        try fs.write(Data("new".utf8), to: temp)

        // 这一条是 P1-05 原子写的核心:目标已存在时必须直接覆盖,
        // 不能要求调用方先删除 —— 「先删再写」中间有个窗口是没有文件的。
        try fs.replaceItem(at: final, withItemAt: temp)

        #expect(try fs.read(at: final) == Data("new".utf8))
        #expect(fs.exists(at: temp) == false)
    }

    @Test("源不存在时替换失败", arguments: Implementation.allCases)
    func replaceWithMissingSourceFails(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let missing = root.appendingPathComponent("nope.tmp")
        let final = root.appendingPathComponent("state.json")
        try fs.write(Data("old".utf8), to: final)

        #expect(throws: FileSystemError.notFound(missing)) {
            try fs.replaceItem(at: final, withItemAt: missing)
        }
        // 失败后原文件必须原封不动 —— 否则一次失败的写入就毁了数据。
        #expect(try fs.read(at: final) == Data("old".utf8))
    }

    // MARK: - 边缘:此前真假分歧,现已对齐
    //
    // 这四条都不是想出来的,是拿探针逐个对比真假实现跑出来的。
    // 契约测试的价值全在覆盖面上 —— 没写进来的边缘,分歧就是不可见的。

    @Test("往目录路径写文件报 isDirectory", arguments: Implementation.allCases)
    func writeOntoDirectory(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let dir = root.appendingPathComponent("jobs", isDirectory: true)
        try fs.createDirectory(at: dir)

        #expect(throws: FileSystemError.isDirectory(dir)) {
            try fs.write(Data("x".utf8), to: dir)
        }
    }

    @Test("中间层是文件时建目录报 notADirectory", arguments: Implementation.allCases)
    func createDirectoryThroughFile(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        try fs.write(Data("f".utf8), to: root.appendingPathComponent("blocker"))
        let blocked = root.appendingPathComponent("blocker/deep", isDirectory: true)

        // 携带的是**请求的**路径,不是那个挡路的中间层 ——
        // mkdir 系统调用不会告诉你是哪一层挡住的,契约跟着它走。
        #expect(throws: FileSystemError.notADirectory(blocked)) {
            try fs.createDirectory(at: blocked)
        }
    }

    @Test("replaceItem 拒绝目录作为源", arguments: Implementation.allCases)
    func replaceRejectsDirectorySource(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let source = root.appendingPathComponent("src", isDirectory: true)
        try fs.createDirectory(at: source)
        try fs.write(Data("c".utf8), to: source.appendingPathComponent("child.txt"))

        #expect(throws: FileSystemError.isDirectory(source)) {
            try fs.replaceItem(at: root.appendingPathComponent("dst"), withItemAt: source)
        }
        // 拒绝必须发生在改动任何状态之前 —— 半途失败会留下孤儿节点。
        #expect(fs.exists(at: source.appendingPathComponent("child.txt")))
    }

    @Test("replaceItem 拒绝目录作为目标", arguments: Implementation.allCases)
    func replaceRejectsDirectoryDestination(_ implementation: Implementation) throws {
        let (fs, root, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        let source = root.appendingPathComponent("state.json.tmp")
        let destination = root.appendingPathComponent("occupied", isDirectory: true)
        try fs.write(Data("new".utf8), to: source)
        try fs.createDirectory(at: destination)

        #expect(throws: FileSystemError.isDirectory(destination)) {
            try fs.replaceItem(at: destination, withItemAt: source)
        }
        #expect(try fs.read(at: source) == Data("new".utf8))
    }
}


/// withExclusiveLock 的契约用例(独立 Suite,避免塞进已经很长的主套件)。
@Suite("withExclusiveLock 契约")
struct WithExclusiveLockContractTests {

    enum Implementation: String, CaseIterable, Sendable {
        case inMemory
        case system
    }

    private func makeSubject(_ implementation: Implementation) throws
        -> (fileSystem: any FileSystem, target: URL, cleanup: @Sendable () -> Void)
    {
        switch implementation {
        case .inMemory:
            let fileSystem = InMemoryFileSystem()
            let dir = URL(fileURLWithPath: "/pilot-test-\(UUID().uuidString)")
            try fileSystem.createDirectory(at: dir)   // 锁文件与目标都需要父目录
            let target = dir.appendingPathComponent("state.json")
            return (fileSystem, target, {})
        case .system:
            let fileSystem = SystemFileSystem()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("pilot-lock-\(UUID().uuidString)", isDirectory: true)
            try fileSystem.createDirectory(at: dir)
            let target = dir.appendingPathComponent("state.json")
            return (fileSystem, target, { try? FileManager.default.removeItem(at: dir) })
        }
    }

    @Test("互斥:body 的并发重叠数最大为 1", arguments: Implementation.allCases)
    func serializesConcurrentBodies(_ implementation: Implementation) throws {
        let (fileSystem, target, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        // 不能用「共享计数器自增」证明互斥:计数器自己持有 NSLock,
        // 把 withExclusiveLock 换成直接调 body,计数照样不丢 ——
        // 断言被计数器自己的锁掩蔽了(第二轮审查 P2)。
        // 改为观测**同时进入 body 的数量**:body 保持一段可重叠窗口,
        // 无锁实现必然叠出并发,互斥实现必须 max == 1。
        final class ConcurrencyProbe: @unchecked Sendable {
            private let lock = NSLock()
            private var current = 0
            private var maxConcurrent = 0
            private var executed = 0
            private var failures = 0
            func enter() {
                lock.lock(); current += 1
                maxConcurrent = max(maxConcurrent, current)
                lock.unlock()
            }
            func exit() {
                lock.lock(); current -= 1; lock.unlock()
            }
            func recordExecuted() {
                lock.lock(); executed += 1; lock.unlock()
            }
            func recordFailure() {
                lock.lock(); failures += 1; lock.unlock()
            }
            func stats() -> (maxConcurrent: Int, executed: Int, failures: Int) {
                lock.lock(); defer { lock.unlock() }
                return (maxConcurrent, executed, failures)
            }
        }

        let probe = ConcurrencyProbe()
        let iterations = 32
        let group = DispatchGroup()
        // enter 必须在派生侧:放在线程闭包里,主线程可能赶在任何一个
        // enter 之前 wait —— 空 group 立即返回,窗口还没跑完。
        let threads = (0..<8).map { _ in
            group.enter()
            return Thread {
                defer { group.leave() }
                for _ in 0..<iterations {
                    // 不能 try? —— 竞争时抛错被吞掉,body 少执行,
                    // max == 1 照样成立,阻塞语义的失效就看不见了(第二轮审查)。
                    do {
                        try fileSystem.withExclusiveLock(at: target) {
                            probe.enter()
                            // 可重叠窗口:1ms 足够让无锁实现叠出并发。
                            Thread.sleep(forTimeInterval: 0.001)
                            probe.exit()
                        }
                        probe.recordExecuted()
                    } catch {
                        probe.recordFailure()
                    }
                }
            }
        }
        threads.forEach { $0.start() }
        group.wait()

        let stats = probe.stats()
        #expect(stats.executed == 8 * iterations,
                "有调用被丢弃:执行 \(stats.executed)/\(8 * iterations),失败 \(stats.failures) —— 锁在竞争时拒绝而不是等待")
        #expect(stats.failures == 0,
                "锁在竞争时抛错 \(stats.failures) 次 —— 阻塞语义失效(LOCK_NB?)")
        #expect(stats.maxConcurrent == 1,
                "body 出现了 \(stats.maxConcurrent) 层并发重叠 —— 锁没有互斥")
    }

    @Test("不同目标的锁互不阻塞", arguments: Implementation.allCases)
    func differentTargetsDoNotBlock(_ implementation: Implementation) throws {
        // 生产实现按目标路径各一把锁:两个不同文件的保存可以并发。
        // 替身若整个实例一把锁,会把跨文件并发强行串行化,
        // 掩盖 P1-12 多命令并发测试里的竞态(第二轮审查 P2)。
        let (fileSystem, target, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        let fileA = target
        let fileB = target.deletingLastPathComponent().appendingPathComponent("other.json")

        let holdingA = DispatchSemaphore(value: 0)
        let enteredB = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        let group = DispatchGroup()

        group.enter()
        let threadA = Thread {
            defer { group.leave() }
            _ = try? fileSystem.withExclusiveLock(at: fileA) {
                holdingA.signal()                                // A 已持锁
                _ = releaseA.wait(timeout: .distantFuture)       // 等 B 进来再放
            }
        }
        threadA.start()
        _ = holdingA.wait(timeout: .distantFuture)

        group.enter()
        let threadB = Thread {
            defer { group.leave() }
            _ = try? fileSystem.withExclusiveLock(at: fileB) {
                enteredB.signal()                                // B 没被 A 挡住
            }
        }
        threadB.start()

        // A 持锁期间,B 必须能在时限内进入自己的锁。
        let got = enteredB.wait(timeout: .now() + 5)
        releaseA.signal()
        group.wait()

        #expect(got == .success, "B 被无关文件的锁阻塞了 —— 替身把所有文件串行化")
    }

    @Test("锁文件是稳定旁路,不随目标被替换", arguments: Implementation.allCases)
    func lockSurvivesTargetReplacement(_ implementation: Implementation) throws {
        let (fileSystem, target, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        // 在锁内替换目标文件(正是 ProjectStore 的事务形态),锁必须仍然有效 ——
        // flock 建立在 inode 上,锁被 rename 的文件会让后续锁请求指向新 inode。
        try fileSystem.write(Data("v1".utf8), to: target)
        var reentered = false
        try fileSystem.withExclusiveLock(at: target) {
            let temp = target.deletingLastPathComponent()
                .appendingPathComponent(".swap-\(UUID().uuidString)")
            try fileSystem.write(Data("v2".utf8), to: temp)
            try fileSystem.replaceItem(at: target, withItemAt: temp)
            reentered = true
        }
        #expect(reentered)
        #expect(try fileSystem.read(at: target) == Data("v2".utf8))
    }
}
