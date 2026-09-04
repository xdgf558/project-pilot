import Foundation
import Testing
import PilotCore
import PilotTestSupport

// 转换表的形状经项目所有者 2026-09-03 确认(v0.2 §2.3 原文不在仓库)。
// 全矩阵逐对钉死:表里任何一条边被增删,这里的字面量必须跟着改 ——
// 那正是要的:业务规则的改动必须在 diff 里显形。见 ADR-0014。

@Suite("TaskStage 转换")
struct TaskStageTransitionTests {

    /// 期望的完整边表,与实现里的 legalTransitions 逐字对应。
    private static let expected: [TaskStage: Set<TaskStage>] = [
        .backlog: [.ready, .queued, .implementing, .review, .approved, .completed, .canceled],
        .ready: [.queued, .implementing, .review, .approved, .completed, .canceled],
        .queued: [.implementing, .review, .approved, .completed, .canceled],
        .implementing: [.review, .approved, .completed, .canceled],
        .review: [.approved, .completed, .canceled, .implementing],
        .approved: [.completed, .canceled],
        .completed: [],
        .canceled: [],
    ]

    @Test("边表全矩阵钉死")
    func matrixIsPinned() {
        #expect(TaskStage.legalTransitions == Self.expected)
        // 表必须是全函数:每个 case 都有条目,包括终态的空集。
        #expect(Set(TaskStage.legalTransitions.keys) == Set(TaskStage.allCases))
    }

    @Test("validate 与边表一致(全 64 对)", arguments: TaskStage.allCases)
    func validateAgreesWithTable(_ from: TaskStage) {
        for to in TaskStage.allCases {
            let allowed = Self.expected[from]!.contains(to)
            if from == to {
                #expect(throws: TransitionDenial.noStateChange(state: from.rawValue)) {
                    try TaskStageTransition.validate(TransitionRequest(from: from, to: to, source: .derived))
                }
            } else if allowed {
                #expect(throws: Never.self) {
                    try TaskStageTransition.validate(TransitionRequest(from: from, to: to, source: .derived))
                }
            } else if from.isTerminal {
                #expect(throws: TransitionDenial.leavingTerminalStage(state: from.rawValue)) {
                    try TaskStageTransition.validate(TransitionRequest(from: from, to: to, source: .derived))
                }
            } else {
                #expect(throws: TransitionDenial.edgeNotPermitted(from: from.rawValue, to: to.rawValue)) {
                    try TaskStageTransition.validate(TransitionRequest(from: from, to: to, source: .derived))
                }
            }
        }
    }

    @Test("后退唯一允许的边:review→implementing(审查打回重做)")
    func reviewCanGoBackToImplementing() throws {
        try TaskStageTransition.validate(
            TransitionRequest(from: .review, to: .implementing, source: .derived))
    }

    @Test("关键的后退边被拒,且拒绝原因各就各位")
    func backwardEdgesDenied() {
        // approved→review:批准后退回审查不在表里 —— 审批失效走 SHA 绑定(ReviewRecord.isStale),
        // 不靠 stage 后退表达。
        #expect(throws: TransitionDenial.edgeNotPermitted(from: "approved", to: "review")) {
            try TaskStageTransition.validate(TransitionRequest(from: .approved, to: .review, source: .derived))
        }
        // implementing→ready:需求变了应该取消重开,不是把做到一半的任务退回 ready。
        #expect(throws: TransitionDenial.edgeNotPermitted(from: "implementing", to: "ready")) {
            try TaskStageTransition.validate(TransitionRequest(from: .implementing, to: .ready, source: .derived))
        }
    }

    @Test("canceled 可从任何非终态进入,含跨级")
    func cancelFromAnyNonTerminal() throws {
        for from in [TaskStage.backlog, .queued, .review, .approved] {
            try TaskStageTransition.validate(
                TransitionRequest(from: from, to: .canceled, source: .derived))
        }
    }

    // MARK: - 手动路径与 reason

    @Test("手动改状态携带类型化 reason")
    func manualStageChangeCarriesTypedReason() throws {
        // reason 是 NonEmptyReason —— 空串在构造时就被拒(见 NonEmptyReasonTests),
        // 这里只需证明合法 reason 的手动路径走得通。
        try TaskStageTransition.validate(TransitionRequest(
            from: .review, to: .implementing,
            source: .manual(operation: .changeStage, reason: try NonEmptyReason("审查打回,重做"))))
    }

    @Test("派生路径不需要 reason")
    func derivedNeedsNoReason() throws {
        try TaskStageTransition.validate(
            TransitionRequest(from: .queued, to: .implementing, source: .derived))
    }
}

@Suite("JobStatus 转换")
struct JobStatusTransitionTests {

    private static let expected: [JobStatus: Set<JobStatus>] = [
        .queued: [.starting, .canceled],
        .starting: [.running, .failed, .canceling, .orphaned],
        .running: [.succeeded, .failed, .canceling, .orphaned],
        .canceling: [.canceled, .orphaned],
        .succeeded: [],
        .failed: [],
        .canceled: [],
        .orphaned: [],
    ]

    @Test("边表全矩阵钉死")
    func matrixIsPinned() {
        #expect(JobStatus.legalTransitions == Self.expected)
        #expect(Set(JobStatus.legalTransitions.keys) == Set(JobStatus.allCases))
    }

    @Test("validate 与边表一致(全 64 对)", arguments: JobStatus.allCases)
    func validateAgreesWithTable(_ from: JobStatus) {
        for to in JobStatus.allCases {
            let allowed = Self.expected[from]!.contains(to)
            if from == to {
                #expect(throws: TransitionDenial.noStateChange(state: from.rawValue)) {
                    try JobStatusTransition.validate(TransitionRequest(from: from, to: to, source: .derived))
                }
            } else if allowed {
                #expect(throws: Never.self) {
                    try JobStatusTransition.validate(TransitionRequest(from: from, to: to, source: .derived))
                }
            } else if from.isTerminal {
                #expect(throws: TransitionDenial.leavingTerminalStage(state: from.rawValue)) {
                    try JobStatusTransition.validate(TransitionRequest(from: from, to: to, source: .derived))
                }
            } else {
                #expect(throws: TransitionDenial.edgeNotPermitted(from: from.rawValue, to: to.rawValue)) {
                    try JobStatusTransition.validate(TransitionRequest(from: from, to: to, source: .derived))
                }
            }
        }
    }

    @Test("queued 取消不经过 canceling —— 没有进程可等")
    func queuedCancelsDirectly() throws {
        try JobStatusTransition.validate(
            TransitionRequest(from: .queued, to: .canceled, source: .derived))
        // 有进程的状态必须走 canceling:starting 直接 canceled 是跳过了「等进程退出」。
        #expect(throws: TransitionDenial.edgeNotPermitted(from: "starting", to: "canceled")) {
            try JobStatusTransition.validate(TransitionRequest(from: .starting, to: .canceled, source: .derived))
        }
    }

    @Test("orphaned 只从预期进程活着的状态进入")
    func orphanedOnlyFromLiveProcessStates() {
        #expect(Set(JobStatus.legalTransitions.filter { $0.value.contains(.orphaned) }.keys)
                == [.starting, .running, .canceling])
        // queued 没有进程,不存在「进程没了但结果不明」。
        #expect(JobStatus.legalTransitions[.queued]!.contains(.orphaned) == false)
    }

    @Test("手动取消作业是七种必须带 reason 的操作之一")
    func manualCancelCarriesTypedReason() throws {
        try JobStatusTransition.validate(TransitionRequest(
            from: .running, to: .canceling,
            source: .manual(operation: .cancelJob, reason: try NonEmptyReason("预算超限,用户叫停"))))
        // 空串的 reason 构造不出来 —— 强制发生在类型层,不是校验器运行期。
        #expect(throws: NonEmptyReasonError.self) {
            _ = try NonEmptyReason("")
        }
    }

    @Test("启动阶段已知失败:starting→failed(秒退不是结果不明)")
    func startupFailureHasAKnownEnding() throws {
        // 执行器起来后立刻以已知错误退出(FakeProcessRunner 的秒退场景),
        // 或者启动确认失败 —— 结果是「已知失败」,不能归到 orphaned(结果不明),
        // 也不能停在非终态。该边由 2026-09-03 审查补上。
        try JobStatusTransition.validate(
            TransitionRequest(from: .starting, to: .failed, source: .derived))
        // 对照:同样在 starting,进程没了但**不知道**为什么,才是 orphaned。
        try JobStatusTransition.validate(
            TransitionRequest(from: .starting, to: .orphaned, source: .derived))
    }

    @Test("失败的作业不能复活 —— 重试是新的 Job")
    func failedJobCannotRevive() {
        #expect(throws: TransitionDenial.leavingTerminalStage(state: "failed")) {
            try JobStatusTransition.validate(TransitionRequest(from: .failed, to: .running, source: .derived))
        }
    }
}

@Suite("领域对象上的转换入口")
struct DomainTransitionTests {

    private func makeTask(stage: TaskStage) -> PilotTask {
        PilotTask(id: UUID(sequenceNumber: 1), projectId: UUID(sequenceNumber: 100),
                  displayNumber: 1, title: "t", type: .code, completionPolicy: .mergedPR,
                  stage: stage, createdAt: Date(timeIntervalSince1970: 0),
                  updatedAt: Date(timeIntervalSince1970: 0))
    }

    private func makeJob(status: JobStatus) -> Job {
        Job(id: UUID(sequenceNumber: 1), projectId: UUID(sequenceNumber: 100),
            taskId: UUID(sequenceNumber: 12), executor: .codex, executorVersion: "1.0",
            authMode: .subscription, worktreePath: URL(fileURLWithPath: "/tmp/w"),
            branchName: "b", status: status)
    }

    @Test("合法转换改变状态")
    func legalTransitionChangesStage() throws {
        var task = makeTask(stage: .queued)
        try task.transition(to: .implementing, source: .derived)
        #expect(task.stage == .implementing)
    }

    @Test("非法转换抛错且状态不变 —— 不部分修改")
    func deniedTransitionLeavesStageAlone() {
        var task = makeTask(stage: .completed)
        #expect(throws: TransitionDenial.leavingTerminalStage(state: "completed")) {
            try task.transition(to: .review, source: .derived)
        }
        #expect(task.stage == .completed)
    }

    @Test("作业:合法取消改变状态,手动路径带类型化 reason")
    func jobTransitionHappyPath() throws {
        var job = makeJob(status: .running)
        try job.transition(to: .canceling,
                           source: .manual(operation: .cancelJob,
                                           reason: try NonEmptyReason("预算超限")))
        #expect(job.status == .canceling)
    }

    @Test("作业:非法转换抛错且状态不变")
    func deniedTransitionLeavesStatusAlone() {
        var job = makeJob(status: .queued)
        // 有进程的状态必须走 canceling,跳过它就是绕过「等进程退出」。
        #expect(throws: TransitionDenial.edgeNotPermitted(from: "queued", to: "failed")) {
            try job.transition(to: .failed, source: .derived)
        }
        #expect(job.status == .queued)
    }
}

@Suite("NonEmptyReason")
struct NonEmptyReasonTests {

    @Test("非空内容构造成功且原样保留")
    func keepsContent() throws {
        let reason = try NonEmptyReason("  审查打回,重做  ")
        // 只拒绝纯空白,不修剪内容 —— 修不算我的,原样留给事件。
        #expect(reason.rawValue == "  审查打回,重做  ")
        #expect(reason.description == "  审查打回,重做  ")
    }

    @Test("空串与纯空白构造失败", arguments: ["", " ", "\n\t ", "　"])
    func rejectsBlank(_ raw: String) {
        #expect(throws: NonEmptyReasonError.blank) {
            _ = try NonEmptyReason(raw)
        }
    }

    @Test("往返相等")
    func roundTrips() throws {
        let original = try NonEmptyReason("依赖 #3 已完成")
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(original)
        #expect(try CanonicalJSON.makeDecoder().decode(NonEmptyReason.self, from: data) == original)
    }

    @Test("解码到空串报 dataCorrupted")
    func rejectsBlankOnDecode() {
        // 落盘数据里的空 reason 是损坏 —— 不能因为「类型会拒绝」就放过解码。
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(NonEmptyReason.self, from: Data("\"\"".utf8))
        } == .dataCorrupted)
    }
}

@Suite("ManualOperation")
struct ManualOperationTests {

    @Test("七种操作与名字写死")
    func sevenOperationsArePinned() {
        // v0.2 §2.8 的七种。增删任何一个都改变「哪些事件必须带 reason」,
        // 必须在 diff 里显形。
        #expect(Set(ManualOperation.allCases.map(\.rawValue)) == [
            "force", "bindPullRequest", "changeStage", "cancelJob",
            "migrate", "restoreBackup", "merge",
        ])
        #expect(ManualOperation.allCases.count == 7)
    }

    @Test("每种操作都有非空的中文名")
    func labelsArePresent() {
        for operation in ManualOperation.allCases {
            #expect(operation.label.isEmpty == false, "\(operation.rawValue)")
        }
    }
}
