import Foundation
import Testing
@testable import PilotInfrastructure
@testable import PilotTestSupport

/// 故障注入的测试。
///
/// 这些场景真实磁盘上造不出来 —— 你没法为了测一条错误分支
/// 真的把 CI 机器的盘写满。P1-12 要求覆盖「写到一半崩溃、磁盘满、
/// 权限拒绝、文件被替换」,能力必须先在这里验明。
@Suite("InMemoryFileSystem 故障注入")
struct InMemoryFileSystemFaultTests {

    private func makeSubject() throws -> (InMemoryFileSystem, URL) {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/data")
        try fs.createDirectory(at: root)
        return (fs, root)
    }

    @Test("磁盘满")
    func diskFull() throws {
        let (fs, root) = try makeSubject()
        let file = root.appendingPathComponent("state.json")

        fs.failNext(.write, with: .diskFull)

        #expect(throws: FileSystemError.diskFull(file)) {
            try fs.write(Data("x".utf8), to: file)
        }
        #expect(fs.exists(at: file) == false)
    }

    @Test("权限拒绝")
    func permissionDenied() throws {
        let (fs, root) = try makeSubject()
        let file = root.appendingPathComponent("state.json")
        try fs.write(Data("ok".utf8), to: file)

        fs.failNext(.read, with: .permissionDenied)

        #expect(throws: FileSystemError.permissionDenied(file)) {
            _ = try fs.read(at: file)
        }
    }

    @Test("写到一半崩溃:文件存在但只有半截")
    func partialWrite() throws {
        let (fs, root) = try makeSubject()
        let file = root.appendingPathComponent("state.json")
        let payload = Data("{\"revision\":42,\"tasks\":[]}".utf8)

        fs.failNext(.write, with: .partialWrite(bytes: 8))

        #expect(throws: FileSystemError.diskFull(file)) {
            try fs.write(payload, to: file)
        }

        // 崩溃恢复最难的不是文件没了,而是文件在那儿、但只有半截 ——
        // 半截 JSON 解析必然失败,而 v0.2 §3 规则 10 要求
        // 「损坏文件不能静默当作空数据」。这条能力先在这里立住。
        let leftover = try #require(fs.storedContents(at: file))
        #expect(leftover == payload.prefix(8))
        #expect(leftover.count < payload.count)
    }

    @Test("文件在操作中途被替换")
    func fileReplacedMidOperation() throws {
        let (fs, root) = try makeSubject()
        let file = root.appendingPathComponent("state.json")
        try fs.write(Data("original".utf8), to: file)

        // 在下一次 read 真正取数据之前,把文件换掉 ——
        // 模拟「另一个进程在你读之间改了文件」。
        let swapped = Data("swapped-by-someone-else".utf8)
        fs.onOperation { operation, url in
            guard operation == .read, url == file else { return }
            fs.onOperation(nil)              // 只换一次,避免无限递归
            try? fs.write(swapped, to: file)
        }

        #expect(try fs.read(at: file) == swapped)
    }

    @Test("失败指定次数后恢复")
    func failsExactlyNTimesThenRecovers() throws {
        let (fs, root) = try makeSubject()
        let file = root.appendingPathComponent("state.json")

        fs.failNext(.write, with: .diskFull, times: 2)

        #expect(throws: (any Error).self) { try fs.write(Data("1".utf8), to: file) }
        #expect(throws: (any Error).self) { try fs.write(Data("2".utf8), to: file) }
        // 第三次必须成功 —— 重试策略(P7-06)的测试要靠这个语义。
        try fs.write(Data("3".utf8), to: file)

        #expect(try fs.read(at: file) == Data("3".utf8))
    }

    @Test("故障可绑定到具体路径")
    func faultTargetsSpecificPath() throws {
        let (fs, root) = try makeSubject()
        let doomed = root.appendingPathComponent("doomed.json")
        let safe = root.appendingPathComponent("safe.json")

        fs.failNext(.write, at: doomed, with: .diskFull)

        #expect(throws: (any Error).self) { try fs.write(Data("x".utf8), to: doomed) }
        try fs.write(Data("y".utf8), to: safe)   // 不受影响

        #expect(try fs.read(at: safe) == Data("y".utf8))
    }

    @Test("故障只作用于指定操作")
    func faultTargetsSpecificOperation() throws {
        let (fs, root) = try makeSubject()
        let file = root.appendingPathComponent("state.json")
        try fs.write(Data("ok".utf8), to: file)

        fs.failNext(.removeItem, with: .permissionDenied)

        _ = try fs.read(at: file)            // read 不受影响
        #expect(throws: (any Error).self) { try fs.removeItem(at: file) }
    }

    @Test("clearFaults 清除未触发的规则")
    func clearFaults() throws {
        let (fs, root) = try makeSubject()
        let file = root.appendingPathComponent("state.json")

        fs.failNext(.write, with: .diskFull, times: 5)
        fs.clearFaults()

        try fs.write(Data("x".utf8), to: file)
        #expect(fs.exists(at: file))
    }
}
