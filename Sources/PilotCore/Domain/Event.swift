import Foundation

/// 事件涉及的实体种类。
///
/// 用开放枚举,理由是**只追加的事件日志**(见 `OpenEnum` 文档第二条):
/// 几年前的事件必须永远读得出来,而严格枚举会让退掉的种类变成解不开的数据。
public enum EntityKind: String, OpenEnumValue {
    case project
    case task
    case job
    case review
    case pullRequest
}

/// 谁触发了这个事件。
public enum ActorKind: String, OpenEnumValue {
    /// 人在界面上操作。
    case user
    /// 系统自己推导或调度出来的。
    case system
    /// 执行器产生的。
    case executor
}

/// 事件类型。
///
/// 刻意做成开放的字符串常量集合而不是枚举:事件类型会随每个 Phase 增加,
/// 而**已经写进日志的旧类型必须永远读得出来**。为一次改名去重写审计日志,
/// 比留着一个旧字符串糟得多。
///
/// 已知类型放在这里做常量,拼写错误靠审查和测试兜 —— 换来的是历史永远可读。
public struct EventType: Sendable, Hashable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard !raw.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "事件类型不能是空串"
            )
        }
        rawValue = raw
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// 一条不可变的事件记录。
///
/// v0.2 §2.8:所有状态变化和高风险命令都写进事件日志。
/// 快照可以由事件重放出来(P1-06),所以事件是比快照更根本的真相。
///
/// **事件写下之后不改。** 所有字段都是 `let` —— 需要更正时追加一条新事件,
/// 不是回去修旧的。审计记录一旦可以修改就不再是审计记录。
public struct Event: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    /// 写下这条事件时的数据格式版本。
    public let schemaVersion: SchemaVersion
    /// 项目内单调递增,从 1 起。快照靠它知道自己重放到哪了(P1-06)。
    public let sequence: Int64
    public let timestamp: Date
    public let projectId: UUID
    public let entityType: OpenEnum<EntityKind>
    public let entityId: UUID
    public let eventType: EventType
    public let actor: OpenEnum<ActorKind>
    /// 幂等键。同一个 requestId 重复到达时不应产生第二条事件(P6-02)。
    public let requestId: String?
    /// 为什么这么做。
    ///
    /// v0.2 §2.8 规定这几种情况**必须**有:`force`、手动绑定 PR、手动改状态、
    /// 取消作业、迁移、恢复备份、合并。半年后回看一次强制操作,
    /// 需要知道的是当时为什么绕过闸门 —— 那只存在于人脑里。
    ///
    /// 「必须有」由产生事件的那一层强制(P1-03 起),不在这里 ——
    /// 这里判断不了一个 eventType 属不属于那七种。
    public let reason: String?
    /// 事件负载。结构随 eventType 变,所以用开放的 JSON 树。
    public let payload: JSONValue

    public init(
        id: UUID,
        schemaVersion: SchemaVersion = .current,
        sequence: Int64,
        timestamp: Date,
        projectId: UUID,
        entityType: OpenEnum<EntityKind>,
        entityId: UUID,
        eventType: EventType,
        actor: OpenEnum<ActorKind>,
        requestId: String? = nil,
        reason: String? = nil,
        payload: JSONValue = .object([:])
    ) {
        precondition(sequence >= 1, "事件序号从 1 起,收到:\(sequence)")
        self.id = id
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.timestamp = timestamp
        self.projectId = projectId
        self.entityType = entityType
        self.entityId = entityId
        self.eventType = eventType
        self.actor = actor
        self.requestId = requestId
        self.reason = reason
        self.payload = payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        schemaVersion = try container.decode(SchemaVersion.self, forKey: .schemaVersion)
        sequence = try container.decode(Int64.self, forKey: .sequence)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        entityType = try container.decode(OpenEnum<EntityKind>.self, forKey: .entityType)
        entityId = try container.decode(UUID.self, forKey: .entityId)
        eventType = try container.decode(EventType.self, forKey: .eventType)
        actor = try container.decode(OpenEnum<ActorKind>.self, forKey: .actor)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        payload = try container.decode(JSONValue.self, forKey: .payload)

        guard sequence >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .sequence, in: container,
                debugDescription: "事件序号从 1 起,实际读到:\(sequence)"
            )
        }
    }
}
