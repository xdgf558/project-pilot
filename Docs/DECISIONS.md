# 架构决策记录

> 本文件按 v0.2「完成定义」第 4 条维护:数据格式、命令协议或安全边界发生
> 变化时必须补充记录。偏离 v0.2 权威文档的决策也记在这里。
>
> `Docs/THREAT_MODEL.md`、`Docs/DATA_FORMAT.md`、`Docs/RECOVERY.md`
> 属于 P0-07,尚未建立。

---

## ADR-0001:暂不建立 PilotAgent target

**状态:** 已采纳
**日期:** 2026-08-19
**偏离:** v0.2 P0-01(要求 workspace 含 `PilotAgent` target)
**依据:** v0.3 D-01 与「异议 2」

### 背景

v0.2 §1.2 把常驻后台服务 `PilotAgent` 放在 Phase 6,并让 Phase 7-9 依赖它。
v0.3 D-01 主张自用版去掉 Agent 与 XPC,保留作业目录协议、启动确认、收尸、
进程组取消和 PID 身份校验 —— **那些才是「可恢复」的实质**。
v0.3「异议 2」进一步指出:Agent 不该进入 Phase 0-6 的必经路径。

### 决策

不建立 `PilotAgent` target。当前 target 为 `PilotCore`、`PilotInfrastructure`
和 `pilotctl`。

### 理由

**空 target 保留不了任何架构位置。** 决定「以后加 Agent 贵不贵」的是接缝,
不是 target 是否存在。v0.2 已经把接缝设计好了:

- §5 的 `ProjectRepository.execute(_:) async throws -> CommandReceipt` ——
  全 `async throws`、全 `Sendable`,这个形状本身就是照跨进程设计的。
- P1-07:「Agent 模式下 App 只通过 XPC 发送 command;进程内模式**复用同一
  command handler**」—— XPC 从一开始就只是传输层。

只要 command 是 Codable 值类型、带 requestId 和幂等 key,以后套 XPC 就是
新增一个 `ProjectRepository` 实现,业务代码不动。这三件事在 P0-02、P0-03、
P1-07 里,与 target 无关。

反过来,以后补 Agent 真正的成本 —— SMAppService 注册、XPC 协议版本化、
Agent 状态展示、进程内降级、P12-01/02 的嵌套签名顺序 —— **空 target 一样
也省不掉**,只省一次 `project.pbxproj` 编辑。

还有一条隐性代价:target 存在就会招代码。Scheduler 和 JobManager 会很自然
地落进去,于是 M-Solo 不发的 target 里躺着没人跑过的代码路径。

### 代价

- App 关闭时不轮询。已派出的执行器进程照常跑完(detached),只是没人实时
  同步 GitHub,下次打开时同步一次。**自用场景可接受。**
- 单写者不再由「只有 Agent 能写」保证。改由跨进程文件锁保证 ——
  v0.2 §3 写入规则第 5 条本来就要求导入与恢复工具使用跨进程锁,
  **这条不依赖 Agent 存在**,Phase 1 必须实现。

### 回退条件

需要 App 关闭后继续轮询与派工时,把 Agent 作为独立可选阶段加入。
按 v0.3 D-01,届时**作业目录协议不需要改**。

---

## ADR-0002:工程以 SPM 为主,Xcode 工程推迟到需要界面时

**状态:** 已采纳
**日期:** 2026-08-19
**偏离:** v0.2 P0-01(要求建立 Xcode workspace 与多 target)

### 背景

v0.2 P0-01 要求先建 Xcode workspace。但 v0.2 P0-05 同时写明「**纯 Swift
Package 运行 `swift test`**」,v0.3 §7 也确认第一到第四步不产生任何可见界面。

### 决策

1. `PilotCore`、`PilotInfrastructure`、`pilotctl` 全部是同一个 SPM package
   的 target,仓库根目录即 package。
2. **暂不创建 `.xcodeproj`。** 界面在 Phase 8 才需要,届时以独立 Xcode 工程
   链接本 package,并使用 Xcode 16+ 的 synchronized file groups。
3. 新增 `pilotctl` 可执行 target(v0.2 P12-01 的签名清单里已列「命令行工具」)。

### 理由

**这个项目的核心卖点是多个执行器在隔离 worktree 中并行改代码。**
如果日常写代码要改 `project.pbxproj`,并行 PR 会在 pbxproj 上持续冲突,
而那是出了名的难合文件。放进 SPM 后,加文件不碰 pbxproj。
**自己的工具不该被自己的工程结构卡住。**

`pilotctl` 一次解决四件事:

1. **编译期金丝雀** —— 只链接 Core 与 Infrastructure、不碰 UI 框架,
   能编过就证明下面两层没有反向渗入界面依赖。
2. **P2-11 `--live` 契约测试的入口。**
3. **Phase 8 之前的驱动入口** —— 数据层、Git 隔离、合并闸门都靠它验证。
4. 以后 Agent 来了,它是第三个宿主。届时接缝已被两个宿主验证过。

### 代价

- P0-01 退出闸门中的「UI 启动测试」当前不适用,推迟到 Xcode 工程建立时。
- 集成 Xcode 工程时可能发现链接或签名问题。风险低:本地 SPM package 被
  Xcode app target 链接是成熟路径。

### 回退条件

若 Phase 8 集成时出现无法解决的链接或签名问题,退回 v0.2 原方案:
把 Core 与 Infrastructure 改为 Xcode framework target。
届时源码目录结构不变,只改构建系统。
