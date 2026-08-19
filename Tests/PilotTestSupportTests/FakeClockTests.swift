import Foundation
import Testing
@testable import PilotCore
@testable import PilotTestSupport

@Suite("FakeClock")
struct FakeClockTests {

    @Test("默认起点是 Unix 纪元")
    func defaultsToEpoch() {
        #expect(FakeClock().now == Date(timeIntervalSince1970: 0))
    }

    @Test("时间不会自己走")
    func timeDoesNotAdvanceOnItsOwn() {
        let clock = FakeClock()
        let first = clock.now
        let second = clock.now
        // 这是整个假时钟的意义:不调用 advance,读多少次都是同一时刻。
        #expect(first == second)
    }

    @Test("advance 前进指定秒数")
    func advanceMovesForward() {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 1000))
        clock.advance(by: 30)
        #expect(clock.now == Date(timeIntervalSince1970: 1030))
    }

    @Test("advance 接受负数以构造时钟回拨")
    func advanceAcceptsNegative() {
        // 真实世界里 NTP 校正、用户改系统时间都会让时钟回拨。
        // 租约与退避逻辑必须能被这样测。
        let clock = FakeClock(now: Date(timeIntervalSince1970: 1000))
        clock.advance(by: -100)
        #expect(clock.now == Date(timeIntervalSince1970: 900))
    }

    @Test("set 跳到指定时刻")
    func setJumpsToDate() {
        let clock = FakeClock()
        let target = Date(timeIntervalSince1970: 1_700_000_000)
        clock.set(to: target)
        #expect(clock.now == target)
    }

    @Test("可当作 TimeSource 注入")
    func conformsToTimeSource() {
        func stamp(using source: any TimeSource) -> Date { source.now }
        let clock = FakeClock(now: Date(timeIntervalSince1970: 42))
        #expect(stamp(using: clock) == Date(timeIntervalSince1970: 42))
    }

    @Test("并发读写不会数据竞争")
    func concurrentAccessIsSafe() async {
        let clock = FakeClock()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { clock.advance(by: 1) }
                group.addTask { _ = clock.now }
            }
        }
        // 100 次各加 1 秒,必须不多不少。丢失更新就说明锁没起作用。
        #expect(clock.now == Date(timeIntervalSince1970: 100))
    }
}
