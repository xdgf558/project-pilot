# 剩余任务盘点(ROADMAP)

> **本文件是快照,不是权威。** 权威任务清单在 v0.2(外部文档)。
> 这里是 2026-09-03 从仓库内证据(PR 历史、ADR、代码与文档里的工作包引用)重建的全景,
> 用来回答「还剩什么、下一步先做哪个」。
>
> **更新时机:阶段收尾时更新,不逐 PR 维护** —— 逐 PR 维护一份必然过时的清单,
> 比一份明确标注了快照日期的清单更危险。

## 已完成(12 个 PR)

| 阶段 | 内容 | PR |
|---|---|---|
| Phase 0 | P0-01/02/03 工程骨架 + 模块边界 | #1 |
| Phase 0 | P0-05 GitHub Actions CI(xunit 产物断言) | #2 |
| Phase 0 | P0-06 测试替身与 FileSystem 契约 | #3 |
| Phase 0 | P0-04 Debug 与 Release 都构建都测试 | #6 |
| Phase 0 | P0-08 执行器规则权威源与漂移检查 | #4 |
| 工具 | 变异探针 mutation-probe(含权限保持、中断安全) | #9 |
| Phase 1 | P1-01 版本化数据 envelope 与规范 JSON 编码 | #7 |
| Phase 1 | P1-02a 任务侧领域模型(Project / PilotTask / TaskStage / Blocker) | #8 |
| Phase 1 | P1-02b 执行与审查侧领域模型(Job / ReviewRecord / PullRequestSnapshot / Event / OpenEnum) | #10 |
| CI | Xcode 27 beta 工具链与开发机对齐 | #11 |
| CI 工具链 | Swift 6.4 下 xunit 少报 155 个测试的静默漏报修复;探针权限保持(第 7 个缺陷) | #12 |
| docs | README 跟上仓库现状 | #5 |

领域模型(P1-02)全部就位:162+ 测试、13 份 ADR。存储层(快照仓库、事件日志)还没有。

## 当前打开

无。(2026-09-03:PR #12 已合并,cb57767。)

## Phase 0 收尾前必须复核(ADR-0006,不能默认已关闭)

- 🔴 退出闸门「Release 配置可完成本地签名构建」**当前不满足** ——
  Hardened Runtime / entitlements 随 Xcode 工程推迟(Phase 8)。
- **P0-07 尚未建立**(DECISIONS.md 卷首明确标注)。
- 复核时与 P0-04、P0-08 的遗留项一起过,见 ADR-0006 的代价一节。

## Phase 1 剩余(模型已就位,存储层全空)

按依赖顺序:

1. **P1-03** 状态转换 reducer —— TaskStage / JobStatus 的合法转换;
   v0.2 §2.8 七种「必须带 reason」的情况也由这层强制(模型层判断不了 eventType 属不属于那七种)。
2. **P1-05** 快照仓库 —— 原子写、revision 乐观校验、**校验和的计算与验证**
   (P1-01 只定义了 `Checksum` 类型,当前无人计算无人验证,是占位)。
3. **P1-06** 事件日志与重放(NDJSON、sequence 游标、快照重放起点)。
4. **P1-07** 命令层(App 经 XPC、进程内复用同一命令层,ADR-0001 的边界)。
5. **P1-11** 恢复工具(只读打开、错误定位、可读时间戳 —— P1-01 选 Double 时间戳欠下的可读性在这里还)。
6. **P1-12** 健壮性覆盖:10 个并发 command、写到一半崩溃、磁盘满
   (InMemoryFileSystem 的故障注入与确定性标识已备好,就是为这个)。
7. **P1-09 / P1-10** 旧版 `tasks.json` 导入 —— ⚠️ **被阻塞**:需先从 dsh 插件提取真实
   schema(v0.2 §10 未决信息第 1 条)。这项外部信息不解决,导入做不了。

## Phase 2-7(执行链路)

- **P2-03** 进程身份(`sysctl kern.proc.pid` 微秒级,实测依据已记在 `ProcessStartIdentity` 文档)
- **P2-04** EnvironmentPolicy(apiKey 不进作业文件 / 日志 / 事件)
- **P2-09** FakeProcessRunner(ADR-0005 推迟到此)
- **P2-10** git / gh 版本契约基线;**P2-11** `--live` 契约测试入口(pilotctl 已留位)
- **P3-01** 仓库路径解析;**P3-02** 仓库信任(未信任禁启动执行器)
- **P4-02** 能力探测;**P4-03** 降级可见;**P4-09** 自审降级明示;**P4-11** protected 仓库
  (P4-08 之后再做 FakeGitHub,等 P4-02 确认字段,ADR-0005)
- **P5-01** 状态推导(可能细化 `isAutomaticallyRecoverable`,ADR-0010);**P5-03** 依赖图校验
  (自依赖 / 循环 / 跨项目,要求返回完整环路径);**P5-05** 审查绑定 head SHA;
  **P5-06** 合并闸门;**P5-08** `--match-head-commit`;**P5-12** 属性测试(stage 不回退)
- **P6-02** 幂等(requestId);**P6-06** 进程身份;**P6-07** 收尸(orphaned 已建模待实现);
  **P6-12** 认证状态展示
- **P7-01** 调度器(v0.3 D-02:automatic 不做);**P7-03** 等待时间排序;**P7-06** 重试策略(按 failureCode)

## Phase 8-12(远期;M-Solo 有裁剪)

- **Phase 8** Xcode 工程 + 界面(P8-04 findings 展示)—— 届时补 Hardened Runtime / entitlements,
  兑现 ADR-0006 的回退条件
- **Phase 10** 整个推迟(v0.3 D-03):P10-04 缺验收标准检查、P10-08 findings 丰富结构、
  P10-09、P10-12 prompt 回放
- **Phase 11** P11-01 接入向导
- **Phase 12** P12-01 签名清单;P12-13

## 建议顺序

1. ~~合并 PR #12~~(已完成 —— 堵 CI 静默漏报)
2. **P1-03 reducer** —— P1-05 / P1-06 的前置。
3. **P1-05 快照仓库** —— 校验和占位拖越久,「格式基准」与实现偏差的风险越大。
4. **P1-06 事件日志** → 随后拦截 dsh 插件 schema 提取,解阻塞 P1-09 / P1-10。
5. **Phase 0 收尾复核**(签名闸门 + P0-07)—— ADR-0006 里那笔不能默认关闭的账。
