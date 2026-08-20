import Foundation
import Testing
import PilotCore

@Suite("JSONValue")
struct JSONValueTests {

    @Test("各种标量往返")
    func scalarsRoundTrip() throws {
        let cases: [JSONValue] = [
            .null, .bool(true), .bool(false),
            .number(0), .number(-1.5), .number(1e10),
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
                .object(["id": .number(1), "done": .bool(false)]),
                .object(["id": .number(2), "done": .bool(true), "note": .null]),
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
            "a": .array([.number(1), .string("two"), .null, .object(["b": .bool(false)])]),
            "c": .number(3.5),
        ]))
    }

    @Test("布尔不会被当成数字")
    func boolIsNotNumber() throws {
        // JSON 里 true 与 1 是不同的值。解码顺序若把 Bool 放在 Double 之后,
        // true 会被读成 1.0,写回去就变成数字 —— 一次静默的类型变形。
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8))
        #expect(value == .bool(true))
        #expect(value != .number(1))
    }
}
