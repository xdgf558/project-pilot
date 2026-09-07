import Foundation

/// 一次命令请求。
///
/// 命令是 Codable 值类型,带 `requestId`(ADR-0001)。XPC 与进程内
/// 走同一个 `execute` —— 传输层以后再套,业务代码不动。
///
/// **本层不解释业务。** `events` 与 `payload` 由调用方准备
/// (调用领域对象上已经存在的 `transition` 等)。命令层负责:
/// 校验 requestId、按序追加事件、乐观写入快照,并保证这两步
/// 落在同一把事务锁里。具体有哪些业务命令,v0.2 原文不在仓库内,
/// 不在这里猜(见 ADR-0017)。
///
/// `idempotencyKey` 先占位。同一个 key 重复到达时不产生第二条事件
/// 是 P6-02,本层不做去重。
public struct CommandRequest<Payload: Codable & Sendable>: Sendable, Codable {
    public let requestId: String
    public let idempotencyKey: String?
    public let expectedRevision: Revision
    public let expectedLastEventSequence: Int64
    public let events: [Event]
    public let payload: Payload

    public init(
        requestId: String,
        idempotencyKey: String? = nil,
        expectedRevision: Revision,
        expectedLastEventSequence: Int64,
        events: [Event],
        payload: Payload
    ) {
        self.requestId = requestId
        self.idempotencyKey = idempotencyKey
        self.expectedRevision = expectedRevision
        self.expectedLastEventSequence = expectedLastEventSequence
        self.events = events
        self.payload = payload
    }
}

extension CommandRequest: Equatable where Payload: Equatable {}

/// 一次成功执行的回执。
///
/// 调用方拿它更新自己的游标;下一步命令必须带上这里的
/// `revision` 与 `lastEventSequence`,否则乐观并发会拒。
public struct CommandReceipt: Sendable, Hashable, Equatable, Codable {
    public let requestId: String
    public let revision: Revision
    public let lastEventSequence: Int64

    public init(requestId: String, revision: Revision, lastEventSequence: Int64) {
        self.requestId = requestId
        self.revision = revision
        self.lastEventSequence = lastEventSequence
    }
}

/// 命令入口自己的错误。存储层的冲突与损坏原样透传
/// (`EventLogError` / `ProjectStoreError` / `FileSystemError`),不换类型 ——
/// 上层要区分「请求不合法」「游标过期」「磁盘故障」。
public enum CommandError: Error, Equatable, Sendable, LocalizedError {
    /// requestId 为空或纯空白。没有它,P6-02 的幂等和审计对不上号。
    case emptyRequestId
    /// 一次命令零条事件。v0.2 §2.8 要求状态变化写进事件日志;
    /// 只改快照、不记事件,重放就会丢这次变化。
    case emptyEvents
    /// 事件上的 requestId 必须与命令一致。对不上的事件写进日志,
    /// 按 requestId 追溯时会指向另一次命令。
    case requestIdMismatch(eventId: UUID, expected: String, actual: String?)

    public var errorDescription: String? {
        switch self {
        case .emptyRequestId:
            return "命令被拒:requestId 不能为空。没有它就无法追溯,也无法做幂等。"
        case .emptyEvents:
            return "命令被拒:一次执行必须追加至少一条事件。"
                + "只改快照不记事件,重放会丢掉这次变化。"
        case .requestIdMismatch(let eventId, let expected, let actual):
            let got = actual.map { "\"\($0)\"" } ?? "nil"
            return "命令被拒:事件 \(eventId.uuidString) 的 requestId 是 \(got),"
                + "必须与命令的 \"\(expected)\" 一致。"
        }
    }
}
