import Foundation

/// 一个「认识的值给类型安全,不认识的原样保留」的枚举。
///
/// ## 什么时候该用它,什么时候不该
///
/// 默认用严格的 Swift 枚举 —— `TaskStage`、`BlockerCode`、`JobStatus` 都是。
/// 那些值由我们定义,出现未知值意味着数据损坏,应当报错。
///
/// **只有两种情况该用开放枚举,而且理由不同:**
///
/// **一、值由别的系统定义。** `mergeable`、`mergeStateStatus`、`reviewDecision`
/// 是 GitHub 定的。严格枚举下,GitHub 新增一个值就让已经存下来的快照解不出来 ——
/// 不是行为退化,是自己的数据读不了了。而这类新增确实会发生。
/// 别人定义的值,我们没有资格说它非法。
///
/// **二、值写进了只追加的事件日志。** `Event` 的 entityType、eventType、actor
/// 属于这一类。事件日志是不可变的审计记录,**几年前的事件必须永远读得出来**。
/// 严格枚举下,哪天退掉一个事件类型,历史事件就成了解不开的数据 ——
/// 而为了一次改名去重写审计日志,比留着一个旧字符串糟得多。
///
/// 两种情况的共同点是:**值的合法性不由当前这份代码说了算。**
///
/// 用法:
///
/// ```swift
/// enum Mergeable: String, OpenEnumValue {
///     case mergeable = "MERGEABLE", conflicting = "CONFLICTING"
/// }
/// let value = OpenEnum<Mergeable>(rawValue: "SOMETHING_NEW")   // 不失败
/// value.known    // nil —— 我们不认识
/// value.rawValue // "SOMETHING_NEW" —— 但不会丢
/// ```
///
public protocol OpenEnumValue: RawRepresentable, Sendable, Hashable, CaseIterable
where RawValue == String {}

/// 包着一个上游值:认识的归到 `known`,不认识的原样留在 `rawValue`。
public struct OpenEnum<Value: OpenEnumValue>: Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ value: Value) {
        self.rawValue = value.rawValue
    }

    /// 我们认识的那个值。上游给了新值时为 nil。
    public var known: Value? { Value(rawValue: rawValue) }

    /// 上游给了我们不认识的值。
    ///
    /// 这不是错误 —— 按 v0.2 P4-03「安全降级」,遇到不认识的状态应当
    /// 继续只读同步并把不确定性显式呈现,而不是拒绝整份数据。
    public var isUnrecognized: Bool { known == nil }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension OpenEnum: CustomStringConvertible {
    public var description: String {
        isUnrecognized ? "\(rawValue)(未知)" : rawValue
    }
}
