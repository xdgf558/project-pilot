import Testing
@testable import PilotCore
@testable import PilotInfrastructure

/// P0-01 占位测试 + P0-02 依赖方向断言。
@Suite("PilotInfrastructure 模块边界")
struct ModuleBoundaryTests {
    @Test("模块标识可用")
    func moduleIdentity() {
        #expect(PilotInfrastructure.moduleName == "PilotInfrastructure")
    }

    /// 依赖方向的运行时对照。
    ///
    /// 编译期的强制来自 `Package.swift`:PilotCore 没有声明任何依赖,
    /// 所以它无法 import 本模块。这条测试断言的是反方向确实通 ——
    /// 也就是说,分层是「上依赖下」,不是两边都没连上。
    @Test("Infrastructure 依赖 Core,方向正确")
    func dependencyDirection() {
        #expect(PilotInfrastructure.dependsOn == PilotCore.moduleName)
    }
}
