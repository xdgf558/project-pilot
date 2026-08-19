/// `PilotCore` 是确定性平台的纯逻辑层。
///
/// ## 边界(P0-02)
///
/// 允许:Swift 标准库、Foundation 的值类型(`Date`、`UUID`、`Data`、`URL`、
/// `JSONEncoder`/`JSONDecoder`)。
///
/// **禁止**:`Process`、`FileManager`、`URLSession`、`FileHandle`、`Pipe`、
/// 任何 UI 框架、任何 XPC。本模块不做 IO,不认识外部世界。
///
/// 这条边界不是洁癖 —— 它保证状态机、依赖图、合并准备度和调度策略
/// 可以在没有磁盘、没有网络、没有 Git 仓库的情况下被完整测试。
/// Phase 5 的决策表测试和属性测试全部依赖这一点。
///
/// 依赖方向由 SPM 在编译期强制(本 target 没有声明任何依赖);
/// 上述符号禁令由 `Scripts/check-module-boundaries.sh` 在 CI 中检查。
public enum PilotCore: Sendable {
    /// 模块标识,供跨模块链接测试使用。
    public static let moduleName = "PilotCore"
}
