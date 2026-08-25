import Foundation

/// 审查结论。
///
/// 三种取值对应 GitHub 的审查类型 —— v0.2 P4-09 明确提到「GitHub 拒绝
/// 作者自审时降级为 comment」,说明 comment 是一种正式的结论,不是没结论。
public enum ReviewVerdict: String, Sendable, Hashable, Codable, CaseIterable {
    case approved
    case changesRequested
    /// 只留意见,不表态。作者自审被 GitHub 拒绝时会降级到这里,
    /// 而降级必须在界面上明示(P4-09)—— 因为它**不能满足合并闸门**。
    case commented

    /// 能否用于满足本地合并闸门。
    ///
    /// 只有 approved 可以,而且还得先通过 `ReviewRecord.isStale` 这一关。
    public var canSatisfyMergeGate: Bool { self == .approved }
}

/// 审查是谁做的。
///
/// v0.2 §1.6 把本地权威来源描述为「本地 AI 或人工审查记录」——
/// 这个区分正是合并闸门要知道的:一个模型看过和一个人看过,分量不同。
///
/// **远端(GitHub 上的)审查不进这里** —— 那是 GitHub 的权威范围,
/// 体现在 `PullRequestSnapshot.reviewDecision` 上。
public enum ReviewSource: String, Sendable, Hashable, Codable, CaseIterable {
    case human
    case automated
}

/// 审查中发现的一条问题。
///
/// 结构刻意保持最小。v0.2 §2.6 只说了要有 `findings`,没规定结构;
/// P10-08 定义的那份丰富结构(严重度、风险、修复期望、证据)属于 Phase 10,
/// 而 Phase 10 在 M-Solo 里整个推迟(v0.3 D-03)。
///
/// 这里只放当前真的有消费方的字段:文件与行号给界面定位(P8-04),
/// `isBlocking` 给合并闸门判断(P5-06)。不发明严重度分级 ——
/// 那会在没有消费方的情况下先固化一套分类。
public struct ReviewFinding: Sendable, Hashable, Codable {
    /// 相对仓库根的路径。跨文件的问题为 nil。
    public var file: String?
    public var line: Int?
    public var message: String
    /// 是否阻止合并。
    public var isBlocking: Bool

    public init(file: String? = nil, line: Int? = nil, message: String, isBlocking: Bool) {
        precondition(!message.isEmpty, "审查发现必须有说明")
        self.file = file
        self.line = line
        self.message = message
        self.isBlocking = isBlocking
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = try container.decodeIfPresent(String.self, forKey: .file)
        line = try container.decodeIfPresent(Int.self, forKey: .line)
        message = try container.decode(String.self, forKey: .message)
        isBlocking = try container.decode(Bool.self, forKey: .isBlocking)
        guard !message.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .message, in: container,
                debugDescription: "审查发现必须有说明"
            )
        }
    }
}

/// 一次审查的记录。
///
/// ## 两条历史业务规则编码在这里
///
/// **审查绑定 head SHA。** PR 的 head 一变,这条记录立刻失效(v0.2 §2.6)。
/// 「approve 之后又推了新代码」是 v0.2 §6.2 列出的必须移植的规则之一。
///
/// **有未审查文件时不能给出可用于合并的 approve。** 覆盖不全的自动审查
/// 说明不了整个改动是安全的(v0.2 §2.6、P10-09)。
public struct ReviewRecord: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let taskId: UUID
    public let pullRequestNumber: Int
    public let verdict: ReviewVerdict
    public let source: ReviewSource
    /// 审查时 PR 的 head SHA。**这条记录的有效期就系在它上面。**
    public let headSHA: String
    public let baseSHA: String
    public let findings: [ReviewFinding]
    public let reviewedFiles: [String]
    /// 没能审到的文件。非空就意味着这次审查不完整。
    public let unreviewedFiles: [String]
    /// 自动审查用的模型。人工审查为 nil。
    public let model: String?
    public let toolVersion: String?
    /// 提示词版本。回放和回测要靠它复现当时的条件(P10-12)。
    public let promptVersion: String?
    public let createdAt: Date

    public init(
        id: UUID,
        taskId: UUID,
        pullRequestNumber: Int,
        verdict: ReviewVerdict,
        source: ReviewSource,
        headSHA: String,
        baseSHA: String,
        findings: [ReviewFinding] = [],
        reviewedFiles: [String] = [],
        unreviewedFiles: [String] = [],
        model: String? = nil,
        toolVersion: String? = nil,
        promptVersion: String? = nil,
        createdAt: Date
    ) {
        precondition(pullRequestNumber >= 1, "PR 编号从 1 起,收到:\(pullRequestNumber)")
        precondition(!headSHA.isEmpty, "审查必须绑定 head SHA,否则无法判断是否失效")
        self.id = id
        self.taskId = taskId
        self.pullRequestNumber = pullRequestNumber
        self.verdict = verdict
        self.source = source
        self.headSHA = headSHA
        self.baseSHA = baseSHA
        self.findings = findings
        self.reviewedFiles = reviewedFiles
        self.unreviewedFiles = unreviewedFiles
        self.model = model
        self.toolVersion = toolVersion
        self.promptVersion = promptVersion
        self.createdAt = createdAt
    }

    /// 相对某个当前 head SHA,这条记录是否已经失效。
    ///
    /// 判断只看 SHA 相等,不看时间 —— 时间会因为时钟回拨、时区、
    /// 或者两次推送挨得太近而骗人,SHA 不会。
    public func isStale(currentHeadSHA: String) -> Bool {
        headSHA != currentHeadSHA
    }

    /// 覆盖是否完整。
    public var hasFullCoverage: Bool { unreviewedFiles.isEmpty }

    /// 是否有标记为阻止合并的发现。
    public var hasBlockingFindings: Bool { findings.contains(where: \.isBlocking) }

    /// 这条记录能否用于满足本地合并闸门。
    ///
    /// **四个条件缺一不可:**结论是 approved、没有阻断项、覆盖完整、
    /// 相对当前 head 未失效。
    ///
    /// 「结论是 approved 但带着阻断项」不是一种可以放行的状态,而是自相矛盾 ——
    /// `isBlocking` 的定义就是「阻止合并」。允许它通过,等于让审查者
    /// 一边说「这里有问题不能合」一边把门打开。
    public func canSatisfyMergeGate(currentHeadSHA: String) -> Bool {
        verdict.canSatisfyMergeGate
            && !hasBlockingFindings
            && hasFullCoverage
            && !isStale(currentHeadSHA: currentHeadSHA)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        taskId = try container.decode(UUID.self, forKey: .taskId)
        pullRequestNumber = try container.decode(Int.self, forKey: .pullRequestNumber)
        verdict = try container.decode(ReviewVerdict.self, forKey: .verdict)
        source = try container.decode(ReviewSource.self, forKey: .source)
        headSHA = try container.decode(String.self, forKey: .headSHA)
        baseSHA = try container.decode(String.self, forKey: .baseSHA)
        findings = try container.decode([ReviewFinding].self, forKey: .findings)
        reviewedFiles = try container.decode([String].self, forKey: .reviewedFiles)
        unreviewedFiles = try container.decode([String].self, forKey: .unreviewedFiles)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        toolVersion = try container.decodeIfPresent(String.self, forKey: .toolVersion)
        promptVersion = try container.decodeIfPresent(String.self, forKey: .promptVersion)
        createdAt = try container.decode(Date.self, forKey: .createdAt)

        guard pullRequestNumber >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .pullRequestNumber, in: container,
                debugDescription: "PR 编号从 1 起,实际读到:\(pullRequestNumber)"
            )
        }
        guard !headSHA.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .headSHA, in: container,
                debugDescription: "审查必须绑定 head SHA,否则无法判断是否失效"
            )
        }
    }
}
