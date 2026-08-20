import Foundation

/// 权威数据的 JSON 编解码规则。
///
/// 所有落盘的数据都必须走这里,不要各处自己 new 一个 `JSONEncoder` ——
/// 编码规则不一致会让校验和失效,而失效的方式是静默的。
///
/// ## 两条规则都是实测逼出来的,不是偏好
///
/// **必须 `.sortedKeys`。** 不加的话,同样的数据编出来的字节不稳定:
///
/// | 场景 | 8 次编码得到几种结果 |
/// |---|---|
/// | 跨进程 | 多种 |
/// | 同进程,每次新建 encoder | 1 种 |
/// | **同进程,复用同一个 encoder 实例** | **8 种,每次都不同** |
///
/// 最糟的那种恰好是最自然的用法 —— 建一次反复用。
/// 后果是校验和无法成立,而且每次写入都产生一个内容没变的假 diff。
///
/// 注意这不是「跨启动才有」的问题。所以本类型的工厂方法每次返回新实例,
/// **但不要依赖这一点** —— 真正的保证来自 `.sortedKeys`。
///
/// **时间戳用默认的 `deferredToDate`(自参考日期起的秒数,`Double`),
/// 不用 ISO8601。** 实测 `.iso8601` 丢掉全部亚秒精度(往返差 0.123456 秒);
/// 即使用带 `.withFractionalSeconds` 的自定义格式,也只到毫秒(往返差 0.00046 秒)。
/// 默认的 `Double` 编码往返精确。
///
/// 代价是原始文件里的时间戳人读不懂。这个代价是主动选的:
/// 精度损失一旦发生就不可逆,而可读性可以由 P1-11 的恢复工具补上。
public enum CanonicalJSON {

    /// 快照用。`prettyPrinted` 让损坏时能定位到行,也让 diff 可读。
    public static func makeSnapshotEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    /// 事件日志用。NDJSON 要求一条事件占一行,所以不能 prettyPrinted。
    public static func makeEventEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}
