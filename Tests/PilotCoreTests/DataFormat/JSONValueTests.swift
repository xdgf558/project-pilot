import Foundation
import Testing
import PilotCore

@Suite("JSONValue")
struct JSONValueTests {

    @Test("各种标量往返")
    func scalarsRoundTrip() throws {
        let cases: [JSONValue] = [
            .null, .bool(true), .bool(false),
            .integer(0), .number(-1.5), .number(0.1), .number(1e10),
            .number(42), .integer(9_007_199_254_740_993),
            .string(""), .string("中文与 emoji 🚀"),
        ]
        for value in cases {
            let data = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value, "\(value)")
        }
    }

    @Test("嵌套结构往返")
    func nestedRoundTrips() throws {
        let value = JSONValue.object([
            "tasks": .array([
                .object(["id": .integer(1), "done": .bool(false)]),
                .object(["id": .integer(2), "done": .bool(true), "note": .null]),
            ]),
            "meta": .object(["version": .string("v1")]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test("从任意 JSON 文本解析")
    func parsesArbitraryJSON() throws {
        let text = """
        {"a": [1, "two", null, {"b": false}], "c": 3.5}
        """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        #expect(value == .object([
            "a": .array([.integer(1), .string("two"), .null, .object(["b": .bool(false)])]),
            "c": .number(3.5),
        ]))
    }

    @Test("超出 Double 精度的整数原样往返")
    func bigIntegerRoundTripsExactly() throws {
        // 9007199254740993 = 2^53 + 1,Double 表示不了它。
        // 按 Double 存的旧设计在这里丢精度 → 重编码字节变了 →
        // 一份完好的未来版本快照会被仓库层误报损坏(P1-05 审查发现)。
        let value = JSONValue.integer(9_007_199_254_740_993)
        let data = try JSONEncoder().encode(value)
        #expect(String(data: data, encoding: .utf8) == "9007199254740993")
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }

    @Test("整数值的 .number 往返后与 .integer 值相等(值语义)")
    func numberWithIntegerValueSurvivesPersistence() throws {
        // 上一轮曾断言两者不等 —— 那基于「42 与 42.0 字节不同」,
        // 而本台编码器把整数值的 Double 写成整数字面量,字节根本没有差异;
        // 不等的只有 case 标签,却会让 payload 匹配 / 事件去重 / 重放断言
        // 被持久化的影子差异咬到(第二轮审查 P2)。改为值语义:
        let original = JSONValue.number(42)
        let data = try JSONEncoder().encode(original)          // 42
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == .integer(42))                        // case 变了
        #expect(decoded == original)                            // 但值相等
        #expect(decoded.hashValue == original.hashValue)        // 相等 ⇒ 同哈希

        // 跨 case 相等要求 Double 精确可逆 —— 两个不同的数不相等。
        #expect(JSONValue.integer(9_007_199_254_740_993)
                != JSONValue.number(9_007_199_254_740_992))
        #expect(JSONValue.number(42.5) != JSONValue.integer(42))
    }

    @Test("Set 去重按值语义工作")
    func setDeduplicatesByValue() {
        let set: Set<JSONValue> = [.integer(42), .number(42), .number(42.0), .bool(true)]
        // 42 的三种表示是同一个值。
        #expect(set.count == 2)
        #expect(set.contains(.integer(42)))
    }

    @Test("布尔不会被当成数字")
    func boolIsNotNumber() throws {
        // JSON 里 true 与 1 是不同的值。解码顺序若把 Bool 放在 Double 之后,
        // true 会被读成 1.0,写回去就变成数字 —— 一次静默的类型变形。
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8))
        #expect(value == .bool(true))
        #expect(value != .number(1))
        #expect(value != .integer(1))   // Int64 分支插进来之后,布尔也不能被它吃掉
    }
}
