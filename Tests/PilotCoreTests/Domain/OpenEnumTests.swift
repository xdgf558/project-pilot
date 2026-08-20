import Foundation
import Testing
import PilotCore
import PilotTestSupport

@Suite("OpenEnum")
struct OpenEnumTests {

    @Test("认识的值给出 known")
    func recognizesKnownValue() {
        let value = OpenEnum<MergeableState>(rawValue: "MERGEABLE")
        #expect(value.known == .mergeable)
        #expect(value.isUnrecognized == false)
    }

    @Test("不认识的值不失败,原样留着")
    func preservesUnknownValue() {
        // 这是整个类型存在的理由。GitHub 新增一个取值时,
        // 严格枚举会让已经存下来的快照解不出来 —— 不是行为退化,
        // 是自己的数据读不了了。
        let value = OpenEnum<MergeableState>(rawValue: "SOMETHING_GITHUB_ADDED")
        #expect(value.known == nil)
        #expect(value.isUnrecognized)
        #expect(value.rawValue == "SOMETHING_GITHUB_ADDED")
    }

    @Test("未知值往返不丢")
    func unknownValueRoundTrips() throws {
        let original = OpenEnum<MergeStateStatus>(rawValue: "FUTURE_STATE")
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(original)
        let decoded = try CanonicalJSON.makeDecoder()
            .decode(OpenEnum<MergeStateStatus>.self, from: data)
        #expect(decoded == original)
        #expect(decoded.rawValue == "FUTURE_STATE")
    }

    @Test("编码成裸字符串,不套一层对象")
    func encodesAsBareString() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder()
            .encode(OpenEnum<PullRequestState>(.open))
        // 存进 JSON 的必须就是上游给的那个字符串 —— 否则和 gh 的输出对不上,
        // 人工比对和 fixture 录制都会变麻烦。
        #expect(String(data: data, encoding: .utf8) == "\"OPEN\"")
    }

    @Test("空字符串是合法值,不是缺失")
    func emptyStringIsAValue() throws {
        // gh 在没有审查结论时返回空字符串而不是 null(已实测)。
        // 按 String? 建模会把空串当成「有值但内容为空」,判断就错了。
        let value = OpenEnum<ReviewDecision>(rawValue: "")
        #expect(value.known == ReviewDecision.none)
        #expect(value.isUnrecognized == false)
    }

    @Test("非字符串解码失败")
    func rejectsNonString() {
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder()
                .decode(OpenEnum<PullRequestState>.self, from: Data("123".utf8))
        } == .typeMismatch)
    }

    @Test("上游枚举的 raw value 写死", arguments: [
        ("PullRequestState", ["OPEN", "CLOSED", "MERGED"]),
        ("MergeableState", ["MERGEABLE", "CONFLICTING", "UNKNOWN"]),
        ("ReviewSourceUnused", []),
    ])
    func rawValuesArePinned(_ name: String, _ expected: [String]) {
        // 这些是和 GitHub 的接口约定,拼错了不会报错,只会永远判成「未知」。
        switch name {
        case "PullRequestState":
            #expect(Set(PullRequestState.allCases.map(\.rawValue)) == Set(expected))
        case "MergeableState":
            #expect(Set(MergeableState.allCases.map(\.rawValue)) == Set(expected))
        default:
            break
        }
    }
}
