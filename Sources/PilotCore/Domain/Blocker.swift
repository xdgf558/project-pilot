import Foundation

/// 任务被卡住的原因。
///
/// v0.2 §2.4:阻塞原因与生命周期分离。一个任务可以同时处在 `review` 阶段
/// 并带着好几个 blocker —— 把「卡住了」塞进 `TaskStage` 会让阶段数爆炸,
/// 而且丢掉「同时卡在两件事上」这个信息。
public enum BlockerCode: String, Sendable, Hashable, Codable, CaseIterable {
    case dependencyNotCompleted
    case invalidDependency
    case dependencyCycle
    case repositoryUntrusted
    case toolMissing
    case authenticationRequired
    case workspaceDirty
    case pullRequestClosed
    case pullRequestDraft
    case mergeConflict
    case requiredChecksPending
    case requiredChecksFailed
    case reviewStale
    case jobFailed
    case budgetExceeded
    case manualPause
    case unsupportedRepository

    /// 是否可能在后续的同步或状态推导中被系统自行清除,不需要用户在
    /// ProjectPilot 里做任何操作。
    ///
    /// **这是推导出来的,不存进数据。** 存下来就意味着分类可以和行为不一致 ——
    /// 哪天重新分类了,旧记录仍然带着旧答案,同一种阻塞在界面上会有两种表现。
    /// 分类是行为,不是数据。
    ///
    /// 不确定的一律归到「不可自动恢复」。跟用户说「它会自己好」结果没好,
    /// 比说「你去看一眼」结果发现不用管更伤信任。
    ///
    /// P5-01 推导状态时可能细化这个分类,那时以那里为准。
    public var isAutomaticallyRecoverable: Bool {
        switch self {
        case .dependencyNotCompleted:   return true   // 依赖任务完成后推导即清除
        case .requiredChecksPending:    return true   // CI 跑完同步即清除
        case .pullRequestDraft:         return true   // 同步到 PR 不再是草稿即清除
        case .invalidDependency, .dependencyCycle, .repositoryUntrusted,
             .toolMissing, .authenticationRequired, .workspaceDirty,
             .pullRequestClosed, .mergeConflict, .requiredChecksFailed,
             .reviewStale, .jobFailed, .budgetExceeded, .manualPause,
             .unsupportedRepository:
            return false
        }
    }
}

/// 一条具体的阻塞记录。
public struct Blocker: Sendable, Hashable, Codable {
    public let code: BlockerCode
    /// 给人看的说明。要写清楚「哪个东西、期望什么、实际怎样」,
    /// 而不是复述 code 的名字 —— 那个用户已经能看到了。
    public let message: String
    public let occurredAt: Date
    /// 关联对象。依赖类阻塞指向那个依赖任务,PR 类指向 PR 所属任务,
    /// 作业类指向 job。没有明确关联对象时为 nil。
    public let relatedEntityId: UUID?

    public init(
        code: BlockerCode,
        message: String,
        occurredAt: Date,
        relatedEntityId: UUID? = nil
    ) {
        precondition(!message.isEmpty, "blocker 必须带可读消息,code=\(code.rawValue)")
        self.code = code
        self.message = message
        self.occurredAt = occurredAt
        self.relatedEntityId = relatedEntityId
    }

    /// 见 `BlockerCode.isAutomaticallyRecoverable`。
    public var isAutomaticallyRecoverable: Bool { code.isAutomaticallyRecoverable }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(BlockerCode.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        relatedEntityId = try container.decodeIfPresent(UUID.self, forKey: .relatedEntityId)

        guard !message.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .message, in: container,
                debugDescription: "blocker 消息不能为空,code=\(code.rawValue)"
            )
        }
    }
}
