import Foundation

/// 作业生命周期。这是**我们自己定义**的枚举,未知值意味着数据损坏,应当报错 ——
/// 与镜像上游的 `UpstreamEnum` 是两回事。
public enum JobStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case queued
    case starting
    case running
    case succeeded
    case failed
    case canceling
    case canceled
    /// 进程没了但结果不明:可能崩了、可能被系统杀了、可能机器重启过。
    /// 需要靠结果文件、exit record、进程身份、worktree 和 PR 状态一起收尸(P6-07)。
    case orphaned

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .canceled, .orphaned: return true
        case .queued, .starting, .running, .canceling: return false
        }
    }

    /// 进程应当还活着。收尸流程只关心这些状态的作业。
    public var expectsLiveProcess: Bool {
        self == .starting || self == .running || self == .canceling
    }
}

/// 具体派给了哪个执行器。
///
/// 与 `ExecutorPreference` 不同:那个是任务上的**偏好**,可以是 `projectDefault`;
/// 作业上的是已经解析出来的**结果**,不存在「跟随默认」这种状态。
public enum ExecutorKind: String, Sendable, Hashable, Codable, CaseIterable {
    case codex
    case claude
}

/// 这次作业用哪种认证。v0.2 P6-12 要求运行前展示实际认证状态和可能的计费路径。
public enum AuthMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// 订阅登录态。删除会触发 API 计费的凭据变量(v0.2 §4.2)。
    case subscription
    /// 显式 API Key。只向目标进程注入该次运行所需的密钥,
    /// **不写进作业文件、日志或事件**。
    case apiKey
    /// 由外部环境提供,ProjectPilot 不管理。
    case external
}

/// 进程身份,用来在 PID 被系统重用后仍能判断「这还是我起的那个进程吗」。
///
/// **内容对 PilotCore 是不透明的。** 这里只做相等比较,不解释它的格式 ——
/// 取什么作为身份是 `PilotInfrastructure` 的事(P2-03 / P6-06),
/// 那需要调系统 API,而 PilotCore 不碰系统。
///
/// 给那个工作包留一条实测证据:macOS 上 `ps -o lstart` **只有秒级精度**,
/// 同一秒内起的多个进程完全无法区分;而 `sysctl kern.proc.pid` 的
/// `p_starttime` 是微秒级 —— 实测同一秒内连起 4 个进程得到 4 个不同值。
/// 用前者会在密集派工时误判,用后者可以。
///
/// 做成不透明字符串而不是 `Date`,是因为身份的构成可能不止时间
/// (例如还要带上启动次数或 boot 标识)。锁死成时间戳,以后想加就得改数据格式。
public struct ProcessStartIdentity: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "进程身份不能是空串 —— 空串会让所有作业互相匹配")
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard !raw.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "进程身份不能是空串 —— 空串会让所有作业互相匹配"
            )
        }
        rawValue = raw
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// 一次实现作业。
public struct Job: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let projectId: UUID
    public let taskId: UUID
    /// 第几次尝试,从 1 起。重试会产生新的 Job 而不是复用旧的 ——
    /// 旧的失败记录必须留着。
    public let attempt: Int
    public let executor: ExecutorKind
    /// 派工时执行器 CLI 的版本。契约破损时靠它定位是哪个版本变了(v0.3 §3)。
    public var executorVersion: String
    /// 用了哪个模型。执行器没暴露或不适用时为 nil。
    public var model: String?
    public var authMode: AuthMode
    public var worktreePath: URL
    /// 分支名在派工时定下,之后不变。做成 `let` 是因为它有「非空」这个不变量,
    /// 而一个可以被改成空串的字段等于没有不变量 —— 改完照样能编码,
    /// 只是下次读不回来。
    public let branchName: String

    /// 进程号。派工前和收尸后为 nil。
    ///
    /// **单独看它不足以识别进程** —— 系统会重用 PID。必须和
    /// `processStartIdentity` 一起用,否则可能杀掉一个无关的进程(v0.2 §2.5)。
    ///
    /// 只能通过 `attachProcess` / `detachProcess` 改。理由见那两个方法。
    public private(set) var processId: Int32?
    public private(set) var processStartIdentity: ProcessStartIdentity?

    public var status: JobStatus
    public var startedAt: Date?
    /// 最后一次心跳。判断作业是否还活着靠它加进程身份,不能只看进程在不在。
    public var heartbeatAt: Date?
    public var finishedAt: Date?
    public var exitCode: Int32?

    public var resultPath: URL?
    public var stdoutPath: URL?
    public var stderrPath: URL?

    /// 稳定的失败分类,给重试策略用(P7-06 按 failureCode 区分可重试与否)。
    public var failureCode: String?
    /// 给人看的失败说明。要写清「哪个工具、期望什么、实际得到什么」。
    public var failureMessage: String?

    public init(
        id: UUID,
        projectId: UUID,
        taskId: UUID,
        attempt: Int = 1,
        executor: ExecutorKind,
        executorVersion: String,
        model: String? = nil,
        authMode: AuthMode,
        worktreePath: URL,
        branchName: String,
        processId: Int32? = nil,
        processStartIdentity: ProcessStartIdentity? = nil,
        status: JobStatus = .queued,
        startedAt: Date? = nil,
        heartbeatAt: Date? = nil,
        finishedAt: Date? = nil,
        exitCode: Int32? = nil,
        resultPath: URL? = nil,
        stdoutPath: URL? = nil,
        stderrPath: URL? = nil,
        failureCode: String? = nil,
        failureMessage: String? = nil
    ) {
        precondition(attempt >= 1, "attempt 从 1 起,收到:\(attempt)")
        precondition(!branchName.isEmpty, "作业必须有分支名")
        if let pid = processId {
            // POSIX 里 0 和负数不是「某个进程」:kill(0, …) 打整个进程组,
            // kill(-1, …) 打当前用户能打的所有进程。存下这种值,
            // 后面的取消或收尸就可能把自己或别人一起带走。
            precondition(pid > 0, "进程号必须为正,收到:\(pid)")
        }
        self.id = id
        self.projectId = projectId
        self.taskId = taskId
        self.attempt = attempt
        self.executor = executor
        self.executorVersion = executorVersion
        self.model = model
        self.authMode = authMode
        self.worktreePath = worktreePath
        self.branchName = branchName
        self.processId = processId
        self.processStartIdentity = processStartIdentity
        self.status = status
        self.startedAt = startedAt
        self.heartbeatAt = heartbeatAt
        self.finishedAt = finishedAt
        self.exitCode = exitCode
        self.resultPath = resultPath
        self.stdoutPath = stdoutPath
        self.stderrPath = stderrPath
        self.failureCode = failureCode
        self.failureMessage = failureMessage
    }

    /// 记录进程已经起来了。
    ///
    /// 两个字段一起写,不单独暴露 setter。原因是它们有跨字段的约束:
    /// 只有 PID 没有身份是危险状态(那个 PID 可能已属于别人),
    /// 而分开的 setter 会让这个中间状态在两次赋值之间必然出现。
    ///
    /// `identity` 允许为 nil —— 取身份可能失败(sysctl 出错),
    /// 那种情况必须能被记录下来,由 `hasVerifiableProcessIdentity` 判定为不可下手。
    public mutating func attachProcess(id: Int32, identity: ProcessStartIdentity?) {
        // 与构造器同一条不变量,同一种强制方式。
        precondition(id > 0, "进程号必须为正,收到:\(id)")
        processId = id
        processStartIdentity = identity
    }

    /// 进程已经结束或已收尸,清掉身份。
    public mutating func detachProcess() {
        processId = nil
        processStartIdentity = nil
    }

    /// 进程身份是否完整到可以安全地对它下手(取消、收尸)。
    ///
    /// 三个条件:PID 在、PID 是正数、身份在。
    ///
    /// 只有 PID 没有身份时**不能杀** —— 那个 PID 可能已经属于别人了。
    /// PID 非正时更不能碰 —— POSIX 里 0 打整个进程组、负数打一批进程。
    ///
    /// 正数检查在构造、解码和 `attachProcess` 三处都做过,这里再做一次
    /// 是有意的纵深防御。
    ///
    /// **诚实说明:自 `processId` 改为 `private(set)` 之后,这个分支从模块外
    /// 已经无法触达,因此没有测试覆盖它。** 留着的理由是本文件内部仍能直接
    /// 赋值(`private` 的作用域是本文件),将来若在同一文件里加了 reducer,
    /// 这行是最后一道拦。代价是一次比较。
    public var hasVerifiableProcessIdentity: Bool {
        guard let pid = processId, pid > 0 else { return false }
        return processStartIdentity != nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        taskId = try container.decode(UUID.self, forKey: .taskId)
        attempt = try container.decode(Int.self, forKey: .attempt)
        executor = try container.decode(ExecutorKind.self, forKey: .executor)
        executorVersion = try container.decode(String.self, forKey: .executorVersion)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        authMode = try container.decode(AuthMode.self, forKey: .authMode)
        worktreePath = try container.decode(URL.self, forKey: .worktreePath)
        branchName = try container.decode(String.self, forKey: .branchName)
        processId = try container.decodeIfPresent(Int32.self, forKey: .processId)
        processStartIdentity = try container.decodeIfPresent(ProcessStartIdentity.self, forKey: .processStartIdentity)
        status = try container.decode(JobStatus.self, forKey: .status)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        heartbeatAt = try container.decodeIfPresent(Date.self, forKey: .heartbeatAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        resultPath = try container.decodeIfPresent(URL.self, forKey: .resultPath)
        stdoutPath = try container.decodeIfPresent(URL.self, forKey: .stdoutPath)
        stderrPath = try container.decodeIfPresent(URL.self, forKey: .stderrPath)
        failureCode = try container.decodeIfPresent(String.self, forKey: .failureCode)
        failureMessage = try container.decodeIfPresent(String.self, forKey: .failureMessage)

        guard attempt >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .attempt, in: container,
                debugDescription: "attempt 从 1 起,实际读到:\(attempt)"
            )
        }
        guard !branchName.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .branchName, in: container,
                debugDescription: "作业必须有分支名"
            )
        }
        if let pid = processId, pid <= 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .processId, in: container,
                debugDescription: "进程号必须为正(0 和负数在 POSIX 里指进程组),实际读到:\(pid)"
            )
        }
    }
}
