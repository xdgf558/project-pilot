import Foundation
import Testing
import PilotCore

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

    @Test("手动改状态必须带非空 reason,编译期由非 Optional 保证")
    func manualStageChangeRequiresReason() throws {
        try TaskStageTransition.validate(TransitionRequest(
            from: .review, to: .implementing,
            source: .manual(operation: .changeStage, reason: "审查打回,重做")))
    }

    @Test("空串和纯空白的 reason 都算没带", arguments: ["", " ", "\n\t "])
    func blankReasonIsMissing(_ reason: String) {
        #expect(throws: TransitionDenial.missingReason(operation: .changeStage)) {
            try TaskStageTransition.validate(TransitionRequest(
                from: .review, to: .implementing,
                source: .manual(operation: .changeStage, reason: reason)))
        }
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
        .starting: [.running, .canceling, .orphaned],
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
    func manualCancelRequiresReason() throws {
        try JobStatusTransition.validate(TransitionRequest(
            from: .running, to: .canceling,
            source: .manual(operation: .cancelJob, reason: "预算超限,用户叫停")))
        #expect(throws: TransitionDenial.missingReason(operation: .cancelJob)) {
            try JobStatusTransition.validate(TransitionRequest(
                from: .running, to: .canceling, source: .manual(operation: .cancelJob, reason: "")))
        }
    }

    @Test("失败的作业不能复活 —— 重试是新的 Job")
    func failedJobCannotRevive() {
        #expect(throws: TransitionDenial.leavingTerminalStage(state: "failed")) {
            try JobStatusTransition.validate(TransitionRequest(from: .failed, to: .running, source: .derived))
        }
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
