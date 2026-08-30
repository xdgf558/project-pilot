import Foundation
import Testing
import PilotCore
import PilotTestSupport

@Suite("Event")
struct EventTests {

    private func makeEvent(sequence: Int64 = 1) -> Event {
        Event(
            id: UUID(sequenceNumber: 1),
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: 1000.5),
            projectId: UUID(sequenceNumber: 100),
            entityType: OpenEnum(.task),
            entityId: UUID(sequenceNumber: 12),
            eventType: EventType(rawValue: "taskStageChanged"),
            actor: OpenEnum(.system),
            requestId: "req-abc",
            reason: "依赖 #3 已完成",
            payload: .object([
                "from": .string("blocked"),
                "to": .string("ready"),
                "dependencyCount": .number(2),
            ])
        )
    }

    @Test("往返相等")
    func roundTrips() throws {
        let original = makeEvent()
        let data = try CanonicalJSON.makeEventEncoder().encode(original)
        #expect(try CanonicalJSON.makeDecoder().decode(Event.self, from: data) == original)
    }

    @Test("事件编码成单行,能进 NDJSON")
    func encodesToSingleLine() throws {
        // 事件日志是 NDJSON,一条事件必须占且只占一行(P1-06)。
        // 用快照那个 prettyPrinted 编码器会把日志写坏。
        let data = try CanonicalJSON.makeEventEncoder().encode(makeEvent())
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\n") == false)
    }

    @Test("payload 可以是任意 JSON 结构")
    func payloadIsOpen() throws {
        var event = makeEvent()
        event = Event(
            id: event.id, sequence: event.sequence, timestamp: event.timestamp,
            projectId: event.projectId, entityType: event.entityType,
            entityId: event.entityId, eventType: event.eventType, actor: event.actor,
            payload: .array([.number(1), .string("两"), .null,
                             .object(["嵌套": .bool(true)])])
        )
        let data = try CanonicalJSON.makeEventEncoder().encode(event)
        #expect(try CanonicalJSON.makeDecoder().decode(Event.self, from: data) == event)
    }

    @Test("payload 默认是空对象,不是 null")
    func payloadDefaultsToEmptyObject() {
        let event = Event(
            id: UUID(sequenceNumber: 1), sequence: 1, timestamp: Date(),
            projectId: UUID(sequenceNumber: 2), entityType: OpenEnum(.project),
            entityId: UUID(sequenceNumber: 2), eventType: EventType(rawValue: "projectCreated"),
            actor: OpenEnum(.user)
        )
        #expect(event.payload == .object([:]))
    }

    // MARK: - 旧事件必须永远读得出来

    @Test("退役的事件类型仍然读得出来")
    func retiredEventTypeStillReadable() throws {
        // 事件日志是不可变的审计记录。哪天退掉一个事件类型,
        // 几年前的事件也必须照样读得出来 —— 为一次改名去重写审计日志,
        // 比留着一个旧字符串糟得多。
        let raw = """
        {"actor":"system","entityId":"00000000-0000-0000-0000-00000000000c",\
        "entityType":"task","eventType":"someRetiredTypeFrom2024",\
        "id":"00000000-0000-0000-0000-000000000001","payload":{},\
        "projectId":"00000000-0000-0000-0000-000000000064","schemaVersion":1,\
        "sequence":7,"timestamp":1000}
        """
        let decoded = try CanonicalJSON.makeDecoder().decode(Event.self, from: Data(raw.utf8))
        #expect(decoded.eventType.rawValue == "someRetiredTypeFrom2024")
    }

    @Test("未知的实体种类和 actor 也读得出来")
    func unknownClassificationsStillReadable() throws {
        var data = try CanonicalJSON.makeEventEncoder().encode(makeEvent())
        data = try JSONMutation.replacing(data, key: "entityType", with: "worktree")
        data = try JSONMutation.replacing(data, key: "actor", with: "scheduler")
        let decoded = try CanonicalJSON.makeDecoder().decode(Event.self, from: data)
        #expect(decoded.entityType.rawValue == "worktree")
        #expect(decoded.entityType.isUnrecognized)
        #expect(decoded.actor.rawValue == "scheduler")
        #expect(decoded.actor.isUnrecognized)
    }

    // MARK: - 校验

    @Test("序号小于 1 解码失败", arguments: [0, -1])
    func rejectsInvalidSequence(_ value: Int) throws {
        // 序号从 1 起且单调递增,快照靠它知道重放到哪了(P1-06)。
        let data = try CanonicalJSON.makeEventEncoder().encode(makeEvent())
        let broken = try JSONMutation.replacing(data, key: "sequence", with: value)
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Event.self, from: broken)
        } == .dataCorrupted)
    }

    @Test("空的事件类型解码失败")
    func rejectsEmptyEventType() throws {
        let data = try CanonicalJSON.makeEventEncoder().encode(makeEvent())
        let broken = try JSONMutation.replacing(data, key: "eventType", with: "")
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Event.self, from: broken)
        } == .dataCorrupted)
    }

    @Test("缺 schemaVersion 解码失败")
    func rejectsMissingSchemaVersion() throws {
        // 没有版本号的事件无法迁移 —— 不知道它是按哪套规则写的。
        let data = try CanonicalJSON.makeEventEncoder().encode(makeEvent())
        let broken = try JSONMutation.removing(data, key: "schemaVersion")
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Event.self, from: broken)
        } == .keyNotFound)
    }

    @Test("timestamp 类型不符时报 typeMismatch")
    func rejectsWrongTypeForTimestamp() throws {
        let data = try CanonicalJSON.makeEventEncoder().encode(makeEvent())
        let broken = try JSONMutation.replacing(data, key: "timestamp", with: "刚才")
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Event.self, from: broken)
        } == .typeMismatch)
    }

    @Test("实体种类的 raw value 写死")
    func rawValuesArePinned() {
        #expect(Set(EntityKind.allCases.map(\.rawValue))
                == ["project", "task", "job", "review", "pullRequest"])
        #expect(Set(ActorKind.allCases.map(\.rawValue)) == ["user", "system", "executor"])
    }
}
