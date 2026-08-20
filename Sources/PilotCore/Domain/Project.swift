import Foundation

/// 调度模式。
public enum SchedulerMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// 只展示 ready,派工全靠人点。新项目的默认值(v0.2 §4.5)。
    case manual
    /// 系统提议下一批,每次派工仍要人确认。
    case assisted
    /// 按策略自动派工。
    ///
    /// **M-Solo 不实现这一档**(v0.3 D-02):它牵扯租约、公平性、
    /// 预算保护和崩溃恢复,是 v0.2 里最重的一块。
    /// 但枚举里保留它 —— 数据模型按 v0.2 定,实现范围按 v0.3 定,
    /// 现在删掉,将来加回来就是一次数据格式变更。
    case automatic
}

/// 仓库策略,决定本地审查能不能满足合并闸门。
public enum RepositoryPolicy: String, Sendable, Hashable, Codable, CaseIterable {
    /// 个人仓库:本地审查可以满足本地闸门。
    case personal
    /// 受保护仓库:继续等 GitHub 的 required reviews、checks 和规则集。
    /// **本地审查不能替代远端要求**(v0.2 P4-11)。
    case protected
}

/// 一个被管理的 GitHub 项目。
public struct Project: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let createdAt: Date

    public var name: String
    /// 规范化后的本地仓库路径。
    public var repositoryPath: URL
    /// 远端主机。
    ///
    /// **刻意不在这里限制成 `github.com`。** v0.2 §0.3 说 v1 只支持 GitHub.com,
    /// 但 §2.4 同时定义了 `unsupportedRepository` 这个 blocker ——
    /// 说明不支持的仓库是**能被存下来并作为阻塞展示**的,不是在数据层拒绝。
    /// 在这里拒绝会导致用户接入一个 GitLab 仓库时连一条像样的错误都给不出来。
    public var remoteHost: String
    public var owner: String
    public var repository: String
    public var defaultBranch: String
    /// 用户确认信任的时间。nil 表示尚未信任 —— 未信任的仓库禁止启动执行器(P3-02)。
    public var trustedAt: Date?
    public var schedulerMode: SchedulerMode
    /// 项目内并发上限。默认 1(v0.2 §4.5)。
    ///
    /// 必须 >= 1。想让项目停下来用暂停,不是把上限设成 0 ——
    /// 那样「暂停了」和「配置错了」在数据上分不开。
    public var projectConcurrency: Int
    public var repositoryPolicy: RepositoryPolicy
    public var updatedAt: Date

    public init(
        id: UUID,
        name: String,
        repositoryPath: URL,
        remoteHost: String,
        owner: String,
        repository: String,
        defaultBranch: String,
        trustedAt: Date? = nil,
        schedulerMode: SchedulerMode = .manual,
        projectConcurrency: Int = 1,
        repositoryPolicy: RepositoryPolicy,
        createdAt: Date,
        updatedAt: Date
    ) {
        precondition(!name.isEmpty, "项目名不能为空")
        precondition(projectConcurrency >= 1, "项目并发上限必须 >= 1,收到:\(projectConcurrency)")
        self.id = id
        self.name = name
        self.repositoryPath = repositoryPath
        self.remoteHost = remoteHost
        self.owner = owner
        self.repository = repository
        self.defaultBranch = defaultBranch
        self.trustedAt = trustedAt
        self.schedulerMode = schedulerMode
        self.projectConcurrency = projectConcurrency
        self.repositoryPolicy = repositoryPolicy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 用户是否已确认信任这个仓库。
    public var isTrusted: Bool { trustedAt != nil }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        repositoryPath = try container.decode(URL.self, forKey: .repositoryPath)
        remoteHost = try container.decode(String.self, forKey: .remoteHost)
        owner = try container.decode(String.self, forKey: .owner)
        repository = try container.decode(String.self, forKey: .repository)
        defaultBranch = try container.decode(String.self, forKey: .defaultBranch)
        trustedAt = try container.decodeIfPresent(Date.self, forKey: .trustedAt)
        schedulerMode = try container.decode(SchedulerMode.self, forKey: .schedulerMode)
        projectConcurrency = try container.decode(Int.self, forKey: .projectConcurrency)
        repositoryPolicy = try container.decode(RepositoryPolicy.self, forKey: .repositoryPolicy)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        guard !name.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container, debugDescription: "项目名不能为空"
            )
        }
        guard projectConcurrency >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .projectConcurrency, in: container,
                debugDescription: "项目并发上限必须 >= 1,实际读到:\(projectConcurrency)"
            )
        }
    }
}
