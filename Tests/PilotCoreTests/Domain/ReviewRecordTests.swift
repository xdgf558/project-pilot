import Foundation
import Testing
import PilotCore
import PilotTestSupport

@Suite("ReviewRecord")
struct ReviewRecordTests {

    private let headSHA = "24514bbcc2ac0d2dc0b75655eb4c92772b46abad"

    private func makeRecord(
        verdict: ReviewVerdict = .approved,
        source: ReviewSource = .automated,
        unreviewedFiles: [String] = []
    ) -> ReviewRecord {
        ReviewRecord(
            id: UUID(sequenceNumber: 1),
            taskId: UUID(sequenceNumber: 12),
            pullRequestNumber: 9,
            verdict: verdict,
            source: source,
            headSHA: headSHA,
            baseSHA: "c300c19aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            findings: [
                ReviewFinding(file: "Sources/X.swift", line: 42,
                              message: "这里没有处理空数组", isBlocking: true)
            ],
            reviewedFiles: ["Sources/X.swift", "Tests/XTests.swift"],
            unreviewedFiles: unreviewedFiles,
            model: "claude-opus-5",
            toolVersion: "2.0.1",
            promptVersion: "review-v3",
            createdAt: Date(timeIntervalSince1970: 1000)
        )
    }

    @Test("往返相等")
    func roundTrips() throws {
        let original = makeRecord()
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(original)
        #expect(try CanonicalJSON.makeDecoder().decode(ReviewRecord.self, from: data) == original)
    }

    @Test("人工审查没有模型信息也能往返")
    func humanReviewRoundTrips() throws {
        let human = ReviewRecord(
            id: UUID(sequenceNumber: 2), taskId: UUID(sequenceNumber: 12),
            pullRequestNumber: 9, verdict: .approved, source: .human,
            headSHA: headSHA, baseSHA: "abc",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(human)
        let decoded = try CanonicalJSON.makeDecoder().decode(ReviewRecord.self, from: data)
        #expect(decoded == human)
        #expect(decoded.model == nil)
        #expect(decoded.promptVersion == nil)
    }

    // MARK: - 「approve 之后又推了新代码」

    @Test("head SHA 一变,审查立刻失效")
    func staleWhenHeadMoves() {
        // v0.2 §6.2 把这条列为必须移植的历史业务规则之一。
        let record = makeRecord()
        #expect(record.isStale(currentHeadSHA: headSHA) == false)
        #expect(record.isStale(currentHeadSHA: "deadbeef"))
    }

    @Test("失效判断只看 SHA,不看时间")
    func stalenessIgnoresTime() {
        // 时间会因为时钟回拨、时区、或两次推送挨得太近而骗人。SHA 不会。
        // 一条「更晚创建」的审查,只要绑的是旧 SHA,照样失效。
        let record = makeRecord()
        #expect(record.isStale(currentHeadSHA: "a-newer-commit"))
    }

    // MARK: - 合并闸门的三个条件

    @Test("三个条件同时满足才能用于合并")
    func mergeGateNeedsAllThree() {
        #expect(makeRecord().canSatisfyMergeGate(currentHeadSHA: headSHA))
    }

    @Test("结论不是 approved 就不行", arguments: [ReviewVerdict.changesRequested, .commented])
    func nonApprovedCannotSatisfy(_ verdict: ReviewVerdict) {
        // commented 尤其要挡住:GitHub 拒绝作者自审时会降级到它(P4-09),
        // 若它能满足闸门,自审就等于绕过了审查。
        #expect(makeRecord(verdict: verdict).canSatisfyMergeGate(currentHeadSHA: headSHA) == false)
        #expect(verdict.canSatisfyMergeGate == false)
    }

    @Test("有未审查文件就不行")
    func incompleteCoverageCannotSatisfy() {
        // 覆盖不全的自动审查说明不了整个改动是安全的(v0.2 §2.6、P10-09)。
        let record = makeRecord(unreviewedFiles: ["Sources/Untouched.swift"])
        #expect(record.hasFullCoverage == false)
        #expect(record.canSatisfyMergeGate(currentHeadSHA: headSHA) == false)
    }

    @Test("已失效就不行")
    func staleCannotSatisfy() {
        #expect(makeRecord().canSatisfyMergeGate(currentHeadSHA: "moved-on") == false)
    }

    @Test("人工 approve 同样受三个条件约束")
    func humanApprovalIsNotExempt() {
        // 人点了同意也不能绕过失效和覆盖检查 —— 他看的是旧代码。
        let human = makeRecord(source: .human, unreviewedFiles: ["a.swift"])
        #expect(human.canSatisfyMergeGate(currentHeadSHA: headSHA) == false)
    }

    // MARK: - 校验

    @Test("空 headSHA 解码失败")
    func rejectsEmptyHeadSHA() throws {
        // 没绑 SHA 的审查记录永远无法判断是否失效 —— 它会永久有效,
        // 那正是「approve 后推新代码」要防的漏洞。
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeRecord())
        let broken = try JSONMutation.replacing(data, key: "headSHA", with: "")
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(ReviewRecord.self, from: broken)
        } == .dataCorrupted)
    }

    @Test("PR 编号小于 1 解码失败")
    func rejectsInvalidPullRequestNumber() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeRecord())
        let broken = try JSONMutation.replacing(data, key: "pullRequestNumber", with: 0)
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(ReviewRecord.self, from: broken)
        } == .dataCorrupted)
    }

    @Test("空的发现说明解码失败")
    func rejectsEmptyFindingMessage() {
        let bad = """
        {"message":"","isBlocking":true}
        """
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(ReviewFinding.self, from: Data(bad.utf8))
        } == .dataCorrupted)
    }

    @Test("未知的结论或来源解码失败", arguments: [("verdict", "maybe"), ("source", "committee")])
    func rejectsUnknownEnum(_ key: String, _ unknown: String) throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeRecord())
        let broken = try JSONMutation.replacing(data, key: key, with: unknown)
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(ReviewRecord.self, from: broken)
        } == .dataCorrupted, "\(key)=\(unknown)")
    }

    @Test("枚举 raw value 写死")
    func rawValuesArePinned() {
        #expect(Set(ReviewVerdict.allCases.map(\.rawValue))
                == ["approved", "changesRequested", "commented"])
        #expect(Set(ReviewSource.allCases.map(\.rawValue)) == ["human", "automated"])
    }
}
