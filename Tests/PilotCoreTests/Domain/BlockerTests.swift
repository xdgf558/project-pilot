import Foundation
import Testing
import PilotCore
import PilotTestSupport

@Suite("Blocker")
struct BlockerTests {

    private func makeBlocker(
        code: BlockerCode = .dependencyNotCompleted,
        message: String = "依赖任务 #3 尚未完成"
    ) -> Blocker {
        Blocker(
            code: code,
            message: message,
            occurredAt: Date(timeIntervalSince1970: 1000),
            relatedEntityId: UUID(sequenceNumber: 3)
        )
    }

    @Test("往返相等")
    func roundTrips() throws {
        let original = makeBlocker()
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(original)
        #expect(try CanonicalJSON.makeDecoder().decode(Blocker.self, from: data) == original)
    }

    @Test("关联对象可以为空")
    func relatedEntityIsOptional() throws {
        let blocker = Blocker(code: .toolMissing, message: "找不到 gh", occurredAt: Date())
        #expect(blocker.relatedEntityId == nil)
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(blocker)
        #expect(try CanonicalJSON.makeDecoder().decode(Blocker.self, from: data) == blocker)
    }

    @Test("空消息解码失败")
    func rejectsEmptyMessage() {
        let bad = """
        {"code":"toolMissing","message":"","occurredAt":0}
        """
        // 没有可读消息的 blocker 在界面上只能显示一个 code,
        // 那正是 v0.2 完成定义第 3 条禁止的「不可操作的错误信息」。
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Blocker.self, from: Data(bad.utf8))
        } == .dataCorrupted)
    }

    @Test("code 是未知值时解码失败")
    func rejectsUnknownCode() {
        let bad = """
        {"code":"somethingNew","message":"x","occurredAt":0}
        """
        // 未知 code 不能被当成某个已知值,也不能被忽略 ——
        // 那会让一条真实的阻塞在界面上消失。
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Blocker.self, from: Data(bad.utf8))
        } == .dataCorrupted)
    }

    @Test("occurredAt 类型不符时报 typeMismatch")
    func rejectsWrongTypeForDate() {
        let bad = """
        {"code":"toolMissing","message":"x","occurredAt":"不是数字"}
        """
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Blocker.self, from: Data(bad.utf8))
        } == .typeMismatch)
    }

    // MARK: - 自动恢复分类

    @Test("可自动恢复的恰好是这三种")
    func automaticallyRecoverableSetIsPinned() {
        // 写死整个集合而不是逐个断言:改分类必须在 diff 里显形。
        // 编译器已经保证 switch 穷尽,这里保证的是**分到哪一边**。
        let recoverable = Set(BlockerCode.allCases.filter(\.isAutomaticallyRecoverable))
        #expect(recoverable == [.dependencyNotCompleted, .requiredChecksPending, .pullRequestDraft])
    }

    @Test("需要人介入的一律不标可自动恢复")
    func humanActionCodesAreNotRecoverable() {
        // 这几条尤其不能标成可自动恢复 —— 跟用户说「它会自己好」结果没好,
        // 比说「你去看一眼」结果发现不用管更伤信任。
        for code in [BlockerCode.repositoryUntrusted, .toolMissing, .authenticationRequired,
                     .mergeConflict, .requiredChecksFailed, .manualPause, .budgetExceeded] {
            #expect(code.isAutomaticallyRecoverable == false, "\(code.rawValue)")
        }
    }

    @Test("Blocker 的便捷属性与 code 一致")
    func instancePropertyMatchesCode() {
        #expect(makeBlocker(code: .manualPause).isAutomaticallyRecoverable == false)
        #expect(makeBlocker(code: .requiredChecksPending).isAutomaticallyRecoverable == true)
    }

    // MARK: - 落盘格式

    @Test("全部 17 个 code 的 raw value 写死")
    func rawValuesArePinned() {
        // raw value 就是落盘格式。改一个 case 名等于改数据格式,
        // 已存的文件会解码失败 —— 这条让那种改动在 diff 里显形。
        #expect(BlockerCode.allCases.count == 17)
        #expect(Set(BlockerCode.allCases.map(\.rawValue)) == [
            "dependencyNotCompleted", "invalidDependency", "dependencyCycle",
            "repositoryUntrusted", "toolMissing", "authenticationRequired",
            "workspaceDirty", "pullRequestClosed", "pullRequestDraft",
            "mergeConflict", "requiredChecksPending", "requiredChecksFailed",
            "reviewStale", "jobFailed", "budgetExceeded", "manualPause",
            "unsupportedRepository",
        ])
    }
}
