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

---

## ADR-0003:xunit 测试结果的文件名由上游决定,CI 必须断言产物存在

**状态:** 已采纳
**日期:** 2026-08-19
**触发:** PR #2 审查发现「上传测试结果」实际未交付

### 背景

P0-05 要求 CI「上传测试结果与失败日志」。第一版 CI 写的是
`swift test --xunit-output test-results.xml`,上传 `test-results.xml`。
实际 artifact 里只有 `build.log` 与 `test.log`,**XML 从未被上传**,
而 `if-no-files-found: warn` 把这次缺失降级成一条不显眼的 annotation,CI 照样绿。

### 实测(Swift 6.3.3 / Xcode 26.6 build 17F113)

| 调用 | 产出 |
|---|---|
| `swift test --xunit-output test-results.xml` | 仅 `test-results-swift-testing.xml`,`tests="3"`,内容正确 |
| 加 `--parallel` | 上者,**加上** `test-results.xml`,`tests="0"`(XCTest 用,本项目没有 XCTest) |
| 绝对路径 `/tmp/x-r.xml` | 仍加后缀:`/tmp/x-r-swift-testing.xml` |

**SwiftPM 把 Swift Testing 的结果写到「去掉扩展名 + `-swift-testing.xml`」,
而不是你指定的文件名。** 你指定的那个路径是留给 XCTest 的,且只在 `--parallel` 下生成。

一个反面教训:排查过程中曾误判为「xunit 只覆盖 XCTest,对 Swift Testing 静默忽略」——
那是被 `--parallel` 产生的空 `test-results.xml` 误导。真相是文件一直在生成,
只是名字不同。**用 `find -newermt` 找新文件时也踩了坑:那是 GNU 语法,
BSD find 上静默失效,导致「没有任何 XML 产出」这个错误结论。**

### 决策

1. 继续用 `--xunit-output`,**不加 `--parallel`** —— 加了只会多出一个
   `tests="0"` 的空文件,比没有更误导。
2. 上传路径改为 glob `test-results*.xml`,不写死单个文件名。
3. **CI 硬断言**:至少存在一个 `test-results*.xml`,且其中记录的测试数大于 0。
   任一条不满足就红,并指向本 ADR。
4. 测试数写进 job summary。

### 理由

这正是 v0.3 §3 描述的静默破坏:`--xunit-output` 接受了 flag、退出码 0、
指定路径下什么都没有。**程序不会崩,只会行为错误。**

本工作流对 Xcode 版本漂移主张「降级要可见,不该熔断」(v0.3 异议 1),
而测试结果缺失恰恰是一次不可见的降级 —— 同一套标准必须适用于自己。

断言用 glob 而不是写死后缀:若上游哪天改了命名,glob 仍能捕获;
若上游彻底不再产出,断言会红。两种变化都可见。

### 代价

- `-swift-testing` 后缀不在 `swift test --help` 里,属于未文档化的上游行为,
  可能随工具链变化。断言就是为此存在的。
- 断言依赖 `<testsuite ... tests="N">` 的属性格式。格式若变,断言会误判为 0 并红 ——
  失败方向安全(宁可错杀),且错误信息指向本 ADR。

### 后续

这条属于 v0.3 §3 P2-10 契约测试的范围。Phase 2 建立契约测试套件时,
把「`swift test --xunit-output` 的实际产出文件名与内容」作为一条断言录入,
并用录制的 fixture 离线跑(P2-11)。

### 回退条件

若上游提供了稳定且文档化的测试结果输出(例如 `--xunit-output` 直接写入
指定路径,或 swift-testing 的事件流转正),改用该机制并保留断言。

> 备选方案已验证可用:`swift test --event-stream-output-path <path>
> --event-stream-version 0` 产出 JSON Lines 事件流,含 suite/测试名、
> 源码位置,失败时带 `issueRecorded` 事件。信息比 xunit 更丰富,
> 但该 flag 同样未出现在 `--help` 中,且不是标准格式、GitHub 不原生渲染。
> 当前选 xunit 是因为它是标准 JUnit 格式,工具链生态更通用。
