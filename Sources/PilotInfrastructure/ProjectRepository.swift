import Foundation
import PilotCore

/// 进程内命令入口(P1-07)。
///
/// App 经 XPC、进程内复用**同一套** `execute`(ADR-0001)。本类型是进程内
/// 实现;XPC 以后是另一个 `execute` 的传输外壳,不改这里的协议。
///
/// ## 一次执行做的事
///
/// 1. 校验 requestId / 事件非空 / 事件 requestId 与命令一致;
/// 2. 先追加事件,再乐观写入快照。
///
/// 事件先、快照后:崩溃发生在两步之间时,快照落后于日志 ——
/// 这正是 `lastEventSequence` 游标要接住的现场,`pendingEvents()` 可以补上。
/// 反过来写会让快照超前,`eventsToReplay` 会报 `cursorAheadOfLog`。
///
/// 两步各自带锁(`EventLog` / `ProjectStore`)。不再套第三把事务锁:
/// 探针实测拿掉它并发测试仍然绿 —— 乐观校验已经让双写恰好一个成功,
/// 夹在两步之间的现场由 `pendingEvents` 恢复。套一把测不红的锁是假安全。
///
/// ## 不做
///
/// 不解释 eventType、不调用 `transition`(调用方在进 `execute` 之前做);
/// 不按 requestId / idempotencyKey 去重(P6-02);不套 XPC。
public struct ProjectRepository<Payload: Codable & Sendable>: Sendable {
    private let fileSystem: any FileSystem
    private let store: ProjectStore<Payload>
    private let eventLog: EventLog
    private let snapshotURL: URL
    private let eventsURL: URL
    private let timeSource: any TimeSource

    public init(
        fileSystem: any FileSystem,
        snapshotURL: URL,
        eventsURL: URL,
        timeSource: any TimeSource = SystemTimeSource()
    ) {
        self.fileSystem = fileSystem
        self.store = ProjectStore(fileSystem: fileSystem)
        self.eventLog = EventLog(fileSystem: fileSystem)
        self.snapshotURL = snapshotURL
        self.eventsURL = eventsURL
        self.timeSource = timeSource
    }

    /// 读取当前快照。文件不存在返回 nil。
    public func load() throws -> LoadedSnapshot<Payload>? {
        try store.load(from: snapshotURL)
    }

    /// 读取事件日志。文件不存在返回空。
    public func loadEvents() throws -> [Event] {
        try eventLog.load(from: eventsURL)
    }

    /// 从当前快照的游标接着取出尚未折入快照的事件。
    public func pendingEvents() throws -> [Event] {
        guard let snapshot = try load() else {
            return try eventLog.events(from: eventsURL, after: 0)
        }
        return try eventLog.eventsToReplay(from: snapshot.envelope, log: eventsURL)
    }

    public func execute(_ request: CommandRequest<Payload>) async throws -> CommandReceipt {
        let requestId = request.requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestId.isEmpty else { throw CommandError.emptyRequestId }
        guard let lastSequence = request.events.last?.sequence else {
            throw CommandError.emptyEvents
        }
        for event in request.events {
            guard event.requestId == requestId else {
                throw CommandError.requestIdMismatch(
                    eventId: event.id, expected: requestId, actual: event.requestId)
            }
        }

        try fileSystem.createDirectory(at: snapshotURL.deletingLastPathComponent())
        try fileSystem.createDirectory(at: eventsURL.deletingLastPathComponent())

        let nextRevision = request.expectedRevision.next
        let now = timeSource.now

        try eventLog.append(
            request.events, to: eventsURL, after: request.expectedLastEventSequence)

        let createdAt = try store.load(from: snapshotURL)?.envelope.createdAt ?? now
        let envelope = DataEnvelope(
            revision: nextRevision,
            lastEventSequence: lastSequence,
            createdAt: createdAt,
            updatedAt: now,
            checksum: Checksum(value: 0),
            payload: request.payload)
        try store.save(envelope, to: snapshotURL, expecting: request.expectedRevision)

        return CommandReceipt(
            requestId: requestId,
            revision: nextRevision,
            lastEventSequence: lastSequence)
    }
}
