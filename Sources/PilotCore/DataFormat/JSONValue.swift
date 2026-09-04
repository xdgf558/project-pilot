import Foundation

/// 一棵任意的 JSON 树。
///
/// 存在的唯一理由是**保留未知字段**。v0.2 §3 写入规则第 9 条要求
/// 「JSON 解码保留未知字段,避免新旧版本往返时丢失数据」——
/// 而 Swift 的 `Codable` 默认直接丢弃它不认识的键。
///
/// 具体的失败场景:用户装了新版本,新版本给 `state.json` 加了字段;
/// 然后用户回退到旧版本跑了一次。旧版本读进来、写回去,新字段就没了。
/// 等他再升上去,那些数据已经永久消失,而且**全程没有任何报错**。
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// 整数值的数字(含超出 Double 精度的,≤ Int64 上限)。
    /// **必须有这个 case**:未知字段原样保留是 v0.2 §3 规则 9 的要求,
    /// 而「未来版本写进 unknownFields 的大整数」在 Double 下会丢精度,
    /// 旧版本解码、重编码后字节变了,一份完好的新版快照会被误报损坏 ——
    /// 「新版可读不可写」的承诺就兑现不了(P1-05 审查发现)。
    ///
    /// 本台编码器把整数值的 Double 写成整数字面量,所以构造
    /// \`.number(42)\` 再持久化,读回来是 \`.integer(42)\` ——
    /// 两者的**值语义相等**(见 == 的实现),字节表示也相同;
    /// 不相等的只有 case 标签本身。浮点带小数部分时仍是 \`.number\`。
    case integer(Int64)
    /// 非整数的数字。与等值的 \`.integer\` 相等(值语义),
    /// 但只有 \`.integer\` 能保真 Int64 范围内的大整数。
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

/// 值语义:42、42.0 与 .integer(42) / .number(42) 彼此相等。
///
/// **为什么跨 case 相等**:持久化往返会把整数值的 Double 变成 .integer
/// (编码器写整数字面量),若 case 标签参与相等,合法的 .number(42)
/// 存进去再读出来就不等于自己 —— payload 匹配、事件去重、重放断言
/// 全都会被这个影子差异咬到。
///
/// 跨 case 比较用 `Int64(exactly:)`:仅当 Double 精确可逆地表示该整数时
/// 才可能相等,所以 .integer(9007199254740993) 与
/// .number(9007199254740992.0) **不**相等 —— 数值上它们就是两个数。
///
/// 哈希按归一化的 Double 计算,满足 Hashable 契约(相等 ⇒ 同哈希;
/// 反方向允许碰撞)。
extension JSONValue {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)): return a == b
        case (.integer(let a), .number(let b)):
            return Int64(exactly: b) == a
        case (.number(let a), .integer(let b)):
            return Int64(exactly: a) == b
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let value): hasher.combine(1); hasher.combine(value)
        case .integer(let value): hasher.combine(2); hasher.combine(Double(value))
        case .number(let value): hasher.combine(2); hasher.combine(value)
        case .string(let value): hasher.combine(3); hasher.combine(value)
        case .array(let value): hasher.combine(4); hasher.combine(value)
        case .object(let value): hasher.combine(5); hasher.combine(value)
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "不是合法的 JSON 值"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
