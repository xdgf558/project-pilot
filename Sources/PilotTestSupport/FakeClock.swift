import Foundation
import PilotCore

/// 可控时钟。
///
/// 时间不会自己走 —— 只有测试调用 `advance(by:)` 或 `set(to:)` 才变。
/// 这样「租约 30 秒后过期」这类断言就不需要真的等 30 秒,
/// 也不会因为 CI 机器慢而随机失败。
///
/// 默认起点是 Unix 纪元 0,失败信息里出现 `1970-01-01` 一眼就知道
/// 这是假时钟,不是漏注入了真时钟。
public final class FakeClock: TimeSource, @unchecked Sendable {
    // @unchecked 是有意的:内部可变状态由 lock 保护。
    // 测试常常从多个任务并发读时间,不能用非线程安全的实现糊弄过去。
    private let lock = NSLock()
    private var current: Date

    public init(now: Date = Date(timeIntervalSince1970: 0)) {
        self.current = now
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// 前进指定秒数。允许负数(用于构造「时钟回拨」场景)。
    public func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }

    /// 跳到指定时刻。
    public func set(to date: Date) {
        lock.lock()
        defer { lock.unlock() }
        current = date
    }
}
