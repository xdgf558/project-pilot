import Foundation

// 下面这些枚举镜像 GitHub 的取值。**列表是尽力而为,不保证完整** ——
// 正确性不依赖它完整:未知值经由 `OpenEnum` 原样保留,不会让快照解不出来。
// 标注「已观察」的是在本项目真实 PR 上直接见到的。

public enum PullRequestState: String, OpenEnumValue {
    case open = "OPEN"          // 已观察
    case closed = "CLOSED"
    case merged = "MERGED"      // 已观察
}

public enum MergeableState: String, OpenEnumValue {
    case mergeable = "MERGEABLE"     // 已观察
    case conflicting = "CONFLICTING"
    case unknown = "UNKNOWN"         // 已观察。GitHub 正在后台算,稍后重试
}

public enum MergeStateStatus: String, OpenEnumValue {
    case behind = "BEHIND"
    case blocked = "BLOCKED"
    case clean = "CLEAN"             // 已观察
    case dirty = "DIRTY"
    case draft = "DRAFT"
    case hasHooks = "HAS_HOOKS"
    case unstable = "UNSTABLE"
    case unknown = "UNKNOWN"         // 已观察
}

public enum ReviewDecision: String, OpenEnumValue {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
    /// **没有审查结论时 gh 返回空字符串,不是 null。**
    /// 已观察。按 `String?` 建模会把空串当成「有值」,判断就错了。
    case none = ""
}

public enum CheckStatus: String, OpenEnumValue {
    case queued = "QUEUED"
    case inProgress = "IN_PROGRESS"
    case completed = "COMPLETED"      // 已观察
    case waiting = "WAITING"
    case pending = "PENDING"
    case requested = "REQUESTED"
}

public enum CheckConclusion: String, OpenEnumValue {
    case success = "SUCCESS"          // 已观察
    case failure = "FAILURE"
    case neutral = "NEUTRAL"
    case cancelled = "CANCELLED"
    case timedOut = "TIMED_OUT"
    case actionRequired = "ACTION_REQUIRED"
    case skipped = "SKIPPED"
    case stale = "STALE"
    case startupFailure = "STARTUP_FAILURE"
}

/// 一条检查(CI 作业等)的状态。
public struct StatusCheck: Sendable, Hashable, Codable {
    public var name: String
    public var status: OpenEnum<CheckStatus>
    /// 未完成的检查没有结论。
    public var conclusion: OpenEnum<CheckConclusion>?
    public var startedAt: Date?
    public var completedAt: Date?
    /// 详情链接。**用 String 不用 URL** —— 上游给出我们解析不了的字符串时,
    /// URL 会解码失败并连累整份快照;而这个字段只是给人点的。
    public var detailsURL: String?
    /// 工作流名(GitHub Actions 有,其他检查提供方可能没有)。
    public var workflowName: String?

    public init(
        name: String,
        status: OpenEnum<CheckStatus>,
        conclusion: OpenEnum<CheckConclusion>? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        detailsURL: String? = nil,
        workflowName: String? = nil
    ) {
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.detailsURL = detailsURL
        self.workflowName = workflowName
    }
}

/// 某一时刻从 GitHub 取回的 PR 状态。
///
/// **这是快照,不是权威。** 权威在 GitHub(v0.2 §1.6),这里只是最后一次
/// 同步看到的样子。合并闸门必须带着 `headRefOid` 去 GitHub 再确认一次
/// (P5-08 用 `--match-head-commit`),不能只信这份快照。
public struct PullRequestSnapshot: Sendable, Hashable, Codable {
    public let number: Int
    public var state: OpenEnum<PullRequestState>
    public var isDraft: Bool
    public var headRefName: String
    /// 当前 head 的 commit SHA。
    ///
    /// 整个合并安全体系的支点:审查绑定到它(P5-05),合并时用它做
    /// `--match-head-commit`(P5-08)。取不到它时高风险操作必须禁用(P4-03)。
    public var headRefOid: String
    public var baseRefName: String
    public var mergeable: OpenEnum<MergeableState>
    public var mergeStateStatus: OpenEnum<MergeStateStatus>
    public var reviewDecision: OpenEnum<ReviewDecision>
    public var statusCheckRollup: [StatusCheck]
    public var mergedAt: Date?
    public var closedAt: Date?
    public var updatedAt: Date
    /// 同步时哪些能力不可用。
    ///
    /// gh 版本过低、字段缺失、权限不足时记在这里,界面据此明示降级
    /// (v0.2 P4-03:缺少展示字段时允许只读同步)。空数组表示这次同步完整。
    public var syncCapabilityWarnings: [String]

    public init(
        number: Int,
        state: OpenEnum<PullRequestState>,
        isDraft: Bool,
        headRefName: String,
        headRefOid: String,
        baseRefName: String,
        mergeable: OpenEnum<MergeableState>,
        mergeStateStatus: OpenEnum<MergeStateStatus>,
        reviewDecision: OpenEnum<ReviewDecision>,
        statusCheckRollup: [StatusCheck] = [],
        mergedAt: Date? = nil,
        closedAt: Date? = nil,
        updatedAt: Date,
        syncCapabilityWarnings: [String] = []
    ) {
        precondition(number >= 1, "PR 编号从 1 起,收到:\(number)")
        self.number = number
        self.state = state
        self.isDraft = isDraft
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.baseRefName = baseRefName
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.reviewDecision = reviewDecision
        self.statusCheckRollup = statusCheckRollup
        self.mergedAt = mergedAt
        self.closedAt = closedAt
        self.updatedAt = updatedAt
        self.syncCapabilityWarnings = syncCapabilityWarnings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        state = try container.decode(OpenEnum<PullRequestState>.self, forKey: .state)
        isDraft = try container.decode(Bool.self, forKey: .isDraft)
        headRefName = try container.decode(String.self, forKey: .headRefName)
        headRefOid = try container.decode(String.self, forKey: .headRefOid)
        baseRefName = try container.decode(String.self, forKey: .baseRefName)
        mergeable = try container.decode(OpenEnum<MergeableState>.self, forKey: .mergeable)
        mergeStateStatus = try container.decode(OpenEnum<MergeStateStatus>.self, forKey: .mergeStateStatus)
        reviewDecision = try container.decode(OpenEnum<ReviewDecision>.self, forKey: .reviewDecision)
        statusCheckRollup = try container.decode([StatusCheck].self, forKey: .statusCheckRollup)
        mergedAt = try container.decodeIfPresent(Date.self, forKey: .mergedAt)
        closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        syncCapabilityWarnings = try container.decode([String].self, forKey: .syncCapabilityWarnings)

        guard number >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .number, in: container,
                debugDescription: "PR 编号从 1 起,实际读到:\(number)"
            )
        }
    }
}
