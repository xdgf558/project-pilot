import Foundation

/// 落盘数据的外壳。
///
/// 每个权威数据文件都是一个 envelope 包着一份 payload。外壳携带
/// 版本、修订号、事件游标、时间戳和校验和 —— 也就是「这份数据是什么、
/// 从哪来、能不能信」所需的全部信息(v0.2 §3 写入规则第 1 条)。
///
/// ## 关于校验和的分工
///
/// 本类型只**携带**校验和,不计算也不验证。
///
/// 计算和验证是仓库层(P1-05)的事,因为只有它知道实际写进磁盘的字节。
/// 让 envelope 自己在解码时重新编码一遍 payload 来对比,看着更自足,
/// 实际上把「校验和正确」建立在「重新编码必然字节相同」这个更强的假设上 ——
/// 一旦哪个字段的编码行为变了,数据会被误判为损坏。
/// 宁可让分工显式,也不要一个会误报损坏的自检。
///
/// 前提条件(规范编码必须往返字节稳定)由 `CanonicalJSON` 保证,
/// 并有对应测试。
///
/// ## 关于未知字段
///
/// 解码时,顶层出现的、本类型不认识的键会被收进 `unknownFields`,
/// 编码时原样写回。v0.2 §3 规则 9 要求这个。
///
/// 要防的场景很具体:用户装了新版本,新版本给文件加了字段;
/// 然后回退到旧版本跑了一次。旧版本读进来、写回去,新字段就没了 ——
/// 等他再升上去,那些数据已经永久消失,而且全程没有任何报错。
public struct DataEnvelope<Payload: Codable & Sendable>: Sendable {
    public let schemaVersion: SchemaVersion
    public let revision: Revision
    /// 快照对应到事件日志的哪一条。重放时从这里之后接着放(P1-06)。
    public let lastEventSequence: Int64
    public let createdAt: Date
    public let updatedAt: Date
    /// 由仓库层计算与验证,见上方说明。
    public let checksum: Checksum
    public let payload: Payload
    /// 解码时遇到的、本版本不认识的顶层键。编码时原样写回。
    public let unknownFields: [String: JSONValue]

    public init(
        schemaVersion: SchemaVersion = .current,
        revision: Revision,
        lastEventSequence: Int64,
        createdAt: Date,
        updatedAt: Date,
        checksum: Checksum,
        payload: Payload,
        unknownFields: [String: JSONValue] = [:]
    ) {
        precondition(lastEventSequence >= 0, "lastEventSequence 不能为负,收到:\(lastEventSequence)")
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.lastEventSequence = lastEventSequence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.checksum = checksum
        self.payload = payload
        self.unknownFields = unknownFields
    }
}

extension DataEnvelope: Codable {
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        init(_ known: Known) { self.stringValue = known.rawValue }
    }

    private enum Known: String, CaseIterable {
        case schemaVersion, revision, lastEventSequence
        case createdAt, updatedAt, checksum, payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)

        schemaVersion = try container.decode(SchemaVersion.self, forKey: AnyKey(.schemaVersion))
        revision = try container.decode(Revision.self, forKey: AnyKey(.revision))
        lastEventSequence = try container.decode(Int64.self, forKey: AnyKey(.lastEventSequence))
        createdAt = try container.decode(Date.self, forKey: AnyKey(.createdAt))
        updatedAt = try container.decode(Date.self, forKey: AnyKey(.updatedAt))
        checksum = try container.decode(Checksum.self, forKey: AnyKey(.checksum))
        payload = try container.decode(Payload.self, forKey: AnyKey(.payload))

        guard lastEventSequence >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: AnyKey(.lastEventSequence),
                in: container,
                debugDescription: "lastEventSequence 不能为负,实际读到:\(lastEventSequence)"
            )
        }

        let known = Set(Known.allCases.map(\.rawValue))
        var extras: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        unknownFields = extras
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)

        try container.encode(schemaVersion, forKey: AnyKey(.schemaVersion))
        try container.encode(revision, forKey: AnyKey(.revision))
        try container.encode(lastEventSequence, forKey: AnyKey(.lastEventSequence))
        try container.encode(createdAt, forKey: AnyKey(.createdAt))
        try container.encode(updatedAt, forKey: AnyKey(.updatedAt))
        try container.encode(checksum, forKey: AnyKey(.checksum))
        try container.encode(payload, forKey: AnyKey(.payload))

        // 未知字段最后写。已知键名与未知键名撞车是不可能的 ——
        // 撞车说明它根本不是未知字段,解码时就会走进已知分支。
        for (name, value) in unknownFields {
            try container.encode(value, forKey: AnyKey(stringValue: name))
        }
    }
}

extension DataEnvelope: Equatable where Payload: Equatable {}
