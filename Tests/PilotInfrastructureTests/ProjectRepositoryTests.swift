import Foundation
import Testing
import PilotCore
import PilotInfrastructure
import PilotTestSupport

@Suite("ProjectRepository")
struct ProjectRepositoryTests {

    enum Implementation: String, CaseIterable, Sendable {
        case inMemory
        case system
    }

    struct Payload: Codable, Sendable, Equatable {
        var name: String
        var count: Int
    }

    private func makeSubject(_ implementation: Implementation) throws
        -> (
            fileSystem: any FileSystem,
            repo: ProjectRepository<Payload>,
            snapshotURL: URL,
            eventsURL: URL,
            cleanup: @Sendable () -> Void
        )
    {
        switch implementation {
        case .inMemory:
            let fileSystem = InMemoryFileSystem()
            let root = URL(fileURLWithPath: "/pilot-repo-\(UUID().uuidString)")
            let snapshotURL = root.appendingPathComponent("state.json")
            let eventsURL = root.appendingPathComponent("events.ndjson")
            let repo = ProjectRepository<Payload>(
                fileSystem: fileSystem,
                snapshotURL: snapshotURL,
                eventsURL: eventsURL,
                timeSource: FakeClock(now: Date(timeIntervalSince1970: 5000)))
            return (fileSystem, repo, snapshotURL, eventsURL, {})
        case .system:
            let fileSystem = SystemFileSystem()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pilot-repo-\(UUID().uuidString)", isDirectory: true)
            let snapshotURL = root.appendingPathComponent("state.json")
            let eventsURL = root.appendingPathComponent("events.ndjson")
            let repo = ProjectRepository<Payload>(
                fileSystem: fileSystem,
                snapshotURL: snapshotURL,
                eventsURL: eventsURL,
                timeSource: FakeClock(now: Date(timeIntervalSince1970: 5000)))
            return (fileSystem, repo, snapshotURL, eventsURL, {
                try? FileManager.default.removeItem(at: root)
            })
        }
    }

    private func makeEvent(sequence: Int64, requestId: String, id: UInt32 = 1) -> Event {
        Event(
            id: UUID(sequenceNumber: id),
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: 1000 + Double(sequence)),
            projectId: UUID(sequenceNumber: 100),
            entityType: OpenEnum(.task),
            entityId: UUID(sequenceNumber: 12),
            eventType: EventType(rawValue: "taskStageChanged"),
            actor: OpenEnum(.system),
            requestId: requestId,
            payload: .object(["n": .integer(sequence)])
        )
    }

    private func request(
        requestId: String = "req-1",
        revision: Revision = .initial,
        after: Int64 = 0,
        events: [Event]? = nil,
        payload: Payload = Payload(name: "初版", count: 1)
    ) -> CommandRequest<Payload> {
        let events = events ?? [makeEvent(sequence: after + 1, requestId: requestId)]
        return CommandRequest(
            requestId: requestId,
            expectedRevision: revision,
            expectedLastEventSequence: after,
            events: events,
            payload: payload)
    }

    // MARK: - 正向

    @Test("首次执行:事件与快照一起落下,回执带新游标", arguments: Implementation.allCases)
    func firstExecutePersistsBoth(_ implementation: Implementation) async throws {
        let (_, repo, _, _, cleanup) = try makeSubject(implementation)
        defer { cleanup() }

        #expect(try repo.load() == nil)
        #expect(try repo.loadEvents() == [])

        let receipt = try await repo.execute(request(payload: Payload(name: "初版", count: 1)))
        #expect(receipt.requestId == "req-1")
        #expect(receipt.revision == Revision(1))
        #expect(receipt.lastEventSequence == 1)

        let snapshot = try #require(try repo.load())
        #expect(snapshot.envelope.payload == Payload(name: "初版", count: 1))
        #expect(snapshot.envelope.revision == Revision(1))
        #expect(snapshot.envelope.lastEventSequence == 1)
        #expect(try repo.loadEvents().map(\.sequence) == [1])
        #expect(try repo.pendingEvents() == [])
    }

    @Test("第二次执行接到上次回执的游标", arguments: Implementation.allCases)
    func secondExecuteUsesReceiptCursor(_ implementation: Implementation) async throws {
        let (_, repo, _, _, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        let first = try await repo.execute(request(requestId: "req-1"))
        let second = try await repo.execute(request(
            requestId: "req-2",
            revision: first.revision,
            after: first.lastEventSequence,
            events: [makeEvent(sequence: 2, requestId: "req-2", id: 2)],
            payload: Payload(name: "第二版", count: 2)))

        #expect(second.revision == Revision(2))
        #expect(second.lastEventSequence == 2)
        #expect(try #require(try repo.load()).envelope.payload == Payload(name: "第二版", count: 2))
        #expect(try repo.loadEvents().map(\.sequence) == [1, 2])
    }

    @Test("首次执行:父目录不存在也能创建", arguments: Implementation.allCases)
    func firstExecuteCreatesDirectories(_ implementation: Implementation) async throws {
        let (_, repo, _, _, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        _ = try await repo.execute(request())
        #expect(try repo.load() != nil)
    }

    // MARK: - 命令入口校验(与存储层错误正交)

    @Test("空 requestId 被拒,什么都不写", arguments: Implementation.allCases)
    func rejectsEmptyRequestId(_ implementation: Implementation) async throws {
        let (_, repo, _, _, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        let blank = CommandRequest(
            requestId: "   ",
            expectedRevision: .initial,
            expectedLastEventSequence: 0,
            events: [makeEvent(sequence: 1, requestId: "   ")],
            payload: Payload(name: "x", count: 1))
        await #expect(throws: CommandError.emptyRequestId) {
            try await repo.execute(blank)
        }
        #expect(try repo.load() == nil)
        #expect(try repo.loadEvents() == [])
    }

    @Test("空事件被拒,与 sequenceConflict 正交", arguments: Implementation.allCases)
    func rejectsEmptyEvents(_ implementation: Implementation) async throws {
        let (_, repo, _, eventsURL, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        let empty = CommandRequest(
            requestId: "req-1",
            expectedRevision: .initial,
            expectedLastEventSequence: 0,
            events: [],
            payload: Payload(name: "x", count: 1))
        await #expect(throws: CommandError.emptyEvents) {
            try await repo.execute(empty)
        }

        _ = try await repo.execute(request(requestId: "req-1"))
        await #expect(throws: EventLogError.sequenceConflict(
            url: eventsURL, onDiskLast: 1, expectedLast: 0)) {
            try await repo.execute(request(
                requestId: "req-2", after: 0,
                events: [makeEvent(sequence: 1, requestId: "req-2", id: 2)]))
        }
    }

    @Test("事件 requestId 与命令不一致被拒", arguments: Implementation.allCases)
    func rejectsMismatchedEventRequestId(_ implementation: Implementation) async throws {
        let (_, repo, _, _, cleanup) = try makeSubject(implementation)
        defer { cleanup() }
        let mismatched = request(
            requestId: "req-1",
            events: [makeEvent(sequence: 1, requestId: "other")])
        do {
            _ = try await repo.execute(mismatched)
            Issue.record("应当抛 .requestIdMismatch")
        } catch let error as CommandError {
            guard case .requestIdMismatch(_, "req-1", "other") = error else {
                Issue.record("抛了别的 case:\(error)")
                return
            }
        }
        #expect(try repo.load() == nil)
    }

    // MARK: - 崩溃恢复(事件先于快照)

    @Test("快照写入失败:事件已落下,pendingEvents 能接住")
    func snapshotFailureLeavesEventsForReplay() async throws {
        let (fileSystem, repo, snapshotURL, _, cleanup) = try makeSubject(.inMemory)
        defer { cleanup() }
        let memory = try #require(fileSystem as? InMemoryFileSystem)

        _ = try await repo.execute(request(requestId: "req-1"))
        memory.failNext(.replaceItem, at: snapshotURL, with: .diskFull)

        do {
            _ = try await repo.execute(request(
                requestId: "req-2",
                revision: Revision(1),
                after: 1,
                events: [makeEvent(sequence: 2, requestId: "req-2", id: 2)],
                payload: Payload(name: "第二版", count: 2)))
            Issue.record("应当抛文件系统错误")
        } catch is FileSystemError {
            // 透传
        }

        #expect(try #require(try repo.load()).envelope.lastEventSequence == 1)
        #expect(try repo.loadEvents().map(\.sequence) == [1, 2])
        #expect(try repo.pendingEvents().map(\.sequence) == [2])
    }

    // MARK: - 并发

    @Test("并发双执行:恰好一个成功", arguments: Implementation.allCases)
    func concurrentExecuteExactlyOneWins(_ implementation: Implementation) async throws {
        for _ in 0..<10 {
            let (_, repo, _, _, cleanup) = try makeSubject(implementation)
            defer { cleanup() }
            _ = try await repo.execute(request(requestId: "seed"))

            let outcomes = await withTaskGroup(of: Result<CommandReceipt, any Error>.self) { group in
                for (requestId, id) in [("req-a", UInt32(10)), ("req-b", UInt32(20))] {
                    group.addTask {
                        let req = request(
                            requestId: requestId,
                            revision: Revision(1),
                            after: 1,
                            events: [makeEvent(sequence: 2, requestId: requestId, id: id)],
                            payload: Payload(name: requestId, count: Int(id)))
                        do {
                            return .success(try await repo.execute(req))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                var collected: [Result<CommandReceipt, any Error>] = []
                for await item in group { collected.append(item) }
                return collected
            }
            let successes = outcomes.filter { if case .success = $0 { return true }; return false }
            #expect(successes.count == 1, "两次执行都成功 = 快照与日志可能分叉")
            let snapshot = try #require(try repo.load())
            #expect(snapshot.envelope.revision == Revision(2))
            #expect(try repo.loadEvents().map(\.sequence) == [1, 2])
            #expect(try repo.pendingEvents() == [])
        }
    }
}
