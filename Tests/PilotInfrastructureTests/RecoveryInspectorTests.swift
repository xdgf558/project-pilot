import Foundation
import Testing
import PilotCore
import PilotInfrastructure
import PilotTestSupport

@Suite("RecoveryInspector")
struct RecoveryInspectorTests {

    enum Implementation: String, CaseIterable, Sendable {
        case inMemory
        case system
    }

    private func makeSubject(_ implementation: Implementation) throws
        -> (
            fileSystem: any FileSystem,
            inspector: RecoveryInspector,
            store: ProjectStore<JSONValue>,
            log: EventLog,
            snapshotURL: URL,
            eventsURL: URL,
            cleanup: @Sendable () -> Void
        )
    {
        switch implementation {
        case .inMemory:
            let fileSystem = InMemoryFileSystem()
            let root = URL(fileURLWithPath: "/pilot-recover-\(UUID().uuidString)")
            try fileSystem.createDirectory(at: root)
            let snapshotURL = root.appendingPathComponent("state.json")
            let eventsURL = root.appendingPathComponent("events.ndjson")
            return (
                fileSystem,
                RecoveryInspector(fileSystem: fileSystem),
                ProjectStore(fileSystem: fileSystem),
                EventLog(fileSystem: fileSystem),
                snapshotURL, eventsURL, {}
            )
        case .system:
            let fileSystem = SystemFileSystem()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pilot-recover-\(UUID().uuidString)", isDirectory: true)
            try fileSystem.createDirectory(at: root)
            let snapshotURL = root.appendingPathComponent("state.json")
            let eventsURL = root.appendingPathComponent("events.ndjson")
            return (
                fileSystem,
                RecoveryInspector(fileSystem: fileSystem),
                ProjectStore(fileSystem: fileSystem),
                EventLog(fileSystem: fileSystem),
                snapshotURL, eventsURL,
                { try? FileManager.default.removeItem(at: root) }
            )
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
            requestId: "req-\(sequence)")
    }

    // MARK: - 完好

    @Test("完好的快照和日志:可读时间戳、关系一致", arguments: Implementation.allCases)
    func healthyPairIsConsistent(_ implementation: Implementation) throws {
        let (_, inspector, store, log, snapshotURL, eventsURL, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        try store.save(
            DataEnvelope(
                revision: Revision(1), lastEventSequence: 2,
                createdAt: Date(timeIntervalSince1970: 1_000),
                updatedAt: Date(timeIntervalSince1970: 2_000),
                checksum: Checksum(value: 0),
                payload: .object(["name": .string("任务表")])),
            to: snapshotURL, expecting: .initial)
        try log.append([makeEvent(sequence: 1, id: 1), makeEvent(sequence: 2, id: 2)],
                       to: eventsURL, after: 0)

        let report = inspector.inspect(snapshot: snapshotURL, events: eventsURL)
        guard case .healthy(let snapshot) = report.snapshot else {
            Issue.record("快照应当完好:\(report.snapshot)")
            return
        }
        #expect(snapshot.revision == Revision(1))
        #expect(snapshot.lastEventSequence == 2)
        #expect(snapshot.createdAt == "1970-01-01T00:16:40.000Z")
        #expect(snapshot.updatedAt == "1970-01-01T00:33:20.000Z")

        guard case .healthy(let events) = report.events else {
            Issue.record("日志应当完好:\(report.events)")
            return
        }
        #expect(events.count == 2)
        #expect(events.lastSequence == 2)
        #expect(events.firstTimestamp == "1970-01-01T00:16:41.000Z")
        #expect(events.lastTimestamp == "1970-01-01T00:16:42.000Z")
        #expect(report.relation == .consistent)

        let text = report.formattedDescription()
        #expect(text.contains("1970-01-01T00:16:40.000Z"))
        #expect(text.contains("一致"))
    }

    @Test("文件都不存在:missing,不是损坏", arguments: Implementation.allCases)
    func missingIsNotCorrupted(_ implementation: Implementation) throws {
        let (_, inspector, _, _, snapshotURL, eventsURL, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        let report = inspector.inspect(snapshot: snapshotURL, events: eventsURL)
        #expect(report.snapshot == .missing(snapshotURL))
        #expect(report.events == .missing(eventsURL))
        #expect(report.relation == .notApplicable)
    }

    // MARK: - 错误定位

    @Test("损坏的快照定位到文件和原因,不当空", arguments: Implementation.allCases)
    func locatesCorruptedSnapshot(_ implementation: Implementation) throws {
        let (fileSystem, inspector, _, _, snapshotURL, eventsURL, cleanup)
            = try makeSubject(implementation)
        defer { cleanup() }
        try fileSystem.write(Data("这不是 JSON".utf8), to: snapshotURL)

        let report = inspector.inspect(snapshot: snapshotURL, events: eventsURL)
        guard case .corrupted(let url, let reason) = report.snapshot else {
            Issue.record("应当是损坏:\(report.snapshot)")
            return
        }
        #expect(url == snapshotURL)
        #expect(reason.isEmpty == false)
        #expect(report.formattedDescription().contains(snapshotURL.path))
        #expect(report.relation == .notApplicable)
    }

    @Test("损坏的日志定位到行号,与快照损坏正交", arguments: Implementation.allCases)
    func locatesCorruptedEventLine(_ implementation: Implementation) throws {
        let (fileSystem, inspector, store, log, snapshotURL, eventsURL, cleanup)
            = try makeSubject(implementation)
        defer { cleanup() }
        try store.save(
            DataEnvelope(
                revision: Revision(1), lastEventSequence: 1,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1),
                checksum: Checksum(value: 0),
                payload: .object([:])),
            to: snapshotURL, expecting: .initial)
        try log.append([makeEvent(sequence: 1)], to: eventsURL, after: 0)
        var raw = try fileSystem.read(at: eventsURL)
        raw.append(contentsOf: Data("这不是 JSON\n".utf8))
        try fileSystem.write(raw, to: eventsURL)

        let report = inspector.inspect(snapshot: snapshotURL, events: eventsURL)
        guard case .healthy = report.snapshot else {
            Issue.record("快照应当仍完好:\(report.snapshot)")
            return
        }
        guard case .corrupted(let url, let line, _) = report.events else {
            Issue.record("日志应当损坏:\(report.events)")
            return
        }
        #expect(url == eventsURL)
        #expect(line == 2)
        #expect(report.formattedDescription().contains("第 2 行"))
        #expect(report.relation == .notApplicable)
    }

    // MARK: - 关系

    @Test("日志比快照新:pendingEvents", arguments: Implementation.allCases)
    func pendingEventsWhenLogIsAhead(_ implementation: Implementation) throws {
        let (_, inspector, store, log, snapshotURL, eventsURL, cleanup)
            = try makeSubject(implementation)
        defer { cleanup() }
        try store.save(
            DataEnvelope(
                revision: Revision(1), lastEventSequence: 1,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1),
                checksum: Checksum(value: 0),
                payload: .object([:])),
            to: snapshotURL, expecting: .initial)
        try log.append(
            [makeEvent(sequence: 1, id: 1), makeEvent(sequence: 2, id: 2),
             makeEvent(sequence: 3, id: 3)],
            to: eventsURL, after: 0)

        let report = inspector.inspect(snapshot: snapshotURL, events: eventsURL)
        #expect(report.relation == .pendingEvents(count: 2))
        #expect(report.formattedDescription().contains("2 条"))
    }

    @Test("快照游标超过日志:cursorAhead", arguments: Implementation.allCases)
    func cursorAheadWhenSnapshotLeads(_ implementation: Implementation) throws {
        let (fileSystem, inspector, store, log, snapshotURL, eventsURL, cleanup)
            = try makeSubject(implementation)
        defer { cleanup() }
        try log.append([makeEvent(sequence: 1)], to: eventsURL, after: 0)
        try store.save(
            DataEnvelope(
                revision: Revision(1), lastEventSequence: 5,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1),
                checksum: Checksum(value: 0),
                payload: .object([:])),
            to: snapshotURL, expecting: .initial)
        _ = fileSystem

        let report = inspector.inspect(snapshot: snapshotURL, events: eventsURL)
        #expect(report.relation == .cursorAhead(cursor: 5, lastInLog: 1))
    }

    // MARK: - 只读 / 新版本

    @Test("更新版本的快照标成只读,不是损坏", arguments: Implementation.allCases)
    func newerVersionIsReadOnly(_ implementation: Implementation) throws {
        let (fileSystem, inspector, store, _, snapshotURL, eventsURL, cleanup)
            = try makeSubject(implementation)
        defer { cleanup() }
        try store.save(
            DataEnvelope(
                revision: Revision(1), lastEventSequence: 0,
                createdAt: Date(timeIntervalSince1970: 1_000),
                updatedAt: Date(timeIntervalSince1970: 1_000),
                checksum: Checksum(value: 0),
                payload: .object([:])),
            to: snapshotURL, expecting: .initial)
        let loaded = try #require(try store.load(from: snapshotURL))
        var future = DataEnvelope(
            schemaVersion: SchemaVersion(99), revision: loaded.envelope.revision,
            lastEventSequence: loaded.envelope.lastEventSequence,
            createdAt: loaded.envelope.createdAt, updatedAt: loaded.envelope.updatedAt,
            checksum: Checksum(value: 0), payload: loaded.envelope.payload)
        let zeroed = DataEnvelope(
            schemaVersion: future.schemaVersion, revision: future.revision,
            lastEventSequence: future.lastEventSequence,
            createdAt: future.createdAt, updatedAt: future.updatedAt,
            checksum: Checksum(value: 0), payload: future.payload)
        let bytes = try CanonicalJSON.makeSnapshotEncoder().encode(zeroed)
        future = DataEnvelope(
            schemaVersion: future.schemaVersion, revision: future.revision,
            lastEventSequence: future.lastEventSequence,
            createdAt: future.createdAt, updatedAt: future.updatedAt,
            checksum: Checksum(hashing: bytes), payload: future.payload)
        try fileSystem.write(try CanonicalJSON.makeSnapshotEncoder().encode(future), to: snapshotURL)

        let report = inspector.inspect(snapshot: snapshotURL, events: eventsURL)
        guard case .readOnly(_, let version) = report.snapshot else {
            Issue.record("应当是只读:\(report.snapshot)")
            return
        }
        #expect(version == SchemaVersion(99))
        #expect(report.formattedDescription().contains("只能读"))
    }

    // MARK: - 只读保证

    @Test("检查完好文件时不写、不建目录、不删")
    func inspectNeverWrites() throws {
        let (fileSystem, inspector, store, log, snapshotURL, eventsURL, cleanup)
            = try makeSubject(.inMemory)
        defer { cleanup() }
        let memory = try #require(fileSystem as? InMemoryFileSystem)
        try store.save(
            DataEnvelope(
                revision: Revision(1), lastEventSequence: 1,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1),
                checksum: Checksum(value: 0),
                payload: .object([:])),
            to: snapshotURL, expecting: .initial)
        try log.append([makeEvent(sequence: 1)], to: eventsURL, after: 0)

        // 用观察点而不是 failNext:try? 会吞掉故障,目录已存在时
        // createDirectory 还是幂等成功。必须看到「调用过」才算写。
        let writes = WriteLog()
        memory.onOperation { operation, _ in
            switch operation {
            case .write, .replaceItem, .createDirectory, .removeItem:
                writes.record(operation)
            case .read, .contentsOfDirectory:
                break
            }
        }

        let report = inspector.inspect(snapshot: snapshotURL, events: eventsURL)
        guard case .healthy = report.snapshot, case .healthy = report.events else {
            Issue.record("只读检查应当成功:\(report)")
            return
        }
        #expect(report.relation == .consistent)
        #expect(writes.operations.isEmpty)
    }

    private final class WriteLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [InMemoryFileSystem.Operation] = []
        func record(_ operation: InMemoryFileSystem.Operation) {
            lock.lock(); defer { lock.unlock() }
            recorded.append(operation)
        }
        var operations: [InMemoryFileSystem.Operation] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
    }
}
