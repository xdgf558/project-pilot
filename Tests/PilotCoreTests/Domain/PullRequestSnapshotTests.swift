import Foundation
import Testing
import PilotCore
import PilotTestSupport

@Suite("PullRequestSnapshot")
struct PullRequestSnapshotTests {

    private func makeSnapshot(number: Int = 9) -> PullRequestSnapshot {
        PullRequestSnapshot(
            number: number,
            state: OpenEnum(.merged),
            isDraft: false,
            headRefName: "tools/mutation-probe",
            headRefOid: "24514bbcc2ac0d2dc0b75655eb4c92772b46abad",
            baseRefName: "main",
            mergeable: OpenEnum(.unknown),
            mergeStateStatus: OpenEnum(.unknown),
            reviewDecision: OpenEnum(ReviewDecision.none),
            statusCheckRollup: [
                StatusCheck(
                    name: "构建与测试",
                    status: OpenEnum(.completed),
                    conclusion: OpenEnum(.success),
                    startedAt: Date(timeIntervalSince1970: 1000),
                    completedAt: Date(timeIntervalSince1970: 1120),
                    detailsURL: "https://github.com/xdgf558/project-pilot/actions/runs/1",
                    workflowName: "CI"
                )
            ],
            mergedAt: Date(timeIntervalSince1970: 2000),
            closedAt: Date(timeIntervalSince1970: 2000),
            updatedAt: Date(timeIntervalSince1970: 2015)
        )
    }

    @Test("往返相等")
    func roundTrips() throws {
        let original = makeSnapshot()
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(original)
        #expect(try CanonicalJSON.makeDecoder().decode(PullRequestSnapshot.self, from: data) == original)
    }

    @Test("未合并的 PR 没有 mergedAt / closedAt")
    func openPullRequestHasNoTerminalDates() throws {
        var snapshot = makeSnapshot()
        snapshot.state = OpenEnum(.open)
        snapshot.mergedAt = nil
        snapshot.closedAt = nil
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(snapshot)
        let decoded = try CanonicalJSON.makeDecoder().decode(PullRequestSnapshot.self, from: data)
        #expect(decoded.mergedAt == nil)
        #expect(decoded.closedAt == nil)
    }

    @Test("GitHub 新增取值时快照仍然读得出来")
    func survivesUnknownUpstreamValues() throws {
        var snapshot = makeSnapshot()
        snapshot.mergeStateStatus = OpenEnum(rawValue: "SOME_NEW_STATE")
        snapshot.state = OpenEnum(rawValue: "ARCHIVED")

        let data = try CanonicalJSON.makeSnapshotEncoder().encode(snapshot)
        let decoded = try CanonicalJSON.makeDecoder().decode(PullRequestSnapshot.self, from: data)

        // 这一条是整个开放枚举设计的验收:不认识不等于读不了。
        #expect(decoded.mergeStateStatus.rawValue == "SOME_NEW_STATE")
        #expect(decoded.mergeStateStatus.isUnrecognized)
        #expect(decoded.state.rawValue == "ARCHIVED")
    }

    @Test("同步能力警告默认为空,有内容时往返")
    func syncWarningsRoundTrip() throws {
        var snapshot = makeSnapshot()
        #expect(snapshot.syncCapabilityWarnings.isEmpty)
        snapshot.syncCapabilityWarnings = ["gh 版本过低,拿不到 statusCheckRollup"]
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(snapshot)
        #expect(try CanonicalJSON.makeDecoder()
            .decode(PullRequestSnapshot.self, from: data).syncCapabilityWarnings.count == 1)
    }

    @Test("PR 编号小于 1 解码失败")
    func rejectsInvalidNumber() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeSnapshot())
        let broken = try JSONMutation.replacing(data, key: "number", with: 0)
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(PullRequestSnapshot.self, from: broken)
        } == .dataCorrupted)
    }

    @Test("headRefOid 缺失时解码失败")
    func rejectsMissingHeadOid() throws {
        // headRefOid 是整个合并安全体系的支点,不能缺。
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeSnapshot())
        let broken = try JSONMutation.removing(data, key: "headRefOid")
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(PullRequestSnapshot.self, from: broken)
        } == .keyNotFound)
    }

    @Test("isDraft 类型不符时报 typeMismatch")
    func rejectsWrongTypeForDraft() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeSnapshot())
        let broken = try JSONMutation.replacing(data, key: "isDraft", with: "false")
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(PullRequestSnapshot.self, from: broken)
        } == .typeMismatch)
    }
}
