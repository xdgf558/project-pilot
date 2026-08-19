import Foundation
import PilotCore
import PilotInfrastructure

// `pilotctl` 是 ProjectPilot 的命令行宿主。
//
// 它承担三件事:
//
// 1. **编译期金丝雀** —— 只链接 PilotCore 与 PilotInfrastructure,不碰任何 UI
//    框架。它能编过,就证明下面两层没有反向渗入界面依赖。
// 2. **契约测试的 `--live` 入口**(P2-11)—— 对真实外部 CLI 跑一遍断言,
//    由人主动触发,不进 CI。
// 3. **Phase 8 之前的驱动入口** —— 界面要到 Phase 8 才有,在那之前
//    数据层、Git 隔离和合并闸门都靠这里验证。
//
// 目前只实现 version 与 modules 两个子命令,足以支撑 P0-01 的退出闸门。
// 参数解析暂不引入 swift-argument-parser:Phase 0 保持零外部依赖,
// 引入时按 v0.2 §11 规则 8 单独写 ADR 并锁定版本。

let version = "0.0.0-dev"

func printUsage() {
    print("""
    pilotctl \(version)

    用法:
      pilotctl version     打印版本
      pilotctl modules     打印已链接模块与依赖方向
      pilotctl help        打印本说明
    """)
}

let arguments = CommandLine.arguments.dropFirst()

switch arguments.first {
case "version":
    print(version)

case "modules":
    // 打印实际链接到的模块链。依赖方向若与 Package.swift 声明不符,这里会立刻暴露。
    print("pilotctl -> \(PilotInfrastructure.moduleName) -> \(PilotCore.moduleName)")
    precondition(
        PilotInfrastructure.dependsOn == PilotCore.moduleName,
        "依赖方向与声明不符"
    )

case "help", "--help", "-h", nil:
    printUsage()

case let unknown?:
    // 未知子命令必须以非零退出码失败,否则脚本会把打字错误当成功。
    FileHandle.standardError.write(Data("未知子命令:\(unknown)\n\n".utf8))
    printUsage()
    exit(2)
}
