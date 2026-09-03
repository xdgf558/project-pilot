import Foundation

/// 谁发起了一次状态转换。
///
/// 这里的区分是 v0.2 §2.8「七种情况必须带 reason」的**编译期落点**:
/// 只有 `.manual` 路径携带 `ManualOperation` 和 reason,而且 `reason`
/// 不是 Optional —— 想省掉它,编译就过不去。
public enum TransitionSource: Sendable, Hashable {
    /// 系统推导:执行器启动、CI 完成、同步推导。不需要 reason ——
    /// 事件本身(哪个执行器、哪次作业)已经说明了经过。
    case derived
    /// 人或强制操作。v0.2 §2.8 的七种情况走这里,**必须**带非空 reason。
    ///
    /// 半年后回看一次强制操作,需要知道的是当时为什么绕过闸门 ——
    /// 那只存在于人脑里,不写下来就永久丢失。
    case manual(operation: ManualOperation, reason: String)
}

/// v0.2 §2.8 规定**必须**记录 reason 的七种操作。
///
/// 清单原文记录在 `Event.reason` 的字段文档里:force、手动绑定 PR、
/// 手动改状态、取消作业、迁移、恢复备份、合并。
public enum ManualOperation: String, Sendable, Hashable, CaseIterable {
    /// 强制执行(绕过闸门)。
    case force
    /// 手动把 PR 绑到任务上。
    case bindPullRequest
    /// 手动改状态(不走推导)。
    case changeStage
    /// 取消作业。
    case cancelJob
    /// 数据迁移。
    case migrate
    /// 恢复备份。
    case restoreBackup
    /// 合并。
    case merge

    /// 给界面和错误信息用的中文名。
    public var label: String {
        switch self {
        case .force: return "强制执行"
        case .bindPullRequest: return "手动绑定 PR"
        case .changeStage: return "手动改状态"
        case .cancelJob: return "取消作业"
        case .migrate: return "数据迁移"
        case .restoreBackup: return "恢复备份"
        case .merge: return "合并"
        }
    }
}

/// 一次状态转换请求。`from` 必须显式给出 —— 仓库层(P1-05)要拿它
/// 与磁盘上的当前状态对照,不一致说明中间有人写过,必须拒绝而不是覆盖。
public struct TransitionRequest<State: Hashable & Sendable>: Sendable, Hashable {
    public let from: State
    public let to: State
    public let source: TransitionSource

    public init(from: State, to: State, source: TransitionSource) {
        self.from = from
        self.to = to
        self.source = source
    }
}

/// 转换被拒绝的原因。类型化到具体分支 ——
/// 「被拒了」不够:哪个东西、期望什么、实际怎样,对应完全不同的用户可见信息。
public enum TransitionDenial: Sendable, Hashable, Error, LocalizedError {
    /// 目标与当前相同。from == to 的转换不携带任何信息,
    /// 事件日志里出现它纯属噪音。
    case noStateChange(state: String)
    /// 终态不可离开。终态之后要修正,追加新事件,不是改旧状态。
    case leavingTerminalStage(state: String)
    /// 这条边不在合法转换表里。查 `legalTransitions` 看当前允许哪些去处。
    case edgeNotPermitted(from: String, to: String)
    /// 手动操作必须带非空 reason。空串或纯空白等于没带。
    case missingReason(operation: ManualOperation)

    public var errorDescription: String? {
        switch self {
        case .noStateChange(let state):
            return "状态没有变化(\(state)):一次转换必须真的改变状态。"
        case .leavingTerminalStage(let state):
            return "「\(state)」是终态,不能再转换。终态之后要修正,请追加新的事件,而不是改旧状态。"
        case .edgeNotPermitted(let from, let to):
            return "状态不允许从「\(from)」改到「\(to)」:这条边不在合法转换表里。允许的去处见 legalTransitions。"
        case .missingReason(let operation):
            return "手动\(operation.label)必须附带原因(reason)。v0.2 §2.8:半年后回看一次强制操作,需要知道当时为什么。空串或纯空白等于没带。"
        }
    }
}

// MARK: - TaskStage 的转换表

extension TaskStage {
    /// 合法转换边,**全显式**,一格一行 —— 拿到 v0.2 §2.3 原文后改这里即可。
    ///
    /// 当前形状(2026-09-03 经项目所有者确认的最小形状,见 ADR-0014):
    /// - 前进允许跨级(backlog→queued 合法,不必逐级);
    /// - 后退只有 review→implementing(审查打回重做);
    /// - canceled 可从任何非终态进入;
    /// - 终态(completed / canceled)没有出边。
    ///
    /// 注意:边表不管「怎样才能算完成」—— mergedPR 策略要求 GitHub 确认合并,
    /// 那是合并闸门(P5-06)和状态推导(P5-01)的职责,不是边表的。
    public static let legalTransitions: [TaskStage: Set<TaskStage>] = [
        .backlog: [.ready, .queued, .implementing, .review, .approved, .completed, .canceled],
        .ready: [.queued, .implementing, .review, .approved, .completed, .canceled],
        .queued: [.implementing, .review, .approved, .completed, .canceled],
        .implementing: [.review, .approved, .completed, .canceled],
        .review: [.approved, .completed, .canceled, .implementing],
        .approved: [.completed, .canceled],
        .completed: [],
        .canceled: [],
    ]
}

/// TaskStage 的转换校验。
public enum TaskStageTransition {
    /// 校验一次转换。合法则返回,非法抛 `TransitionDenial`。
    public static func validate(_ request: TransitionRequest<TaskStage>) throws {
        if request.from == request.to {
            throw TransitionDenial.noStateChange(state: request.from.rawValue)
        }
        guard let targets = TaskStage.legalTransitions[request.from] else {
            preconditionFailure("转换表缺少 \(request.from.rawValue) 的条目 —— 表必须是全函数")
        }
        if targets.contains(request.to) {
            try checkReason(request.source)
            return
        }
        if request.from.isTerminal {
            throw TransitionDenial.leavingTerminalStage(state: request.from.rawValue)
        }
        throw TransitionDenial.edgeNotPermitted(from: request.from.rawValue, to: request.to.rawValue)
    }

    private static func checkReason(_ source: TransitionSource) throws {
        if case .manual(let operation, let reason) = source {
            if reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw TransitionDenial.missingReason(operation: operation)
            }
        }
    }
}

// MARK: - JobStatus 的转换表

extension JobStatus {
    /// 合法转换边,**全显式**(2026-09-03 经项目所有者确认的标准收尸流,见 ADR-0014):
    ///
    /// - 线性前进:queued→starting→running→{succeeded, failed};
    /// - 取消要走 canceling(等进程退出):starting/running→canceling→canceled;
    /// - queued 还没有进程,直接 canceled,不经过 canceling;
    /// - orphaned 只从「预期进程活着」的状态进入:starting / running / canceling;
    ///   queued 没有进程,不存在「进程没了但结果不明」;
    /// - 终态(succeeded / failed / canceled / orphaned)没有出边。
    ///   重试是**新的 Job**(attempt +1),不是旧 Job 复活。
    public static let legalTransitions: [JobStatus: Set<JobStatus>] = [
        .queued: [.starting, .canceled],
        .starting: [.running, .canceling, .orphaned],
        .running: [.succeeded, .failed, .canceling, .orphaned],
        .canceling: [.canceled, .orphaned],
        .succeeded: [],
        .failed: [],
        .canceled: [],
        .orphaned: [],
    ]
}

/// JobStatus 的转换校验。
public enum JobStatusTransition {
    /// 校验一次转换。合法则返回,非法抛 `TransitionDenial`。
    public static func validate(_ request: TransitionRequest<JobStatus>) throws {
        if request.from == request.to {
            throw TransitionDenial.noStateChange(state: request.from.rawValue)
        }
        guard let targets = JobStatus.legalTransitions[request.from] else {
            preconditionFailure("转换表缺少 \(request.from.rawValue) 的条目 —— 表必须是全函数")
        }
        if targets.contains(request.to) {
            try checkReason(request.source)
            return
        }
        if request.from.isTerminal {
            throw TransitionDenial.leavingTerminalStage(state: request.from.rawValue)
        }
        throw TransitionDenial.edgeNotPermitted(from: request.from.rawValue, to: request.to.rawValue)
    }

    private static func checkReason(_ source: TransitionSource) throws {
        if case .manual(let operation, let reason) = source {
            if reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw TransitionDenial.missingReason(operation: operation)
            }
        }
    }
}
