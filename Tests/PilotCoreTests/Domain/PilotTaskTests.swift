import Foundation
import Testing
import PilotCore
import PilotTestSupport

@Suite("PilotTask 与 TaskStage")
struct PilotTaskTests {

    private func makeTask(
        displayNumber: Int = 12,
        title: String = "实现 JSON 快照仓库",
        stage: TaskStage = .backlog,
        pullRequestNumber: Int? = nil
    ) -> PilotTask {
        PilotTask(
            id: UUID(sequenceNumber: 1),
            projectId: UUID(sequenceNumber: 100),
            displayNumber: displayNumber,
            title: title,
            description: "原子写、唯一临时文件、未知字段保留",
            acceptanceCriteria: ["并发写不丢数据", "损坏文件不当空数据"],
            type: .code,
            completionPolicy: .mergedPR,
            stage: stage,
            blockers: [Blocker(code: .dependencyNotCompleted, message: "依赖 #3 未完成",
                               occurredAt: Date(timeIntervalSince1970: 500))],
            dependencyIds: [UUID(sequenceNumber: 3)],
            priority: 7,
            executorPreference: .claude,
            pullRequestNumber: pullRequestNumber,
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000)
        )
    }

    @Test("往返相等")
    func roundTrips() throws {
        let original = makeTask(pullRequestNumber: 42)
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(original)
        #expect(try CanonicalJSON.makeDecoder().decode(PilotTask.self, from: data) == original)
    }

    @Test("可选字段为空时也能往返")
    func roundTripsWithoutOptionals() throws {
        let minimal = PilotTask(
            id: UUID(sequenceNumber: 1), projectId: UUID(sequenceNumber: 2),
            displayNumber: 1, title: "最小任务",
            type: .manual, completionPolicy: .manualConfirmation,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(minimal)
        let decoded = try CanonicalJSON.makeDecoder().decode(PilotTask.self, from: data)
        #expect(decoded == minimal)
        #expect(decoded.executorPreference == nil)
        #expect(decoded.activeJobId == nil)
        #expect(decoded.pullRequestNumber == nil)
    }

    @Test("displayNumber 小于 1 时解码失败")
    func rejectsInvalidDisplayNumber() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeTask())
        let broken = try JSONMutation.replacing(data, key: "displayNumber", with: 0)
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(PilotTask.self, from: broken)
        } == .dataCorrupted)
    }

    @Test("空标题解码失败")
    func rejectsEmptyTitle() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeTask())
        let broken = try JSONMutation.replacing(data, key: "title", with: "")
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(PilotTask.self, from: broken)
        } == .dataCorrupted)
    }

    @Test("PR 编号小于 1 时解码失败")
    func rejectsInvalidPullRequestNumber() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeTask(pullRequestNumber: 42))
        let broken = try JSONMutation.replacing(data, key: "pullRequestNumber", with: 0)
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(PilotTask.self, from: broken)
        } == .dataCorrupted)
    }

    @Test("displayNumber 类型不符时报 typeMismatch")
    func rejectsWrongTypeForDisplayNumber() throws {
        // 正交对照:确认实现不是把所有失败都返回成 dataCorrupted。
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeTask())
        let broken = try JSONMutation.replacing(data, key: "displayNumber", with: "12")
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(PilotTask.self, from: broken)
        } == .typeMismatch)
    }

    @Test("缺字段时报 keyNotFound")
    func rejectsMissingField() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeTask())
        let broken = try JSONMutation.removing(data, key: "stage")
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(PilotTask.self, from: broken)
        } == .keyNotFound)
    }

    // MARK: - TaskStage

    @Test("approved 不是终态,completed 和 canceled 才是")
    func terminalStages() {
        // v0.2 §6.2 把「approved 不等于完成」列为必须移植的历史规则之首。
        // mergedPR 策略下,只有 GitHub 确认合并才能进 completed。
        #expect(TaskStage.approved.isTerminal == false)
        #expect(TaskStage.completed.isTerminal)
        #expect(TaskStage.canceled.isTerminal)
        for stage in [TaskStage.backlog, .ready, .queued, .implementing, .review] {
            #expect(stage.isTerminal == false, "\(stage.rawValue)")
        }
    }

    @Test("未知枚举值解码失败", arguments: [
        ("stage", "shipped"), ("type", "chore"),
        ("completionPolicy", "whenever"), ("executorPreference", "gemini"),
    ])
    func rejectsUnknownEnumValue(_ key: String, _ unknown: String) throws {
        // 未知值不能被当成某个已知值,也不能被忽略 —— 前者会让任务
        // 显示成错误的阶段,后者会让它凭空消失。
        // BlockerCode 与 SchedulerMode 已有同类用例,这里补齐其余四个家族。
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeTask(pullRequestNumber: 1))
        let broken = try JSONMutation.replacing(data, key: key, with: unknown)
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(PilotTask.self, from: broken)
        } == .dataCorrupted, "\(key)=\(unknown)")
    }

    @Test("枚举 raw value 写死")
    func rawValuesArePinned() {
        // raw value 就是落盘格式,改 case 名等于改数据格式。
        #expect(Set(TaskStage.allCases.map(\.rawValue)) == [
            "backlog", "ready", "queued", "implementing",
            "review", "approved", "completed", "canceled",
        ])
        #expect(Set(TaskType.allCases.map(\.rawValue)) == ["code", "research", "manual", "review"])
        #expect(Set(CompletionPolicy.allCases.map(\.rawValue)) == [
            "mergedPR", "manualConfirmation", "artifactProduced",
        ])
        #expect(Set(ExecutorPreference.allCases.map(\.rawValue)) == [
            "codex", "claude", "projectDefault",
        ])
    }
}
