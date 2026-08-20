import Foundation

/// `DecodingError` 的大类,用于把断言收紧到具体分支。
///
/// `#expect(throws: DecodingError.self)` 只断言到「是个解码错误」,
/// 而错误映射从 `.dataCorrupted` 改成 `.typeMismatch` 时它照样绿 ——
/// 那正是执行器规则第 4 节说的弱断言。
///
/// 直接比较 `DecodingError` 值不现实:关联值里带着 `CodingPath` 和
/// `Context`,构造一个用来比较的期望值比被测代码还长。比较大类是
/// 成本与鉴别力的平衡点 —— 它能区分「字段缺了」「类型不对」「值非法」,
/// 而这三者对应完全不同的用户可见错误信息。
public enum DecodingErrorKind: String, Sendable, CustomStringConvertible {
    case dataCorrupted
    case keyNotFound
    case typeMismatch
    case valueNotFound
    /// 抛了非 `DecodingError` 的东西。
    case notADecodingError
    /// 根本没抛。
    case didNotThrow

    public var description: String { rawValue }
}

/// 跑一段可能抛错的代码,返回它抛出的 `DecodingError` 属于哪一类。
public func decodingErrorKind(_ body: () throws -> Void) -> DecodingErrorKind {
    do {
        try body()
        return .didNotThrow
    } catch let error as DecodingError {
        switch error {
        case .dataCorrupted: return .dataCorrupted
        case .keyNotFound: return .keyNotFound
        case .typeMismatch: return .typeMismatch
        case .valueNotFound: return .valueNotFound
        @unknown default: return .notADecodingError
        }
    } catch {
        return .notADecodingError
    }
}
