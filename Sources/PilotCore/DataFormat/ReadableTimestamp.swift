import Foundation

/// 把落盘用的 `Date` 收成人类能读的 UTC 时间。
///
/// P1-01 把时间戳写成 `deferredToDate` 的 Double,原始文件里是
/// `777292800.123456` 这种数。精度保住了,人读不懂。
/// 恢复工具(P1-11)的职责之一就是把这个数变回可核对的时刻。
///
/// 固定 UTC、固定到毫秒、固定 `Z` 后缀。不用本地时区 —— 同一份损坏
/// 在东京和在纽约打开,定位信息必须一样,否则两个人对不上。
public enum ReadableTimestamp: Sendable {
    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
