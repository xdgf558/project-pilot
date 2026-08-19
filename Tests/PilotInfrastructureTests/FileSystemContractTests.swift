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
