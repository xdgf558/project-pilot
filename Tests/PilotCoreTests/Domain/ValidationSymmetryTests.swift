import Foundation
import Testing
import PilotCore
import PilotTestSupport

/// 构造器与解码器的校验必须对称。
///
/// 起因是一个真实缺陷:`EventType` 的解码器拒绝空串,构造器却接受 ——
/// 于是可以造出一条**写得出去、读不回来**的事件。对一个只追加的审计日志,
/// 「可恢复」是它存在的全部理由,而这个不对称正好毁掉它。
///
/// 光靠普通测试抓不到这类问题:`precondition` 会让进程直接中止,
/// 不产生测试失败。这里用 Swift Testing 的 exit test ——
/// 它在子进程里跑,能断言「这段代码应当让进程非正常退出」。
@Suite("构造与解码的校验对称")
struct ValidationSymmetryTests {

    // MARK: - 构造器一侧:非法输入必须让进程中止

    @Test("SchemaVersion 拒绝小于 1")
    func schemaVersionTraps() async {
        await #expect(processExitsWith: .failure) { _ = SchemaVersion(0) }
    }

    @Test("Revision 拒绝负数")
    func revisionTraps() async {
        await #expect(processExitsWith: .failure) { _ = Revision(-1) }
    }

    @Test("ProcessStartIdentity 拒绝空串")
    func identityTraps() async {
        // 空身份会让所有作业互相匹配 —— 比没有身份更危险。
        await #expect(processExitsWith: .failure) { _ = ProcessStartIdentity(rawValue: "") }
    }

    @Test("EventType 拒绝空串")
    func eventTypeTraps() async {
        // 本套件的起因就是这一条原来不存在。
        await #expect(processExitsWith: .failure) { _ = EventType(rawValue: "") }
    }

    @Test("Blocker 拒绝空消息")
    func blockerTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = Blocker(code: .toolMissing, message: "", occurredAt: Date())
        }
    }

    @Test("ReviewFinding 拒绝空说明")
    func findingTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = ReviewFinding(message: "", isBlocking: false)
        }
    }

    // exit test 的闭包会变成 C 函数指针,**不能捕获上下文** ——
    // 所以这里不能参数化,取值必须写成字面量。

    @Test("Job 拒绝进程号 0")
    func jobRejectsZeroPID() async {
        // POSIX 里 kill(0, …) 打的是整个进程组 —— 包括 ProjectPilot 自己。
        await #expect(processExitsWith: .failure) {
            _ = Job(id: UUID(), projectId: UUID(), taskId: UUID(),
                    executor: .claude, executorVersion: "1", authMode: .external,
                    worktreePath: URL(fileURLWithPath: "/tmp"), branchName: "b",
                    processId: 0)
        }
    }

    @Test("Job 拒绝负进程号")
    func jobRejectsNegativePID() async {
        // kill(-1, …) 打当前用户能打的所有进程。
        await #expect(processExitsWith: .failure) {
            _ = Job(id: UUID(), projectId: UUID(), taskId: UUID(),
                    executor: .claude, executorVersion: "1", authMode: .external,
                    worktreePath: URL(fileURLWithPath: "/tmp"), branchName: "b",
                    processId: -1)
        }
    }

    @Test("Event 拒绝小于 1 的序号")
    func eventSequenceTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = Event(id: UUID(), sequence: 0, timestamp: Date(), projectId: UUID(),
                      entityType: OpenEnum(.task), entityId: UUID(),
                      eventType: EventType(rawValue: "x"), actor: OpenEnum(.system))
        }
    }

    // MARK: - 解码器一侧:同样的非法输入必须报 dataCorrupted
    //
    // 上面每一条在构造器侧中止的,这里必须在解码侧也被拒 —— 否则
    // 磁盘上的一份坏数据能绕过构造器的全部检查。

    @Test("解码侧同样拒绝", arguments: [
        ("SchemaVersion", "0"),
        ("Revision", "-1"),
        ("ProcessStartIdentity", "\"\""),
        ("EventType", "\"\""),
    ])
    func decodeRejectsSameInputs(_ type: String, _ json: String) {
        let data = Data(json.utf8)
        let kind: DecodingErrorKind
        switch type {
        case "SchemaVersion":
            kind = decodingErrorKind { _ = try CanonicalJSON.makeDecoder().decode(SchemaVersion.self, from: data) }
        case "Revision":
            kind = decodingErrorKind { _ = try CanonicalJSON.makeDecoder().decode(Revision.self, from: data) }
        case "ProcessStartIdentity":
            kind = decodingErrorKind { _ = try CanonicalJSON.makeDecoder().decode(ProcessStartIdentity.self, from: data) }
        default:
            kind = decodingErrorKind { _ = try CanonicalJSON.makeDecoder().decode(EventType.self, from: data) }
        }
        #expect(kind == .dataCorrupted, "\(type) 的解码器应当拒绝 \(json)")
    }

    @Test("Job 的非正进程号解码时被拒", arguments: [0, -1])
    func decodeRejectsNonPositivePID(_ pid: Int) throws {
        let job = Job(id: UUID(sequenceNumber: 1), projectId: UUID(sequenceNumber: 2),
                      taskId: UUID(sequenceNumber: 3), executor: .codex,
                      executorVersion: "1", authMode: .external,
                      worktreePath: URL(fileURLWithPath: "/tmp"), branchName: "b",
                      processId: 42, status: .running)
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(job)
        let broken = try JSONMutation.replacing(data, key: "processId", with: pid)
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Job.self, from: broken)
        } == .dataCorrupted)
    }

    @Test("纵深防御:字段被改成非正数后,闸门仍然拒绝")
    func mutatedPIDIsNotVerifiable() {
        // 构造器和解码器都会拦下非正的 PID,所以要走到这个分支,
        // 只能靠事后改字段 —— 而 processId 是 var,任何持有者都能改。
        //
        // 这正是纵深防御要防的:某条路径(现在的、或将来新加的)产生了
        // 一个坏 PID,而「可以下手了」这个闸门自己必须再判一次。
        // 它答错的代价是杀掉无关进程,多一次比较的代价是零。
        var job = Job(id: UUID(sequenceNumber: 1), projectId: UUID(sequenceNumber: 2),
                      taskId: UUID(sequenceNumber: 3), executor: .codex,
                      executorVersion: "1", authMode: .external,
                      worktreePath: URL(fileURLWithPath: "/tmp"), branchName: "b",
                      processId: 42,
                      processStartIdentity: ProcessStartIdentity(rawValue: "x"),
                      status: .running)
        #expect(job.hasVerifiableProcessIdentity)

        job.processId = 0
        #expect(job.hasVerifiableProcessIdentity == false, "PID 0 在 POSIX 里是整个进程组")

        job.processId = -1
        #expect(job.hasVerifiableProcessIdentity == false, "负 PID 在 POSIX 里是一批进程")

        job.processId = 42
        job.processStartIdentity = nil
        #expect(job.hasVerifiableProcessIdentity == false, "没有身份时 PID 可能已属于别人")
    }
}
