import PilotCore

/// `PilotInfrastructure` 是确定性平台与外部世界之间的唯一通道。
///
/// ## 职责
///
/// 这里将来会放:`ProjectStore`(JSON 快照 + NDJSON 事件日志)、
/// `SafeProcessRunner`、`CommandResolver`、`GitAdapter`、`GitHubAdapter`
/// 以及各执行器适配器。
///
/// ## 边界(P0-02)
///
/// 可以依赖 `PilotCore`,**不能被 `PilotCore` 依赖**。
///
/// 一切触碰外部世界的动作都必须经过本模块,并遵守 v0.2 §4.1:
/// 只使用绝对可执行路径和参数数组,**禁止拼接 shell 命令字符串**。
public enum PilotInfrastructure: Sendable {
    /// 模块标识,供跨模块链接测试使用。
    public static let moduleName = "PilotInfrastructure"

    /// 本模块依赖的下层模块标识。用于验证依赖方向与 `Package.swift` 声明一致。
    public static let dependsOn = PilotCore.moduleName
}
