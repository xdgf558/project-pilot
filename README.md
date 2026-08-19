# ProjectPilot

> A native macOS tool for driving multi-project development progress —
> it dispatches coding tasks to local CLI agents (Codex / Claude Code),
> tracks them through PR review and merge, and keeps GitHub as the single source of truth.

一个 macOS 原生的多项目开发进度管理工具:把开发文档拆成任务,派给本地
编码 agent(Codex CLI / Claude Code)去做,盯着它们走完「开 PR → 审查 → 合并 → 标完成」,
GitHub 是唯一权威来源。

**当前状态:规划阶段,尚未开工。** 这个仓库目前只有工程骨架。

---

## 为什么做这个

现状是一套跑在 DeepSeek Harness(dsh)里的插件,已经完整跑通过整条流水线。
它能用,但有三个问题:

1. **单项目写死** —— 配置里只有一组 `repo` / `repoPath` / `dataDir`
2. **没有主动性** —— 没有调度器,每一步都要人打字触发
3. **绑在 dsh 上** —— dsh 版本迭代很快,配置层还会静默失效

还有一条更痛的:**没有 worktree 隔离,多个执行器只能串行。**

## 核心架构判断:切一刀

整套系统里**真正需要 LLM 的只有两件事** —— 拆任务、审代码。其余全是确定性逻辑。

| 属于哪半 | 内容 | 归谁 |
|---|---|---|
| **确定性** | 任务表、GitHub 状态同步、依赖图、合并闸门、进程管理、作业收尸、看板 | 原生 Swift |
| **需要 LLM** | 从开发文档拆任务、代码审查 | 外部 CLI 或 OpenAI 兼容 API |

这样切的好处:上游工具升级,最坏只影响后者,**降级成「你自己拆、自己审」,
而不是整个系统崩掉**。数据在自己的 JSON 里,PR 在 GitHub 上,一样都不会丢。

## 两层完全不同的 AI 接入

容易混淆的地方,分清楚才好设计扩展点:

| 你想接什么 | 接在哪层 | 形式 |
|---|---|---|
| 另一个终端编码 agent | 实现执行器 | **CLI 适配器**(不是 API Key) |
| 另一个模型来拆任务 / 审代码 | 规划与审查 | **API**(OpenAI 兼容端点) |

## 技术栈

- Swift 6 + SwiftUI + SwiftData
- macOS 14+ / Apple Silicon
- **关闭 App Sandbox** —— 核心行为是 spawn 外部进程,沙箱禁止任意子进程执行。
  已决策不上 App Store,自用 + 个人网站分发。

## 外部依赖

依赖四个外部 CLI,它们各自独立演进:

| 工具 | 用途 |
|---|---|
| `git` | worktree 隔离、分支管理 |
| `gh` | PR 状态、合并闸门 |
| `codex` | 实现执行器 |
| `claude` | 实现执行器 |

**破坏方式往往是静默的** —— JSON 少一个字段、输出格式微调、flag 改名,
程序不会崩,只会行为错误。所以有一套**契约测试**专门断言我们实际依赖的那部分行为,
并且**锁定已验证版本,不使用 `latest` 浮动版本**。

## 路线图(M-Solo 自用版)

```
第一步  工程骨架 + 数据层          不碰外部世界
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
