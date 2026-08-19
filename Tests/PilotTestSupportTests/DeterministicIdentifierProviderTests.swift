import Foundation
import Testing
import PilotCore
import PilotTestSupport

@Suite("DeterministicIdentifierProvider")
struct DeterministicIdentifierProviderTests {

    @Test("按顺序产出可读的标识符")
    func producesReadableSequence() {
        let provider = DeterministicIdentifierProvider()
        // 失败信息里出现 ...0001 / ...0002,一眼看得出是第几个对象。
        #expect(provider.makeIdentifier().uuidString == "00000000-0000-0000-0000-000000000001")
        #expect(provider.makeIdentifier().uuidString == "00000000-0000-0000-0000-000000000002")
        #expect(provider.makeIdentifier().uuidString == "00000000-0000-0000-0000-000000000003")
    }

    @Test("可指定起点以区分不同来源")
    func honoursStartingPoint() {
        let projectA = DeterministicIdentifierProvider(startingAt: 1)
        let projectB = DeterministicIdentifierProvider(startingAt: 1000)
        // uuidString 用大写十六进制,1000 = 0x3E8。
        #expect(projectA.makeIdentifier().uuidString.hasSuffix("0001"))
        #expect(projectB.makeIdentifier().uuidString.hasSuffix("03E8"))
    }

    @Test("两个同起点的 provider 产出相同序列")
    func isReproducible() {
        let first = DeterministicIdentifierProvider()
        let second = DeterministicIdentifierProvider()
        // 可复现是全部意义所在:同一个测试重跑,ID 必须一样。
        #expect((0..<5).map { _ in first.makeIdentifier() }
                == (0..<5).map { _ in second.makeIdentifier() })
    }

    @Test("nextSequenceNumber 反映已产出数量")
    func exposesProgress() {
        let provider = DeterministicIdentifierProvider()
        _ = provider.makeIdentifier()
        _ = provider.makeIdentifier()
        #expect(provider.nextSequenceNumber == 3)
    }

    @Test("可当作 IdentifierProvider 注入")
    func conformsToIdentifierProvider() {
        func make(using provider: any IdentifierProvider) -> UUID { provider.makeIdentifier() }
        #expect(make(using: DeterministicIdentifierProvider()).uuidString.hasSuffix("0001"))
    }

    @Test("并发调用不产生重复")
    func concurrentCallsAreUnique() async {
        let provider = DeterministicIdentifierProvider()
        let identifiers = await withTaskGroup(of: UUID.self) { group -> Set<UUID> in
            for _ in 0..<200 { group.addTask { provider.makeIdentifier() } }
            var seen = Set<UUID>()
            for await id in group { seen.insert(id) }
            return seen
        }
        // 重复的主键会让 P1-12 的并发写测试出现假阳性 —— 必须一个不重。
        #expect(identifiers.count == 200)
        #expect(provider.nextSequenceNumber == 201)
    }
}
