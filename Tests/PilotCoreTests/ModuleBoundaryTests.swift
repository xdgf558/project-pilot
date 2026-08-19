import Testing
@testable import PilotCore

/// P0-01 占位测试:确认 PilotCore 能被独立链接与测试。
///
/// 这个 target **不依赖** PilotInfrastructure。这不是疏忽 ——
/// 如果哪天 PilotCore 的测试需要 IO,说明纯逻辑层已经被污染了。
@Suite("PilotCore 模块边界")
struct ModuleBoundaryTests {
    @Test("模块标识可用")
    func moduleIdentity() {
        #expect(PilotCore.moduleName == "PilotCore")
    }
}
