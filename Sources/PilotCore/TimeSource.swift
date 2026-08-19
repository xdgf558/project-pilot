import Foundation

/// 时间来源。
///
/// 领域逻辑不直接调用 `Date()` —— 那会让「事件时间戳」「租约过期」「审查失效」
/// 这类判断变得不可复现。所有需要「现在」的地方都注入 `TimeSource`,
/// 测试里换成 `FakeClock`(见 PilotTestSupport)。
///
/// 名字不叫 `Clock`,是为了避开 Swift 标准库同名协议 —— 那个管的是
/// 时长与休眠,这个管的是墙上时钟的时间戳,两回事。
public protocol TimeSource: Sendable {
    /// 当前时刻。
    var now: Date { get }
}

/// 生产用实现:真实系统时钟。
public struct SystemTimeSource: TimeSource {
    public init() {}

    public var now: Date { Date() }
}
