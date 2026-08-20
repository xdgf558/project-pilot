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

    @Test("六个上游枚举的 raw value 全部写死")
    func rawValuesArePinned() {
        // 这些是和 GitHub 的接口约定。**拼错了不会报错**,只会让那个取值
        // 永远落进「未知」分支 —— 系统看起来在工作,判断却一直是错的。
        // 这是开放枚举的代价:它对未知值宽容,所以拼写错误不会浮出来。
        //
        // 原来这条是个参数化测试,其中一个条目落到 default: break ——
        // 一个 #expect 都没有,永远不可能红。空断言比没有断言更坏,
        // 因为它看起来像覆盖了。改成逐个直写。
        #expect(Set(PullRequestState.allCases.map(\.rawValue))
                == ["OPEN", "CLOSED", "MERGED"])
        #expect(Set(MergeableState.allCases.map(\.rawValue))
                == ["MERGEABLE", "CONFLICTING", "UNKNOWN"])
        #expect(Set(MergeStateStatus.allCases.map(\.rawValue))
                == ["BEHIND", "BLOCKED", "CLEAN", "DIRTY", "DRAFT",
                    "HAS_HOOKS", "UNSTABLE", "UNKNOWN"])
        #expect(Set(ReviewDecision.allCases.map(\.rawValue))
                == ["APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", ""])
        #expect(Set(CheckStatus.allCases.map(\.rawValue))
                == ["QUEUED", "IN_PROGRESS", "COMPLETED", "WAITING", "PENDING", "REQUESTED"])
        #expect(Set(CheckConclusion.allCases.map(\.rawValue))
                == ["SUCCESS", "FAILURE", "NEUTRAL", "CANCELLED", "TIMED_OUT",
                    "ACTION_REQUIRED", "SKIPPED", "STALE", "STARTUP_FAILURE"])
    }

    @Test("每个上游枚举都能吞下未知值", arguments: [
        "SOMETHING_NEW", "", "lowercase", "带中文的值",
    ])
    func everyUpstreamEnumTolerates(_ raw: String) {
        // 逐个确认,不是只对某一个成立 —— 漏掉一个,GitHub 在那个字段上
        // 新增取值时,已经存下来的快照就读不出来了。
        #expect(OpenEnum<PullRequestState>(rawValue: raw).rawValue == raw)
        #expect(OpenEnum<MergeableState>(rawValue: raw).rawValue == raw)
        #expect(OpenEnum<MergeStateStatus>(rawValue: raw).rawValue == raw)
        #expect(OpenEnum<ReviewDecision>(rawValue: raw).rawValue == raw)
        #expect(OpenEnum<CheckStatus>(rawValue: raw).rawValue == raw)
        #expect(OpenEnum<CheckConclusion>(rawValue: raw).rawValue == raw)
    }
}
