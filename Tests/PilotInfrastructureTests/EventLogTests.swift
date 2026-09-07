import Foundation
import Testing
import PilotCore
import PilotInfrastructure
import PilotTestSupport

/// EventLog 的测试。**每个用例对 InMemory 与 System 两种实现各跑一遍** ——
/// 与 ProjectStore / FileSystem 契约测试同一个理由:只跟假实现一致,
/// 证明不了任何关于真实磁盘的事。
@Suite("EventLog")
struct EventLogTests {

    enum Implementation: String, CaseIterable, Sendable {
        case inMemory
        case system
    }

    private func makeSubject(_ implementation: Implementation) throws
        -> (fileSystem: any FileSystem, log: EventLog, url: URL, cleanup: @Sendable () -> Void)
    {
        switch implementation {
        case .inMemory:
            let fileSystem = InMemoryFileSystem()
            let root = URL(fileURLWithPath: "/pilot-events-\(UUID().uuidString)")
            try fileSystem.createDirectory(at: root)
            let url = root.appendingPathComponent("events.ndjson")
            return (fileSystem, EventLog(fileSystem: fileSystem), url, {})
        case .system:
            let fileSystem = SystemFileSystem()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pilot-events-\(UUID().uuidString)", isDirectory: true)
            try fileSystem.createDirectory(at: root)
            let url = root.appendingPathComponent("events.ndjson")
            return (fileSystem, EventLog(fileSystem: fileSystem), url, {
                try? FileManager.default.removeItem(at: root)
            })
        }
    }

    private func makeEvent(sequence: Int64, id: UInt32 = 1) -> Event {
        Event(
            id: UUID(sequenceNumber: id),
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: 1000 + Double(sequence)),
            projectId: UUID(sequenceNumber: 100),
            entityType: OpenEnum(.task),
            entityId: UUID(sequenceNumber: 12),
            eventType: EventType(rawValue: "taskStageChanged"),
            actor: OpenEnum(.system),
            requestId: "req-\(sequence)",
            reason: "依赖已完成",
            payload: .object(["n": .integer(sequence)])
        )
    }

    // MARK: - 往返与空日志

    @Test("追加后读回完全相等", arguments: Implementation.allCases)
    func roundTrips(_ implementation: Implementation) throws {
        let (_, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        #expect(try log.load(from: url) == [])

        let first = makeEvent(sequence: 1, id: 1)
        let second = makeEvent(sequence: 2, id: 2)
        try log.append([first], to: url, after: 0)
        try log.append([second], to: url, after: 1)

        #expect(try log.load(from: url) == [first, second])
    }

    @Test("文件不存在时 load 返回空数组,不抛错", arguments: Implementation.allCases)
    func missingFileIsEmpty(_ implementation: Implementation) throws {
        let (_, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        #expect(try log.load(from: url) == [])
        #expect(try log.events(from: url, after: 0) == [])
    }

    @Test("空文件当作空日志", arguments: Implementation.allCases)
    func emptyFileIsEmpty(_ implementation: Implementation) throws {
        let (fileSystem, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        try fileSystem.write(Data(), to: url)
        #expect(try log.load(from: url) == [])
    }

    @Test("一次追加多条连续事件", arguments: Implementation.allCases)
    func appendsBatch(_ implementation: Implementation) throws {
        let (_, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        let batch = [makeEvent(sequence: 1, id: 1), makeEvent(sequence: 2, id: 2),
                     makeEvent(sequence: 3, id: 3)]
        try log.append(batch, to: url, after: 0)
        #expect(try log.load(from: url) == batch)
    }

    @Test("首次追加:父目录完全不存在也能创建", arguments: Implementation.allCases)
    func firstAppendCreatesMissingDirectories(_ implementation: Implementation) throws {
        let log: EventLog
        let url: URL
        let cleanup: @Sendable () -> Void
        switch implementation {
        case .inMemory:
            log = EventLog(fileSystem: InMemoryFileSystem())
            url = URL(fileURLWithPath: "/pilot-fresh-\(UUID().uuidString)/a/b/events.ndjson")
            cleanup = {}
        case .system:
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pilot-fresh-\(UUID().uuidString)", isDirectory: true)
            log = EventLog(fileSystem: SystemFileSystem())
            url = root.appendingPathComponent("a/b/events.ndjson")
            cleanup = { try? FileManager.default.removeItem(at: root) }
        }
        defer { cleanup() }

        try log.append([makeEvent(sequence: 1)], to: url, after: 0)
        #expect(try log.load(from: url).map(\.sequence) == [1])
        try log.append([makeEvent(sequence: 2, id: 2)], to: url, after: 1)
        #expect(try log.load(from: url).map(\.sequence) == [1, 2])
    }

    // MARK: - 游标 / 重放起点

    @Test("events(after:) 只返回游标之后的事件", arguments: Implementation.allCases)
    func readsAfterCursor(_ implementation: Implementation) throws {
        let (_, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        try log.append(
            [makeEvent(sequence: 1, id: 1), makeEvent(sequence: 2, id: 2),
             makeEvent(sequence: 3, id: 3)],
            to: url, after: 0)

        #expect(try log.events(from: url, after: 0).map(\.sequence) == [1, 2, 3])
        #expect(try log.events(from: url, after: 2).map(\.sequence) == [3])
        #expect(try log.events(from: url, after: 3) == [])
    }

    @Test("快照 lastEventSequence 是重放起点", arguments: Implementation.allCases)
    func snapshotCursorIsReplayStart(_ implementation: Implementation) throws {
        let (_, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        try log.append(
            [makeEvent(sequence: 1, id: 1), makeEvent(sequence: 2, id: 2),
             makeEvent(sequence: 3, id: 3)],
            to: url, after: 0)

        let snapshot = DataEnvelope(
            revision: Revision(1), lastEventSequence: 2,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            checksum: Checksum(value: 0),
            payload: ["ok": true])

        #expect(try log.eventsToReplay(from: snapshot, log: url).map(\.sequence) == [3])
    }

    @Test("游标超过日志末尾报 cursorAheadOfLog", arguments: Implementation.allCases)
    func cursorAheadOfLogIsError(_ implementation: Implementation) throws {
        let (_, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        try log.append([makeEvent(sequence: 1)], to: url, after: 0)

        #expect(throws: EventLogError.cursorAheadOfLog(url: url, cursor: 5, lastInLog: 1)) {
            _ = try log.events(from: url, after: 5)
        }
    }

    @Test("负游标报 invalidCursor,与 cursorAheadOfLog 正交", arguments: Implementation.allCases)
    func negativeCursorIsInvalid(_ implementation: Implementation) throws {
        let (_, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        #expect(throws: EventLogError.invalidCursor(url: url, sequence: -1)) {
            _ = try log.events(from: url, after: -1)
        }
    }

    // MARK: - 序号协议

    @Test("基于过期游标的追加被拒,盘上事件不被覆盖", arguments: Implementation.allCases)
    func staleAppenderCannotOverwrite(_ implementation: Implementation) throws {
        let (_, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        try log.append([makeEvent(sequence: 1, id: 1)], to: url, after: 0)
        try log.append([makeEvent(sequence: 2, id: 2)], to: url, after: 1)

        #expect(throws: EventLogError.sequenceConflict(url: url, onDiskLast: 2, expectedLast: 1)) {
            try log.append([makeEvent(sequence: 2, id: 99)], to: url, after: 1)
        }
        #expect(try log.load(from: url).map(\.id) == [UUID(sequenceNumber: 1), UUID(sequenceNumber: 2)])
    }

    @Test("追加序号没有从 expectedLast 前进一格被拒", arguments: Implementation.allCases)
    func rejectsSequenceNotAdvanced(_ implementation: Implementation) throws {
        let (_, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        #expect(throws: EventLogError.sequenceNotAdvanced(url: url, expected: 1, actual: 5)) {
            try log.append([makeEvent(sequence: 5)], to: url, after: 0)
        }
        #expect(try log.load(from: url) == [])
    }

    @Test("批次内部序号不连续被拒", arguments: Implementation.allCases)
    func rejectsGapInsideBatch(_ implementation: Implementation) throws {
        let (_, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        #expect(throws: EventLogError.sequenceNotAdvanced(url: url, expected: 3, actual: 5)) {
            try log.append(
                [makeEvent(sequence: 1, id: 1), makeEvent(sequence: 2, id: 2),
                 makeEvent(sequence: 5, id: 5)],
                to: url, after: 0)
        }
        #expect(try log.load(from: url) == [])
    }

    @Test("空追加被拒", arguments: Implementation.allCases)
    func rejectsEmptyAppend(_ implementation: Implementation) throws {
        let (_, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        #expect(throws: EventLogError.emptyAppend(url: url)) {
            try log.append([], to: url, after: 0)
        }
    }

    @Test("冲突后重读再追加成功", arguments: Implementation.allCases)
    func conflictThenReloadThenSuccess(_ implementation: Implementation) throws {
        let (_, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        try log.append([makeEvent(sequence: 1, id: 1)], to: url, after: 0)

        let a = try log.load(from: url)
        _ = try log.load(from: url)
        try log.append([makeEvent(sequence: 2, id: 2)], to: url, after: a.last?.sequence ?? 0)

        #expect(throws: EventLogError.sequenceConflict(url: url, onDiskLast: 2, expectedLast: 1)) {
            try log.append([makeEvent(sequence: 2, id: 99)], to: url, after: 1)
        }

        let latest = try log.load(from: url)
        try log.append([makeEvent(sequence: 3, id: 3)], to: url, after: latest.last?.sequence ?? 0)
        #expect(try log.load(from: url).map(\.sequence) == [1, 2, 3])
    }

    // MARK: - 损坏

    @Test("不是合法 JSON 的行报损坏,不当空日志", arguments: Implementation.allCases)
    func rejectsGarbageLine(_ implementation: Implementation) throws {
        let (fileSystem, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        try log.append([makeEvent(sequence: 1)], to: url, after: 0)
        var raw = try fileSystem.read(at: url)
        raw.append(contentsOf: Data("这不是 JSON\n".utf8))
        try fileSystem.write(raw, to: url)

        try assertCorrupted(url: url, line: 2) { _ = try log.load(from: url) }
    }

    @Test("中间空行报损坏", arguments: Implementation.allCases)
    func rejectsBlankLineInMiddle(_ implementation: Implementation) throws {
        let (fileSystem, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        let first = try CanonicalJSON.makeEventEncoder().encode(makeEvent(sequence: 1, id: 1))
        let second = try CanonicalJSON.makeEventEncoder().encode(makeEvent(sequence: 2, id: 2))
        var data = first
        data.append(contentsOf: Data("\n\n".utf8))
        data.append(second)
        data.append(contentsOf: Data("\n".utf8))
        try fileSystem.write(data, to: url)

        try assertCorrupted(url: url, line: 2) { _ = try log.load(from: url) }
    }

    @Test("日志里序号出现空洞报损坏", arguments: Implementation.allCases)
    func rejectsGapOnDisk(_ implementation: Implementation) throws {
        let (fileSystem, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        try log.append(
            [makeEvent(sequence: 1, id: 1), makeEvent(sequence: 2, id: 2)],
            to: url, after: 0)
        // NDJSON 不是单个 JSON 对象,只能改第一行。把序号改成 9,
        // 首条就不再是 1,整份日志按损坏拒绝。
        let raw = try fileSystem.read(at: url)
        let text = try #require(String(data: raw, encoding: .utf8))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let first = try JSONMutation.replacing(Data(lines[0].utf8), key: "sequence", with: 9)
        let mutated = String(data: first, encoding: .utf8)! + "\n" + lines.dropFirst().joined(separator: "\n")
        try fileSystem.write(Data(mutated.utf8), to: url)

        try assertCorrupted(url: url, line: 1) { _ = try log.load(from: url) }
    }

    @Test("字段类型不对也报损坏,与 sequenceConflict 正交", arguments: Implementation.allCases)
    func typeMismatchIsCorruptedNotConflict(_ implementation: Implementation) throws {
        let (fileSystem, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        try log.append([makeEvent(sequence: 1)], to: url, after: 0)
        var raw = try fileSystem.read(at: url)
        raw = try JSONMutation.replacing(raw, key: "timestamp", with: "刚才")
        try fileSystem.write(raw, to: url)

        do {
            _ = try log.load(from: url)
            Issue.record("应当抛 .corrupted")
        } catch let error as EventLogError {
            guard case .corrupted(let thrownURL, let line, _) = error else {
                Issue.record("抛了别的 case:\(error)")
                return
            }
            #expect(thrownURL == url)
            #expect(line == 1)
        }

        // 对照:同一套 API 在完好日志上会走 sequenceConflict,不会把所有失败都收成 corrupted。
        let (fileSystem2, log2, url2, cleanup2) = try makeSubject(implementation)
        defer { cleanup2() }
        try log2.append([makeEvent(sequence: 1, id: 2)], to: url2, after: 0)
        #expect(throws: EventLogError.sequenceConflict(url: url2, onDiskLast: 1, expectedLast: 0)) {
            try log2.append([makeEvent(sequence: 1, id: 3)], to: url2, after: 0)
        }
        _ = fileSystem2
    }

    @Test("损坏文件拒绝被追加覆盖", arguments: Implementation.allCases)
    func refusesToOverwriteCorruptedLog(_ implementation: Implementation) throws {
        let (fileSystem, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        try fileSystem.write(Data("这不是 JSON\n".utf8), to: url)
        try assertCorrupted(url: url, line: 1) {
            try log.append([makeEvent(sequence: 1)], to: url, after: 0)
        }
        #expect(try fileSystem.read(at: url) == Data("这不是 JSON\n".utf8))
    }

    @Test("退役的事件类型经日志仍然读得出来", arguments: Implementation.allCases)
    func retiredEventTypeSurvivesLog(_ implementation: Implementation) throws {
        let (fileSystem, log, url, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        try log.append([makeEvent(sequence: 1)], to: url, after: 0)
        var raw = try fileSystem.read(at: url)
        raw = try JSONMutation.replacing(raw, key: "eventType", with: "someRetiredTypeFrom2024")
        try fileSystem.write(raw, to: url)

        let loaded = try log.load(from: url)
        #expect(loaded.count == 1)
        #expect(loaded[0].eventType.rawValue == "someRetiredTypeFrom2024")
    }

    private func assertCorrupted(url: URL, line: Int, _ body: () throws -> Void) throws {
        do {
            try body()
            Issue.record("应当抛 .corrupted")
        } catch let error as EventLogError {
            guard case .corrupted(let thrownURL, let thrownLine, _) = error else {
                Issue.record("抛了别的 case:\(error)")
                return
            }
            #expect(thrownURL == url)
            #expect(thrownLine == line)
        }
    }

    // MARK: - 并发

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<Void, any Error>?
        func set(_ value: Result<Void, any Error>) {
            lock.lock(); defer { lock.unlock() }
            outcome = value
        }
        func get() -> Result<Void, any Error>? {
            lock.lock(); defer { lock.unlock() }
            return outcome
        }
    }

    @Test("并发双写:恰好一个成功,不可能都成功", arguments: Implementation.allCases)
    func concurrentAppendersExactlyOneWins(_ implementation: Implementation) throws {
        for _ in 0..<20 {
            let (_, log, url, cleanup) = try makeSubject(implementation)
            defer { cleanup() }
            try log.append([makeEvent(sequence: 1, id: 1)], to: url, after: 0)

            let startGate = DispatchSemaphore(value: 0)
            let doneGate = DispatchSemaphore(value: 0)
            let boxA = OutcomeBox()
            let boxB = OutcomeBox()

            @Sendable func writer(_ box: OutcomeBox, _ id: UInt32) {
                startGate.wait()
                do {
                    try log.append([makeEvent(sequence: 2, id: id)], to: url, after: 1)
                    box.set(.success(()))
                } catch {
                    box.set(.failure(error))
                }
                doneGate.signal()
            }

            let threadA = Thread { writer(boxA, 10) }
            let threadB = Thread { writer(boxB, 20) }
            threadA.start(); threadB.start()
            startGate.signal(); startGate.signal()
            doneGate.wait(); doneGate.wait()

            let outcomes = [boxA.get()!, boxB.get()!]
            let successes = outcomes.filter { if case .success = $0 { return true }; return false }
            let conflicts = outcomes.filter {
                if case .failure(EventLogError.sequenceConflict) = $0 { return true }; return false
            }
            #expect(successes.count == 1, "两追加同时成功 = 丢事件或序号分叉")
            #expect(conflicts.count == 1)

            let onDisk = try log.load(from: url)
            #expect(onDisk.map(\.sequence) == [1, 2])
        }
    }

    // MARK: - 原子写(故障注入,仅内存实现)

    @Test("写到一半崩溃:旧日志完好,临时文件不留垃圾")
    func partialWriteKeepsOldLogIntact() throws {
        let (fileSystem, log, url, cleanup) = try makeSubject(.inMemory)
        defer { cleanup() }
        let memory = try #require(fileSystem as? InMemoryFileSystem)
        try log.append([makeEvent(sequence: 1, id: 1)], to: url, after: 0)

        memory.failNext(.write, with: .partialWrite(bytes: 40))
        do {
            try log.append([makeEvent(sequence: 2, id: 2)], to: url, after: 1)
            Issue.record("应当抛文件系统错误")
        } catch let error as FileSystemError {
            #expect(error != .notFound(url))
        }

        #expect(try log.load(from: url).map(\.sequence) == [1])
        #expect(memory.allPaths.filter { $0.contains(".tmp-") } == [])

        memory.clearFaults()
        try log.append([makeEvent(sequence: 2, id: 2)], to: url, after: 1)
        #expect(try log.load(from: url).map(\.sequence) == [1, 2])
    }
}
