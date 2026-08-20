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

---

## ADR-0004:测试替身放独立的 PilotTestSupport target

**状态:** 已采纳
**日期:** 2026-08-19
**工作包:** P0-06

### 背景

P0-06 要建立测试替身。放哪里有三个选择。

### 决策

新建 `PilotTestSupport` target,依赖 `PilotCore` 与 `PilotInfrastructure`,
**只被 test target 依赖,且不作为 product 暴露**。

### 理由

| 方案 | 问题 |
|---|---|
| 替身跟着各自协议放进产品模块 | 会跟着产品二进制发出去。一个能注入「磁盘满」的文件系统出现在正式构建里是负债,不只是死重量 |
| 每个 test target 各放一份 | `FakeClock` 要复制两份。Phase 1 起几乎每个测试都要用,两份迟早分叉 |
| **独立 target** | 一份实现,产品不携带 |

这条由 `Scripts/check-module-boundaries.sh` 的**检查 4** 强制,两个方向都挡:
非测试 target 不得依赖它,也不得把它做成 product。
三个失败用例(Core 声明依赖、产品 target 依赖替身、替身被暴露为 product)
都在 `Scripts/test-check-module-boundaries.sh` 里验证过确实会红。

### 代价

替身的改动会触发测试 target 重编。规模很小,可接受。

---

## ADR-0005:三个替身推迟到各自阶段,不在 P0-06 硬造

**状态:** 已采纳
**日期:** 2026-08-19
**偏离:** v0.2 P0-06(列了六个替身,本次交付三个)

### 背景

P0-06 原文要求定义 `FakeProcessRunner`、`FakeGit`、`FakeGitHub`、
`FakeClock`、`FakeFileSystem` 和 deterministic UUID provider。

但替身必须是**某个协议**的替身,而后三个协议依赖的类型现在都不存在:

| 协议(v0.2 §5) | 依赖的类型 | 由谁定义 |
|---|---|---|
| `ProcessRunning` | `ProcessSpecification` / `RunningProcess` / `ProcessIdentity` | P2-03 |
| `GitOperating` | `RepositorySnapshot` / `WorktreeRequest` / `CommitResult` | P3-01 |
| `GitHosting` | `PullRequestSnapshot` | P1-02 |

### 决策

**本次交付:** `FakeClock`、`DeterministicIdentifierProvider`、
`InMemoryFileSystem`(含故障注入),以及它们对应的协议
`TimeSource`、`IdentifierProvider`、`FileSystem`。

**推迟:**

| 替身 | 推迟到 | 那个工作包本来就包含它 |
|---|---|---|
| `FakeProcessRunner` | **P2-09** | 「建立 Fake CLI 套件。可脚本化输出、延迟、秒退、部分写入、非法 JSON、超大日志和信号处理」 |
| `FakeGit` | **P3-01 之后** | RepositorySnapshot 的字段要从真实 git 行为推导 |
| `FakeGitHub` | **P4-08 之后** | PullRequestSnapshot 由 P1-02 定义,字段要经 P4-02 能力探测确认 |

### 理由

v0.2 §11 规则 6:「遇到不确定 schema、第三方 CLI 行为或系统 API 时,
**先生成证据任务,不自行假设**。」

现在造出这三个协议,等于替 P1-02 / P3-01 / P4-08 猜领域模型。
猜错要返工,猜对也是同一个类型定义两遍 —— 两种结果都伤可维护性。
`FakeProcessRunner` 更直接:P2-09 本身就是它的归属,在这里做等于重复。

反过来,交付的三个没有任何猜测成分:
「现在几点」「下一个 UUID」「文件读写与原子替换」都是自足的语义,
不依赖任何领域模型。

**而且交付的这三个恰好是 Phase 1 唯一真正需要的。** P1-12 要求覆盖
「写到一半崩溃、磁盘满、权限拒绝、文件被替换」,全部落在 `InMemoryFileSystem` 上;
P1-01 / P1-02 的时间戳与 UUID 主键落在另外两个上。
Phase 1 不需要 Process、Git 或 GitHub 的替身。

### 代价

- P0-06 的完成定义按 v0.2 原文不算全满足。这一条必须在 Phase 0 收尾时
  连同 P0-04、P0-07、P0-08 一起复核,不能默认它已经关闭。
- 若将来决定把 Phase 2 或 3 提前,需要先补对应替身。

### 一个副产品

`FileSystem` 同时交付了真假两个实现,并由 `FileSystemContractTests`
**同一套用例跑两遍**。这不是额外功夫,是必要条件 ——
只跟自己一致的假实现,证明不了任何关于真实环境的事。
已验证该契约测试有分辨力:故意改错假实现的错误映射,只有假的那边会红。

这套「一份契约,两个实现」的写法就是 v0.2 §6.1 第 2 条
「基础设施 contract tests」的模板,后续 Process、Git、gh 的替身照此办理。

---

## ADR-0006:P0-04 只做 SPM 侧,签名相关部分随 Xcode 工程一起推迟

**状态:** 已采纳
**日期:** 2026-08-19
**偏离:** v0.2 P0-04(还要求 Hardened Runtime 与 entitlements)

### 背景

P0-04 原文:「配置 Debug、Release 和测试环境。**Release 开启 Hardened Runtime;
App 和 Agent 分别管理 entitlements**;v1 明确关闭 App Sandbox。」

后两项在当前工程里**没有对应的东西可配**。Hardened Runtime 是 Xcode target
的构建设置,entitlements 是 target 的 plist —— 而按 ADR-0002 现在没有
`.xcodeproj`,按 ADR-0001 `PilotAgent` 也不存在。SPM 的 `Package.swift`
里没有这两个概念。

### 决策

**本次交付:** Debug 与 Release 两种配置都构建、都跑测试,都进 CI,
都要求零警告。

**推迟到 Xcode 工程建立时(Phase 8 或更早,若提前需要界面):**
Hardened Runtime、App 与 Agent 各自的 entitlements、
显式关闭 App Sandbox 的 entitlement 声明。

### 为什么 Release 值得单独跑,而不只是「再编一遍」

实测(Swift 6.3,SPM 的 Debug 用 `-Onone`、Release 用 `-O`):

| | `-Onone` | `-O` |
|---|---|---|
| `assert()` | 触发,退出 133 | **被整个移除,程序继续运行** |
| `precondition()` | 触发,退出 133 | 触发,退出 133 |

也就是说,写成 `assert` 的不变量检查在发布构建里**等于不存在**。
对一个靠不变量支撑正确性的数据层,只测 Debug 意味着真正发出去的那个构建
从来没有被验证过。优化器也会暴露 Debug 下看不见的警告。

Release 下能跑测试是 P0-06 那轮审查的意外收益 —— 当时按建议把
`@testable import` 改回普通 `import`,而 `@testable` 正是 Release 测试编不过的原因。

### 为什么没有禁止 `assert()`

考虑过在边界检查里禁掉 `Sources/` 下的 `assert(`。没做,理由是
`assert` 有正当用途:开发期的昂贵自查,失效了也不影响正确性。
一刀切禁掉是发明 v0.2 没有的政策。

改为写进执行器规则(第 6 节),并靠 **Release 也跑测试**来提供实际防线 ——
若有测试依赖 `assert` 触发,Release 那一遍会红。

若将来发现 `assert` 被误用于真正的不变量,再加硬检查。

### 代价

- **Phase 0 退出闸门中的「Release 配置可以完成本地签名构建」当前不满足。**
  这条与 P0-06 的推迟部分一样,必须在 Phase 0 收尾时复核,不能默认已关闭。
- CI 时间约翻倍(构建与测试各跑两遍)。公开仓库跑标准 runner 不计费,
  实测三次运行的计费分钟均为 0,这个代价可以接受。

### 回退条件

Xcode 工程建立后,把 Hardened Runtime 与 entitlements 补齐,
并在 Phase 12 的签名清单(P12-01)里核对。

---

## ADR-0007:权威数据的 JSON 编码规则

**状态:** 已采纳
**日期:** 2026-08-19
**工作包:** P1-01

### 背景

v0.2 §3 规定权威数据是版本化 JSON 快照,写入规则第 1 条要求
`state.json` 含 schemaVersion、revision、lastEventSequence 和校验信息,
第 9 条要求「JSON 解码保留未知字段」。但没有规定编码细节 ——
而编码细节决定了校验和能不能成立。

### 实测证据

两条决定不是偏好,是被数据逼出来的。

**键顺序:** 不加 `.sortedKeys` 时,同样的输入编出来的字节不稳定。
分三种场景实测:

| 场景 | 8 次编码得到几种结果 |
|---|---|
| 跨进程(同一二进制跑 5 次) | 4 种 |
| 同进程,每次新建 encoder | 1 种(稳定) |
| **同进程,复用同一个 encoder 实例** | **8 种 —— 每次都不同** |

**最糟的那种恰好是最自然的用法:建一次 encoder 反复用。**

审查前这里写的原因是「哈希种子每次启动都变」。那个解释是错的 ——
它会让人以为「只要在同一个进程里就没问题」,而实测正相反:
复用 encoder 实例时,连续两次编码同一份数据就已经字节不同。

**时间戳精度:** 对 `1755600000.123456` 这个时刻做往返:

| 策略 | 往返误差 |
|---|---|
| `.iso8601` | −0.123456 秒(亚秒全丢) |
| ISO8601 + `.withFractionalSeconds` | −0.00046 秒(只到毫秒) |
| 默认 `.deferredToDate`(Double) | **0** |

### 决策

1. **必须 `.sortedKeys`。** 否则同样的数据每次写出不同字节:
   校验和无法成立,而且每次写入都产生一个内容没变的假 diff。
2. **时间戳用默认的 `.deferredToDate`,不用任何 ISO8601 变体。**
3. 快照用 `.prettyPrinted`(损坏时能定位到行,diff 可读);
   事件日志不用 —— NDJSON 要求一条事件占一行。
4. 校验和用 **FNV-1a 64**,以 16 位十六进制**字符串**写入。
5. **envelope 只携带校验和,不计算也不验证。**
6. 顶层未知字段进 `unknownFields`,编码时原样写回。

### 为什么校验和用字符串而不是 JSON 数字

`UInt64` 超出 JSON 数字能精确表达的范围。走一趟 Double 就可能丢低位 ——
一个用来检测损坏的字段自己先被损坏了。

### 为什么 envelope 不自己验证校验和

让它在解码时重新编码一遍 payload 来对比,看着更自足,实际上把
「校验和正确」建立在「重新编码必然字节相同」这个更强的假设上。
任何字段的编码行为一变,**数据会被误判为损坏**。

宁可让分工显式:计算和验证归仓库层(P1-05),它知道实际写进磁盘的字节。
前提条件(规范编码往返字节稳定)由测试保证。

### 为什么是 FNV-1a 而不是 CRC32 或 SHA

这是**检测损坏**,不是防篡改 —— 本地单用户数据里,任何人都能改了内容
再重算一遍校验和。要防的是磁盘坏块、写到一半崩溃这类情况。

密码学哈希要 CryptoKit,而 `PilotCore` 只允许标准库和 Foundation(P0-02)。
FNV-1a 二十行纯 Swift 写得完,输出确定,有公开测试向量。

### 代价

**原始文件里的时间戳人读不懂**,是 `777292800.123456` 而不是
`2025-08-19T10:40:00Z`。这个代价是主动选的:精度损失一旦发生不可逆,
而可读性可以由 P1-11 的恢复工具补上 —— 那个工作包本来就要做
「只读打开、错误定位」的界面。

### 一个测试上的教训

最初的校验和测试只断言空输入等于 offset basis。实测发现:**故意改掉
FNV 的 prime,零条测试会红** —— 因为空输入根本不经过乘法。
补上了规范公布的三组测试向量(`""`、`"a"`、`"foobar"`),
且向量是独立按规范算出来的,不是从本实现取的,否则是循环论证。

算法一旦悄悄变了,所有已存的校验和全部失效,而且没有任何东西会报错。

### 回退条件

若将来需要跨机器同步或防篡改,把 FNV-1a 换成 SHA-256 ——
届时哈希计算移到 `PilotInfrastructure`(那里可以用 CryptoKit),
`Checksum` 类型本身不变。

---

## ADR-0008:任务类型改名为 `PilotTask`

**状态:** 已采纳
**日期:** 2026-08-19
**偏离:** v0.2 §2.2(那里叫 `Task`)
**工作包:** P1-02

### 背景

v0.2 §2.2 把任务类型命名为 `Task`。但 Swift 并发已经占了这个名字。

### 实测

冲突方向对我们不利 —— 不是歧义警告,是导入方**直接编译错误**:

```
User.swift:4:16: error: type 'Task' has no member 'detached'
```

也就是说,任何 `import PilotCore` 的模块里,`Task.detached`、`Task { }`
都会解析到我们这个领域类型。而 v0.2 §5 的协议全是 `async throws` ——
`PilotInfrastructure`、`pilotctl`、测试都要大量使用 Swift 并发。

其余六个类型名(`Project`、`Blocker`、`Job`、`Event`、`ReviewRecord`、
`PullRequestSnapshot`)与 `TaskStage` 实测均无冲突,保持 v0.2 原名。

### 决策

叫 `PilotTask`。

### 为什么是加前缀,不是换个名词

考虑过 `WorkItem`、`TaskRecord` 之类。否掉的理由:**v0.2 是所有人和所有
执行器的共同参照**,词汇分叉的成本比一个前缀高 —— 每个读 v0.2 的人
都要在脑子里做一次翻译,而翻译表本身没有地方存。

也考虑过嵌套成 `Pilot.Task`。否掉是因为只有这一个类型需要嵌套,
其余六个不需要,混着用比统一加前缀更难读。

**没有加 `typealias Task = PilotTask`** —— 那会把冲突原样带回来。

### 代价

代码里的名字与权威文档的名字不一致。任何拿到「按 v0.2 §2.2 实现 Task」
这类工作包的人或执行器,都需要知道这条对应关系,而唯一的地方就是这份 ADR。

### 回退条件

若 Swift 将来改变名字解析规则,让本地模块类型不再压过 `_Concurrency.Task`,
可以改回 `Task`。届时是一次大范围重命名,但不涉及数据格式 ——
类型名不进 JSON。

---

## ADR-0009:领域模型刻意不做的三种校验

**状态:** 已采纳
**日期:** 2026-08-19
**工作包:** P1-02

这三条都属于「看起来该做、但被明确否决」。不写下来,将来一定有人
「好心」补上,而每一条补上都会造成具体的坏结果。

### 一、`remoteHost` 不限制为 `github.com`

v0.2 §0.3 说 v1 只支持 GitHub.com。字面读法是应该在模型层拒绝其他 host。

**但 §2.4 同时定义了 `unsupportedRepository` 这个 blocker** ——
说明不支持的仓库是**能被存下来、并作为阻塞展示**的,不是在数据层拒绝。

补上校验的后果很具体:用户接入一个 GitLab 仓库时,系统给不出
「这个仓库暂不支持,因为 v1 只对接 GitHub」这种可操作的信息,
只能在解码时抛一个 `dataCorrupted`,或者在构造时 precondition 崩掉。
那正是 v0.2 完成定义第 3 条禁止的「不可操作的错误信息」。

**校验属于接入流程(P3-02 仓库信任、P11-01 接入向导),不属于数据层。**

### 二、`SchedulerMode.automatic` 保留在枚举里

v0.3 D-02 说 M-Solo 只做到 `assisted`,`automatic` 涉及租约、公平性、
预算保护和崩溃恢复,是 v0.2 里最重的一块。

字面读法是枚举里不该有 `automatic`。但**数据模型按 v0.2 定,实现范围按
v0.3 定** —— 现在删掉,将来加回来就是一次数据格式变更,
已存的文件要迁移,而这个变更本可以避免。

调度器不实现 `automatic` 是调度器的事(P7-01),不是数据模型的事。

### 三、依赖的合法性不在 `PilotTask` 里判

自依赖、缺失的依赖、跨项目非法依赖、循环 —— 这些都要**看到整张图**才能判断,
单个任务判断不了。放在这里只能做到「id 不等于自己」这一种,
而那会给人一种「依赖已经校验过了」的错觉。

完整检测在 P5-03,它要求「写入前检测并返回完整环路径」。

### 代价

模型能表示一些业务上非法的状态(指向不支持的仓库、依赖不存在的任务)。
这是有意的:**非法状态要能被存下来并解释给用户,而不是无法表示。**
代价是每个消费方都不能假设「能构造出来就是合法的」。

### 回退条件

若将来发现某条校验放在数据层确实更好(例如非法状态泄漏到了太多地方),
再单独讨论。前提是同时给出「非法数据怎么呈现给用户」的方案 ——
不能只是拒绝。

---

## ADR-0010:`isAutomaticallyRecoverable` 推导而不落盘

**状态:** 已采纳
**日期:** 2026-08-19
**工作包:** P1-02

### 背景

v0.2 §2.4 要求每个 Blocker 包含「是否可自动恢复」。

### 决策

做成 `BlockerCode` 的计算属性,**不作为字段存进 JSON**。

### 理由

存下来就意味着分类可以和行为不一致。重新分类之后,旧记录仍带着旧答案 ——
同一种阻塞在界面上会有两种表现,而且看不出为什么。

**分类是行为,不是数据。** 数据是「发生了什么」(code、时间、关联对象),
行为是「我们怎么对待它」。后者应当随代码走。

### 分类原则

不确定的一律归到「不可自动恢复」。跟用户说「它会自己好」结果没好,
比说「你去看一眼」结果发现不用管更伤信任。

当前判为可自动恢复的只有三种:`dependencyNotCompleted`、
`requiredChecksPending`、`pullRequestDraft`。整个集合写死在测试里,
改分类必须在 diff 里显形。

### 代价

若将来某条 blocker 需要**按实例**决定是否可自动恢复(而不是按 code),
这个设计不够用。届时要加一个可选的实例级覆盖字段,而不是把整个分类落盘。

### 回退条件

P5-01 推导状态时可能细化分类,以那里为准。若发现按 code 分类确实不够,
按上一段的方式扩展。
