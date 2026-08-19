import Foundation
import PilotCore

/// 可复现的标识符来源。
///
/// 按顺序产出 `00000000-0000-0000-0000-000000000001`、`...0002`……
/// 好处是测试断言可以写死,而且失败信息一眼看得出是第几个对象 ——
/// 随机 UUID 在这两点上都很糟。
public final class DeterministicIdentifierProvider: IdentifierProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt32

    /// - Parameter startingAt: 第一个标识符的序号,默认 1。
    ///   不同的起点可以让两个 provider 产出互不冲突的区间,
    ///   便于在同一个测试里区分「项目 A 造的对象」和「项目 B 造的对象」。
    public init(startingAt: UInt32 = 1) {
        self.counter = startingAt
    }

    public func makeIdentifier() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let value = counter
        counter += 1
        return UUID(sequenceNumber: value)
    }

    /// 下一个将要产出的序号。用于断言「一共造了几个对象」。
    public var nextSequenceNumber: UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return counter
    }
}

extension UUID {
    /// 由序号构造一个全零前缀的 UUID,便于阅读。
    package init(sequenceNumber: UInt32) {
        let bytes = withUnsafeBytes(of: sequenceNumber.bigEndian) { Array($0) }
        self.init(uuid: (
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            bytes[0], bytes[1], bytes[2], bytes[3]
        ))
    }
}
