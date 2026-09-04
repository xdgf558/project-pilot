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
    case integer(Int64)
    /// 非整数的数字。JSON 不区分 42 与 42.0 的类型,
    /// 但字节表示不同:整数字面量解码为 `.integer`,带小数点/指数的解码为
    /// `.number`,各自原样往返 —— 两者不相等是有意的。
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
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
