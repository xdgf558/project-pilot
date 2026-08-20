import Foundation

/// 任务的生命周期阶段。
///
/// **只描述生命周期,不描述「为什么卡住」** —— 后者是 `Blocker`。
/// 一个任务可以同时处在 `review` 并带着三个 blocker。
///
/// ## approved 不等于完成
///
/// v0.2 §2.3 专门强调了这一条,而且 §6.2 把它列为必须移植的历史业务规则之首。
/// 在 `mergedPR` 完成策略下,只有 **GitHub 确认 PR 已合并**才能进入 `completed`。
///
/// 本地审查通过、CI 全绿、人点了同意 —— 都不是完成。合并可能失败,
/// 可能被别人抢先关掉,可能推了新代码让审查失效。以 GitHub 为准。
public enum TaskStage: String, Sendable, Hashable, Codable, CaseIterable {
    case backlog
    case ready
    case queued
    case implementing
    case review
    case approved
    case completed
    case canceled

    /// 终态。进入之后不应再回退 —— P5-12 的属性测试要断言这一点。
    public var isTerminal: Bool {
        self == .completed || self == .canceled
    }
}

/// 任务类型。决定它需不需要派给执行器、以及怎样算完成。
public enum TaskType: String, Sendable, Hashable, Codable, CaseIterable {
    /// 要改代码的,派给执行器。
    case code
    /// 要查资料、出结论的。
    case research
    /// 人自己做的。
    case manual
    /// 审查别人产出的。
    case review
}

/// 怎样算完成。
public enum CompletionPolicy: String, Sendable, Hashable, Codable, CaseIterable {
    /// PR 被 GitHub 确认合并。code 任务的默认策略。
    case mergedPR
    /// 人工确认。
    case manualConfirmation
    /// 产出了指定产物。
    case artifactProduced
}

/// 派工时优先用哪个执行器。
public enum ExecutorPreference: String, Sendable, Hashable, Codable, CaseIterable {
    case codex
    case claude
    /// 跟随项目设置。
    case projectDefault
}
