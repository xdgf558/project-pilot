import Foundation
import Testing
import PilotCore
import PilotTestSupport

@Suite("Command")
struct CommandTests {

    struct Payload: Codable, Sendable, Equatable {
        var name: String
    }

    @Test("CommandRequest 往返相等")
    func requestRoundTrips() throws {
        let event = Event(
            id: UUID(sequenceNumber: 1),
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1000),
            projectId: UUID(sequenceNumber: 2),
            entityType: OpenEnum(.task),
            entityId: UUID(sequenceNumber: 3),
            eventType: EventType(rawValue: "taskStageChanged"),
            actor: OpenEnum(.user),
            requestId: "req-1",
            payload: .object([:])
        )
        let original = CommandRequest(
            requestId: "req-1",
            idempotencyKey: "idem-1",
            expectedRevision: Revision(3),
            expectedLastEventSequence: 7,
            events: [event],
            payload: Payload(name: "任务表"))
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(original)
        #expect(try CanonicalJSON.makeDecoder().decode(CommandRequest<Payload>.self, from: data) == original)
    }

    @Test("CommandReceipt 往返相等")
    func receiptRoundTrips() throws {
        let original = CommandReceipt(
            requestId: "req-1", revision: Revision(2), lastEventSequence: 9)
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(original)
        #expect(try CanonicalJSON.makeDecoder().decode(CommandReceipt.self, from: data) == original)
    }

    @Test("requestId 类型不符时报 typeMismatch")
    func requestIdTypeMismatch() throws {
        let event = Event(
            id: UUID(sequenceNumber: 1), sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            projectId: UUID(sequenceNumber: 2), entityType: OpenEnum(.project),
            entityId: UUID(sequenceNumber: 2), eventType: EventType(rawValue: "x"),
            actor: OpenEnum(.user), requestId: "req-1")
        let request = CommandRequest(
            requestId: "req-1", expectedRevision: .initial,
            expectedLastEventSequence: 0, events: [event], payload: Payload(name: "a"))
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(request)
        let broken = try JSONMutation.replacing(data, key: "requestId", with: 12)
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(CommandRequest<Payload>.self, from: broken)
        } == .typeMismatch)
    }

    @Test("缺 events 时报 keyNotFound,与 typeMismatch 正交")
    func missingEventsIsKeyNotFound() throws {
        let event = Event(
            id: UUID(sequenceNumber: 1), sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            projectId: UUID(sequenceNumber: 2), entityType: OpenEnum(.project),
            entityId: UUID(sequenceNumber: 2), eventType: EventType(rawValue: "x"),
            actor: OpenEnum(.user), requestId: "req-1")
        let request = CommandRequest(
            requestId: "req-1", expectedRevision: .initial,
            expectedLastEventSequence: 0, events: [event], payload: Payload(name: "a"))
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(request)
        let broken = try JSONMutation.removing(data, key: "events")
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(CommandRequest<Payload>.self, from: broken)
        } == .keyNotFound)
    }
}
