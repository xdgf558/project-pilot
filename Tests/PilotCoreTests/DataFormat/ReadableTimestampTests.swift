import Foundation
import Testing
import PilotCore

@Suite("ReadableTimestamp")
struct ReadableTimestampTests {

    @Test("Unix 纪元零点是 1970-01-01T00:00:00.000Z")
    func formatsEpoch() {
        #expect(ReadableTimestamp.format(Date(timeIntervalSince1970: 0))
                == "1970-01-01T00:00:00.000Z")
    }

    @Test("带小数秒的时刻保留到毫秒")
    func keepsMilliseconds() {
        #expect(ReadableTimestamp.format(Date(timeIntervalSince1970: 1000.5))
                == "1970-01-01T00:16:40.500Z")
    }

    @Test("同一时刻不论在哪个时区打开都是 UTC")
    func isAlwaysUTC() {
        // 回归:若误用本地时区,CI(UTC)和开发机(东八区)会对不上。
        let formatted = ReadableTimestamp.format(Date(timeIntervalSince1970: 1_577_836_800))
        #expect(formatted.hasSuffix("Z"))
        #expect(formatted.contains("+") == false)
        #expect(formatted == "2020-01-01T00:00:00.000Z")
    }
}
