import Foundation

/// 权威数据的格式版本。
///
/// 单调递增的整数,不是 semver。这里两端都在我们自己手里,
/// 需要回答的问题只有一个:「存的这份比我认识的新还是旧」。
/// major.minor 会引入「minor 变化能不能安全忽略」这类判断,
/// 而那正是最容易判断错的地方。
///
/// **本类型不决定版本策略。** 存的比当前新时该拒绝、该只读、还是该照读,
/// 是仓库层(P1-05)的事 —— 那需要知道具体改了什么,不是版本号能回答的。
public struct SchemaVersion: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        precondition(rawValue >= 1, "schemaVersion 必须从 1 起,收到:\(rawValue)")
        self.rawValue = rawValue
    }

    /// 当前代码写出的版本。
    public static let current = SchemaVersion(1)

    public static func < (lhs: SchemaVersion, rhs: SchemaVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { "v\(rawValue)" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        guard raw >= 1 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "schemaVersion 必须 >= 1,实际读到:\(raw)"
            )
        }
        self.rawValue = raw
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 乐观并发的修订号。
///
/// 每次成功写入 +1。写入方必须带上自己读到的 revision,
/// 与磁盘上的不一致就说明中间有人写过 —— 这时候要失败,不能覆盖。
/// v0.2 P1-05 的「revision 乐观校验」就是这个。
public struct Revision: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: Int64

    public init(_ rawValue: Int64) {
        precondition(rawValue >= 0, "revision 不能为负,收到:\(rawValue)")
        self.rawValue = rawValue
    }

    /// 尚未写入过任何内容。
    public static let initial = Revision(0)

    public var next: Revision { Revision(rawValue + 1) }

    public static func < (lhs: Revision, rhs: Revision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { "r\(rawValue)" }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int64.self)
        guard raw >= 0 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "revision 不能为负,实际读到:\(raw)"
            )
        }
        self.rawValue = raw
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
