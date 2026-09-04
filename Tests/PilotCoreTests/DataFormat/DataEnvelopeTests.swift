import Foundation
import Testing
import PilotCore
import PilotTestSupport

@Suite("DataEnvelope")
struct DataEnvelopeTests {

    struct Payload: Codable, Sendable, Equatable {
        var name: String
        var count: Int
    }

    private func makeEnvelope(
        revision: Revision = Revision(3),
        payload: Payload = Payload(name: "任务表", count: 7)
    ) -> DataEnvelope<Payload> {
        DataEnvelope(
            revision: revision,
            lastEventSequence: 42,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.123456),
            updatedAt: Date(timeIntervalSince1970: 1_755_600_000.654321),
            checksum: Checksum(hashing: Data("任务表".utf8)),
            payload: payload
        )
    }

    // MARK: - 往返

    @Test("编码解码往返后完全相等")
    func roundTripsExactly() throws {
        let original = makeEnvelope()
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(original)
        let decoded = try CanonicalJSON.makeDecoder().decode(DataEnvelope<Payload>.self, from: data)
        #expect(decoded == original)
    }

    @Test("时间戳往返不丢精度")
    func timestampsSurviveExactly() throws {
        // 这一条单独立着,是因为它是选择编码策略的直接理由:
        // .iso8601 会把亚秒精度丢光(实测往返差 0.123456 秒),
        // 带 .withFractionalSeconds 也只到毫秒。默认的 Double 编码才精确。
        let original = makeEnvelope()
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(original)
        let decoded = try CanonicalJSON.makeDecoder().decode(DataEnvelope<Payload>.self, from: data)

        #expect(decoded.createdAt.timeIntervalSince1970 == original.createdAt.timeIntervalSince1970)
        #expect(decoded.updatedAt.timeIntervalSince1970 == original.updatedAt.timeIntervalSince1970)
    }

    @Test("往返后字节完全一致")
    func reEncodingIsByteStable() throws {
        // 校验和能成立的前提。若同一份数据两次编码字节不同,
        // 任何基于内容的校验都是假的 —— 而这正是不加 .sortedKeys 时的实际情况。
        let encoder = CanonicalJSON.makeSnapshotEncoder()
        let first = try encoder.encode(makeEnvelope())
        let decoded = try CanonicalJSON.makeDecoder().decode(DataEnvelope<Payload>.self, from: first)
        let second = try encoder.encode(decoded)
        #expect(first == second)
    }

    @Test("复用同一个 encoder 实例仍然字节稳定")
    func reusedEncoderStaysStable() throws {
        // 这条是审查发现的:不加 .sortedKeys 时,**复用同一个 encoder 实例**
        // 连续编码同一份数据,每次字节都不同(实测 8 次 8 种)。
        // 而「建一次 encoder 反复用」恰好是最自然的用法。
        //
        // 工厂方法每次返回新实例,但保证不能建立在那上面 —— 调用方完全可以
        // 自己持有一个反复用。真正的保证来自 .sortedKeys,这条测试盯的就是它。
        let encoder = CanonicalJSON.makeSnapshotEncoder()
        let envelope = makeEnvelope()
        let first = try encoder.encode(envelope)
        for _ in 0..<8 {
            #expect(try encoder.encode(envelope) == first)
        }
    }

    @Test("键按字典序输出")
    func keysAreSorted() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeEnvelope())
        let text = try #require(String(data: data, encoding: .utf8))
        let order = ["checksum", "createdAt", "lastEventSequence", "payload", "revision", "schemaVersion", "updatedAt"]
        let positions = order.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(positions.count == order.count)
        #expect(positions == positions.sorted())
    }

    // MARK: - 未知字段

    @Test("新版本加的字段在旧版本手里不会丢")
    func preservesFieldsFromNewerVersion() throws {
        // 具体场景:用户升级后新版本给文件加了字段,然后回退到旧版本跑了一次。
        // 旧版本读进来、写回去 —— 如果不保留,新字段永久消失,而且全程无报错。
        let fromNewerVersion = """
        {
          "schemaVersion": 1,
          "revision": 3,
          "lastEventSequence": 42,
          "createdAt": 1000.5,
          "updatedAt": 2000.5,
          "checksum": "0123456789abcdef",
          "payload": { "count": 7, "name": "任务表" },
          "futureFlag": true,
          "futureConfig": { "retries": 3, "labels": ["a", "b"] },
          "futureNote": null
        }
        """
        let decoded = try CanonicalJSON.makeDecoder()
            .decode(DataEnvelope<Payload>.self, from: Data(fromNewerVersion.utf8))

        #expect(decoded.unknownFields.count == 3)
        #expect(decoded.unknownFields["futureFlag"] == .bool(true))
        #expect(decoded.unknownFields["futureNote"] == .null)
        #expect(decoded.unknownFields["futureConfig"] == .object([
            "retries": .integer(3),
            "labels": .array([.string("a"), .string("b")]),
        ]))

        // 关键的一半:写回去之后它们还在,而且结构没变形。
        let reEncoded = try CanonicalJSON.makeSnapshotEncoder().encode(decoded)
        let again = try CanonicalJSON.makeDecoder()
            .decode(DataEnvelope<Payload>.self, from: reEncoded)
        #expect(again.unknownFields == decoded.unknownFields)
    }

    @Test("没有未知字段时不会凭空造出键")
    func doesNotInventKeys() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeEnvelope())
        let tree = try CanonicalJSON.makeDecoder().decode(JSONValue.self, from: data)
        guard case .object(let fields) = tree else {
            Issue.record("顶层应当是对象"); return
        }
        #expect(Set(fields.keys) == [
            "schemaVersion", "revision", "lastEventSequence",
            "createdAt", "updatedAt", "checksum", "payload",
        ])
    }

    // MARK: - 失败用例

    @Test("lastEventSequence 为负数时解码失败")
    func rejectsNegativeSequence() {
        let bad = """
        {"schemaVersion":1,"revision":3,"lastEventSequence":-1,"createdAt":0,
         "updatedAt":0,"checksum":"0123456789abcdef","payload":{"count":1,"name":"x"}}
        """
        // 收紧到具体分支:值非法是 .dataCorrupted,与「字段缺了」「类型不对」
        // 对应完全不同的用户可见信息,不能混为一谈。
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(DataEnvelope<Payload>.self, from: Data(bad.utf8))
        } == .dataCorrupted)
    }

    @Test("缺少必需字段时解码失败,而不是当作默认值")
    func rejectsMissingRequiredField() {
        // v0.2 §3 规则 10 的同一个原则:损坏的数据不能被静默当成合法的空数据。
        let bad = """
        {"schemaVersion":1,"revision":3,"createdAt":0,
         "updatedAt":0,"checksum":"0123456789abcdef","payload":{"count":1,"name":"x"}}
        """
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(DataEnvelope<Payload>.self, from: Data(bad.utf8))
        } == .keyNotFound)
    }

    @Test("payload 结构不符时解码失败")
    func rejectsMalformedPayload() {
        let bad = """
        {"schemaVersion":1,"revision":3,"lastEventSequence":0,"createdAt":0,
         "updatedAt":0,"checksum":"0123456789abcdef","payload":{"count":"不是数字","name":"x"}}
        """
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(DataEnvelope<Payload>.self, from: Data(bad.utf8))
        } == .typeMismatch)
    }
}
