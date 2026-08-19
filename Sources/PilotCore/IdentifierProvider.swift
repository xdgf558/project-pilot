import Foundation

/// 标识符来源。
///
/// v0.2 §2 规定 Project、Task、Job、Event 等一律用 UUID 主键。直接调 `UUID()`
/// 会让测试断言无法写死,失败信息也没法读 —— 一串随机十六进制看不出是第几个对象。
/// 注入本协议后,测试里换成 `DeterministicIdentifierProvider`,
/// 拿到的是 `...0001`、`...0002` 这样可读且可复现的值。
public protocol IdentifierProvider: Sendable {
    /// 产生一个新标识符。每次调用都必须返回不同的值。
    func makeIdentifier() -> UUID
}

/// 生产用实现:随机 UUID。
public struct RandomIdentifierProvider: IdentifierProvider {
    public init() {}

    public func makeIdentifier() -> UUID { UUID() }
}
