import Foundation

/// 一个任务。
///
/// ## 为什么不叫 `Task`
///
/// v0.2 §2.2 里它叫 Task,但 Swift 并发已经占了这个名字,而且**冲突方向
/// 对我们不利**:实测导入方一旦 import 本模块,`Task.detached` 会解析到
/// 我们这个类型并直接编译错误。PilotInfrastructure、pilotctl、测试
/// 都要大量用 Swift 并发(v0.2 §5 的协议全是 async throws),
/// 逼所有人写 `_Concurrency.Task` 是不可接受的代价。
///
/// 加前缀而不是换个名词(WorkItem 之类),是为了保住 v0.2 的词汇表 ——
/// 那份文档是所有人和所有执行器的共同参照,词汇分叉的成本比一个前缀高。
public struct PilotTask: Sendable, Hashable, Codable, Identifiable {
    // 身份字段不可变。改这些等于换了一个任务,应当走新建 + 取消。
    public let id: UUID
    public let projectId: UUID
    /// 项目内的可读编号,给人用的(「去看一下 12 号」)。
    /// 跨项目不唯一 —— 跨项目唯一的是 `id`。
    public let displayNumber: Int
    public let createdAt: Date

    /// 只能通过 `rename(to:)` 改 —— 它有「非空」这个不变量,
    /// 而一个能被改成空串的字段等于没有不变量。
    public private(set) var title: String
    public var description: String
    /// 可验证的验收标准。空数组是允许的,但 P10-04 会把「缺少验收标准」
    /// 当成任务质量问题报出来。
    public var acceptanceCriteria: [String]
    public var type: TaskType
    public var completionPolicy: CompletionPolicy
    public var stage: TaskStage
    public var blockers: [Blocker]
    /// 依赖的任务。自依赖、缺失、跨项目非法、循环的检测在 P5-03,
    /// **不在这里** —— 那需要看到整张图,单个任务判断不了。
    public var dependencyIds: [UUID]
    public var priority: Int
    public var executorPreference: ExecutorPreference?
    public var activeJobId: UUID?
    /// 只能通过 `bindPullRequest` / `unbindPullRequest` 改。
    public private(set) var pullRequestNumber: Int?
    public var updatedAt: Date

    public init(
        id: UUID,
        projectId: UUID,
        displayNumber: Int,
        title: String,
        description: String = "",
        acceptanceCriteria: [String] = [],
        type: TaskType,
        completionPolicy: CompletionPolicy,
        stage: TaskStage = .backlog,
        blockers: [Blocker] = [],
        dependencyIds: [UUID] = [],
        priority: Int = 0,
        executorPreference: ExecutorPreference? = nil,
        activeJobId: UUID? = nil,
        pullRequestNumber: Int? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        precondition(displayNumber >= 1, "displayNumber 从 1 起,收到:\(displayNumber)")
        precondition(!title.isEmpty, "任务标题不能为空")
        if let number = pullRequestNumber {
            precondition(number >= 1, "PR 编号从 1 起,收到:\(number)")
        }
        self.id = id
        self.projectId = projectId
        self.displayNumber = displayNumber
        self.title = title
        self.description = description
        self.acceptanceCriteria = acceptanceCriteria
        self.type = type
        self.completionPolicy = completionPolicy
        self.stage = stage
        self.blockers = blockers
        self.dependencyIds = dependencyIds
        self.priority = priority
        self.executorPreference = executorPreference
        self.activeJobId = activeJobId
        self.pullRequestNumber = pullRequestNumber
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 改标题。
    ///
    /// 用 `precondition` 而不是抛错,是为了和构造器保持一致 ——
    /// 同一条不变量,同一种强制方式。调用方(命令层、界面)负责在把空标题
    /// 递进来之前就挡住,那是它该做的校验。
    public mutating func rename(to newTitle: String) {
        precondition(!newTitle.isEmpty, "任务标题不能为空")
        title = newTitle
    }

    /// 绑定一个 PR。
    public mutating func bindPullRequest(number: Int) {
        precondition(number >= 1, "PR 编号从 1 起,收到:\(number)")
        pullRequestNumber = number
    }

    /// 解绑 PR。
    public mutating func unbindPullRequest() {
        pullRequestNumber = nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectId = try container.decode(UUID.self, forKey: .projectId)
        displayNumber = try container.decode(Int.self, forKey: .displayNumber)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decode(String.self, forKey: .description)
        acceptanceCriteria = try container.decode([String].self, forKey: .acceptanceCriteria)
        type = try container.decode(TaskType.self, forKey: .type)
        completionPolicy = try container.decode(CompletionPolicy.self, forKey: .completionPolicy)
        stage = try container.decode(TaskStage.self, forKey: .stage)
        blockers = try container.decode([Blocker].self, forKey: .blockers)
        dependencyIds = try container.decode([UUID].self, forKey: .dependencyIds)
        priority = try container.decode(Int.self, forKey: .priority)
        executorPreference = try container.decodeIfPresent(ExecutorPreference.self, forKey: .executorPreference)
        activeJobId = try container.decodeIfPresent(UUID.self, forKey: .activeJobId)
        pullRequestNumber = try container.decodeIfPresent(Int.self, forKey: .pullRequestNumber)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        guard displayNumber >= 1 else {
            throw DecodingError.dataCorruptedError(
                forKey: .displayNumber, in: container,
                debugDescription: "displayNumber 从 1 起,实际读到:\(displayNumber)"
            )
        }
        guard !title.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .title, in: container,
                debugDescription: "任务标题不能为空"
            )
        }
        if let number = pullRequestNumber, number < 1 {
            throw DecodingError.dataCorruptedError(
                forKey: .pullRequestNumber, in: container,
                debugDescription: "PR 编号从 1 起,实际读到:\(number)"
            )
        }
    }
}
