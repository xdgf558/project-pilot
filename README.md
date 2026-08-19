# ProjectPilot

> A native macOS tool for driving multi-project development progress —
> it dispatches coding tasks to local CLI agents (Codex / Claude Code),
> tracks them through PR review and merge, and keeps GitHub as the single source of truth.

一个 macOS 原生的多项目开发进度管理工具:把开发文档拆成任务,派给本地
编码 agent(Codex CLI / Claude Code)去做,盯着它们走完「开 PR → 审查 → 合并 → 标完成」,
GitHub 是唯一权威来源。

**当前状态:Phase 0 工程基础,接近完成。**
还没有界面,也还没有数据层 —— 现在仓库里的是工程骨架、
自动强制的模块边界、CI,以及给 AI 执行器看的规则源。

---

## 为什么做这个

现状是一套跑在 DeepSeek Harness(dsh)里的插件,已经完整跑通过整条流水线。
它能用,但有三个问题:

1. **单项目写死** —— 配置里只有一组 `repo` / `repoPath` / `dataDir`
2. **没有主动性** —— 没有调度器,每一步都要人打字触发
3. **绑在 dsh 上** —— dsh 版本迭代很快,配置层还会静默失效

还有一条更痛的:**没有 worktree 隔离,多个执行器只能串行。**

## 核心架构判断:三层责任模型

整套系统里**真正需要模型的只有两层**,底下那层全是确定性逻辑。

| 层 | 责任 | 依赖模型 |
|---|---|---|
| **确定性平台** | 数据、状态机、依赖图、GitHub 同步、Git 操作、合并准备度、调度、日志、通知、界面 | 否 |
| **实现执行器** | 在隔离 worktree 中改代码、跑测试、输出结构化结果 | 是(Codex / Claude) |
| **规划与审查** | 从文档拆任务、分析 diff、给审查结论 | 可选,待决策 |

这样切的好处:上游工具升级,最坏只影响上面两层,**降级成「你自己拆、自己审」,
而不是整个系统崩掉**。数据在自己的 JSON 里,PR 在 GitHub 上,一样都不会丢。

## 上面两层的接入方式完全不同

容易混淆的地方,分清楚才好设计扩展点:

| 你想接什么 | 接在哪层 | 形式 |
|---|---|---|
| 另一个终端编码 agent | 实现执行器 | **CLI 适配器**(不是填 API Key) |
| 另一个模型来拆任务 / 审代码 | 规划与审查 | **API**(OpenAI 兼容端点) |

执行器是本地命令行 agent,靠 spawn 进程、传 prompt、读结构化输出;
规划和审查是一次请求一次响应,不需要 agent loop。

## 技术栈

- **Swift 6**(开启严格并发检查)、**SwiftUI**、Swift Testing、Foundation、ServiceManagement、OSLog
- macOS 14+ / Apple Silicon
- **权威数据存储是版本化 JSON 快照 + NDJSON 事件日志,不用 SwiftData。**
  选它是因为:能继续用旧版 JSON 资产、迁移备份审计更透明、
  后台服务可以成为唯一写入者、状态历史能直接支撑趋势图和通知去重。
- **关闭 App Sandbox** —— 核心行为是 spawn 外部进程,而沙箱子进程会继承父进程限制。
  已决策不上 App Store,自用 + 个人网站分发。

关掉沙箱不等于没有边界,仍然要求:不用 root、只以当前用户身份运行、
不扫描未授权目录、仓库必须经用户信任确认、外部命令只用解析验证过的绝对路径、
**禁止拼接 shell 命令字符串**。

## 仓库结构

    Package.swift            SPM 包,swift-tools-version 6.0
    Sources/
      PilotCore/             纯逻辑层。零 IO,不认识外部世界
      PilotInfrastructure/   通往外部世界的唯一通道
      PilotTestSupport/      测试替身。不是 product,产品 target 不得依赖
      pilotctl/              命令行宿主
    Tests/
    Scripts/                 边界检查、规则生成,以及它们各自的测试
    Docs/
      DECISIONS.md           架构决策记录
      EXECUTOR_RULES.md      执行器规则的权威源
    AGENTS.md  CLAUDE.md     由 EXECUTOR_RULES.md 生成,勿直接编辑

**没有 `.xcodeproj`。** 界面要到 Phase 8 才需要,届时以独立 Xcode 工程链接本 package。
这么选是因为本项目的核心卖点是多个执行器**并行**改代码,而 `project.pbxproj`
是出了名的难合文件 —— 自己的工具不该被自己的工程结构卡住。
理由和回退条件见 ADR-0002。

分层不靠自觉。`PilotCore` 里出现 `Process`、`FileManager`、任何 UI 框架,
或者产品 target 依赖了 `PilotTestSupport`,CI 会直接红。

## 上手

```bash
swift build
swift test
```

CI 跑的是下面八条,推送前本地先跑一遍能省一个来回:

```bash
swift build -Xswiftc -warnings-as-errors
Scripts/run-tests.sh debug
swift build -c release -Xswiftc -warnings-as-errors
Scripts/run-tests.sh release
Scripts/check-module-boundaries.sh
Scripts/test-check-module-boundaries.sh
Scripts/generate-executor-rules.sh --check
Scripts/test-generate-executor-rules.sh
```

Debug 和 Release 都跑,是因为两者行为真的不同 —— `-O` 下 `assert()` 被整个移除,
`precondition()` 保留。只测 Debug,发布构建里少掉的那些检查就从来没被验证过。

新增了 test target 之后要先 `rm -rf .build`,否则 SPM 不会重建测试 bundle,
新套件会**静默不跑**。

需要 Xcode 26.6 / Swift 6.3。CI 锁的是同一个 Xcode build(17F113),
所以本地和 CI 之间不存在工具链差异。

## 两份值得先读的文档

| | |
|---|---|
| [`Docs/DECISIONS.md`](Docs/DECISIONS.md) | 每条架构决策的理由、**代价**和回退条件。有些看起来该做的事已经被明确否决过 |
| [`Docs/EXECUTOR_RULES.md`](Docs/EXECUTOR_RULES.md) | AI 执行器开工前必读的规则。`AGENTS.md` 与 `CLAUDE.md` 由它生成,CI 挡住两者漂移 |

## 外部依赖

依赖四个外部 CLI,它们各自独立演进:

| 工具 | 用途 | 必需性 |
|---|---|---|
| `git` | worktree 隔离、分支管理、提交推送 | **必需** |
| `gh` | PR 状态、能力探测、合并闸门 | **必需** |
| `codex` | 实现执行器 | 可选 |
| `claude` | 实现执行器 | 可选 |

**破坏方式往往是静默的** —— JSON 少一个字段、输出格式微调、flag 改名,
程序不会崩,只会行为错误。所以有一套**契约测试**专门断言我们实际依赖的那部分行为,
并且**锁定已验证版本,不使用 `latest` 浮动版本**。

## 路线图(M-Solo 自用版)

```
第一步  工程骨架 + 数据层          不碰外部世界      ← 现在在这里
第二步  命令安全 + 契约测试        上游变化的预警机制
第三步  worktree 隔离              现有实现最痛的缺口
第四步  GitHub 同步 + 合并安全
第五步  作业协议 + 执行器
第六步  看板                       先能用再好看
───────────── 到这里自用版可以每天用了 ─────────────
之后    按实际痛点补:常驻 Agent / 自动调度 / 智能规划 / 分发
```

前四步不产生任何可见界面。这是必要的代价 ——
**数据和合并安全出问题的成本,远高于晚几周看到界面。**

## 一个诚实的边界

「剩余额度」做不到,因为上游没提供接口。能做的是:
统计累计花费(Claude 的 `total_cost_usd`,注意那是**客户端估算的等价 API 费用**,
订阅用户并不按这个扣费),以及在额度耗尽时给出明确的 blocker 和一键切换执行器 ——
**这比显示剩余额度更有用。**

## License

[GPL-3.0](LICENSE)
