import Foundation
import Testing
import PilotTestSupport

@Suite("JSONMutation")
struct JSONMutationTests {

    private let sample = Data("""
    {"name":"任务","count":7,"nested":{"a":1},"flag":true}
    """.utf8)

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("替换成同类型的值")
    func replacesSameType() throws {
        let result = try object(JSONMutation.replacing(sample, key: "count", with: 99))
        #expect(result["count"] as? Int == 99)
        #expect(result["name"] as? String == "任务")
    }

    @Test("替换成不同类型的值(用来触发 typeMismatch)")
    func replacesWithDifferentType() throws {
        let result = try object(JSONMutation.replacing(sample, key: "count", with: "不是数字"))
        #expect(result["count"] as? String == "不是数字")
    }

    @Test("删除键")
    func removesKey() throws {
        let result = try object(JSONMutation.removing(sample, key: "count"))
        #expect(result["count"] == nil)
        #expect(result.count == 3)
    }

    // MARK: - 这两条才是助手存在的价值

    @Test("替换不存在的键会抛错,而不是静默新增")
    func replacingMissingKeyThrows() {
        // 这是助手最重要的一条行为。若它静默新增,那么某个字段改名之后,
        // 所有针对它的失败用例都会变成「往 JSON 里塞一个没人读的键」,
        // 然后照常绿 —— 一整组错误路径测试静默失效。
        #expect(throws: JSONMutation.Failure.self) {
            _ = try JSONMutation.replacing(self.sample, key: "typoedKey", with: 1)
        }
    }

    @Test("删除不存在的键会抛错")
    func removingMissingKeyThrows() {
        #expect(throws: JSONMutation.Failure.self) {
            _ = try JSONMutation.removing(self.sample, key: "typoedKey")
        }
    }

    @Test("错误信息里列出现有的键")
    func failureListsAvailableKeys() {
        // 「找不到 xxx」帮不上忙,「找不到 xxx;现有的键:a, b, c」能一眼看出是拼错了。
        do {
            _ = try JSONMutation.replacing(sample, key: "cont", with: 1)
            Issue.record("应当抛错")
        } catch let failure as JSONMutation.Failure {
            let text = failure.description
            #expect(text.contains("cont"))
            #expect(text.contains("count"))
            #expect(text.contains("name"))
        } catch {
            Issue.record("抛了别的错误:\(error)")
        }
    }

    @Test("顶层不是对象时抛错")
    func rejectsNonObject() {
        #expect(throws: JSONMutation.Failure.self) {
            _ = try JSONMutation.replacing(Data("[1,2,3]".utf8), key: "a", with: 1)
        }
    }

    @Test("不动其他键")
    func leavesOtherKeysAlone() throws {
        let result = try object(JSONMutation.replacing(sample, key: "flag", with: false))
        #expect(result["flag"] as? Bool == false)
        #expect(result["name"] as? String == "任务")
        #expect(result["count"] as? Int == 7)
        #expect((result["nested"] as? [String: Any])?["a"] as? Int == 1)
    }
}
