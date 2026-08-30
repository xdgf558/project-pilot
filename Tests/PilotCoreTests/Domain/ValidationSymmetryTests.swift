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

    // MARK: - 改字段之后仍然写得出读得回
    //
    // 起因:`Job.processId` 等字段原本是 public var,构造器和解码器都校验了,
    // 但**对象造出来之后还能直接写进非法值** —— 合成的 Encodable 照单全收,
    // 自定义解码器却拒绝。于是能产生「写得出去、读不回来」的权威快照。
    //
    // 实测当时有七处这样的洞:Job 的 processId 与 branchName、
    // ReviewFinding.message、PilotTask 的 title 与 pullRequestNumber、
    // Project 的 name 与 projectConcurrency。
    //
    // 修法是让非法状态**在编译期就写不出来**:不变的字段改 let,
    // 会变的改 private(set) 并配一个校验过的方法。
    // 下面这些用例守的是「合法的改动仍然能往返」——
    // 非法的那一半现在由编译器拦,写不出测试来。

    private func assertRoundTrips<T: Codable & Equatable>(_ value: T, _ label: Comment) throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(value)
        #expect(try CanonicalJSON.makeDecoder().decode(T.self, from: data) == value, label)
    }

    @Test("attachProcess 之后仍可往返")
    func attachProcessRoundTrips() throws {
        var job = Job(id: UUID(sequenceNumber: 1), projectId: UUID(sequenceNumber: 2),
                      taskId: UUID(sequenceNumber: 3), executor: .codex,
                      executorVersion: "1", authMode: .external,
                      worktreePath: URL(fileURLWithPath: "/tmp"), branchName: "b",
                      status: .starting)
        job.attachProcess(id: 71439, identity: ProcessStartIdentity(rawValue: "1787196028.492046"))
        #expect(job.hasVerifiableProcessIdentity)
        try assertRoundTrips(job, "attach 之后")

        job.detachProcess()
        // 两个字段必须一起清 —— 只清一个会留下「有 PID 没身份」这种危险状态。
        #expect(job.processId == nil)
        #expect(job.processStartIdentity == nil)
        #expect(job.hasVerifiableProcessIdentity == false)
        try assertRoundTrips(job, "detach 之后")
    }

    @Test("取不到进程身份时也能记录,但不算可核验")
    func attachWithoutIdentity() throws {
        // 取身份可能失败(sysctl 出错)。那种情况必须能被记录下来,
        // 而不是假装没有进程 —— 但也绝不能被当成可以下手。
        var job = Job(id: UUID(sequenceNumber: 1), projectId: UUID(sequenceNumber: 2),
                      taskId: UUID(sequenceNumber: 3), executor: .codex,
                      executorVersion: "1", authMode: .external,
                      worktreePath: URL(fileURLWithPath: "/tmp"), branchName: "b",
                      status: .starting)
        job.attachProcess(id: 71439, identity: nil)
        #expect(job.processId == 71439)
        #expect(job.hasVerifiableProcessIdentity == false)
        try assertRoundTrips(job, "有 PID 无身份")
    }

    @Test("attachProcess 拒绝进程号 0")
    func attachRejectsZero() async {
        await #expect(processExitsWith: .failure) {
            var job = Job(id: UUID(), projectId: UUID(), taskId: UUID(),
                          executor: .codex, executorVersion: "1", authMode: .external,
                          worktreePath: URL(fileURLWithPath: "/tmp"), branchName: "b")
            job.attachProcess(id: 0, identity: nil)
        }
    }

    @Test("改标题后仍可往返")
    func renameTaskRoundTrips() throws {
        var task = PilotTask(id: UUID(sequenceNumber: 1), projectId: UUID(sequenceNumber: 2),
                             displayNumber: 1, title: "旧标题", type: .code,
                             completionPolicy: .mergedPR,
                             createdAt: Date(timeIntervalSince1970: 0),
                             updatedAt: Date(timeIntervalSince1970: 0))
        task.rename(to: "新标题")
        #expect(task.title == "新标题")
        try assertRoundTrips(task, "改名之后")
    }

    @Test("rename 拒绝空标题")
    func renameRejectsEmpty() async {
        await #expect(processExitsWith: .failure) {
            var task = PilotTask(id: UUID(), projectId: UUID(), displayNumber: 1,
                                 title: "t", type: .code, completionPolicy: .mergedPR,
                                 createdAt: Date(), updatedAt: Date())
            task.rename(to: "")
        }
    }

    @Test("绑定与解绑 PR 后仍可往返")
    func bindPullRequestRoundTrips() throws {
        var task = PilotTask(id: UUID(sequenceNumber: 1), projectId: UUID(sequenceNumber: 2),
                             displayNumber: 1, title: "t", type: .code,
                             completionPolicy: .mergedPR,
                             createdAt: Date(timeIntervalSince1970: 0),
                             updatedAt: Date(timeIntervalSince1970: 0))
        task.bindPullRequest(number: 42)
        #expect(task.pullRequestNumber == 42)
        try assertRoundTrips(task, "绑定之后")

        task.unbindPullRequest()
        #expect(task.pullRequestNumber == nil)
        try assertRoundTrips(task, "解绑之后")
    }

    @Test("bindPullRequest 拒绝 0")
    func bindRejectsZero() async {
        await #expect(processExitsWith: .failure) {
            var task = PilotTask(id: UUID(), projectId: UUID(), displayNumber: 1,
                                 title: "t", type: .code, completionPolicy: .mergedPR,
                                 createdAt: Date(), updatedAt: Date())
            task.bindPullRequest(number: 0)
        }
    }

    @Test("改项目名与并发上限后仍可往返")
    func projectMutationsRoundTrip() throws {
        var project = Project(id: UUID(sequenceNumber: 1), name: "旧名",
                              repositoryPath: URL(fileURLWithPath: "/tmp"),
                              remoteHost: "github.com", owner: "o", repository: "r",
                              defaultBranch: "main", repositoryPolicy: .personal,
                              createdAt: Date(timeIntervalSince1970: 0),
                              updatedAt: Date(timeIntervalSince1970: 0))
        project.rename(to: "新名")
        project.setConcurrency(3)
        #expect(project.name == "新名")
        #expect(project.projectConcurrency == 3)
        try assertRoundTrips(project, "改动之后")
    }

    @Test("setConcurrency 拒绝 0")
    func setConcurrencyRejectsZero() async {
        // 想让项目停下来用暂停,不是把上限设成 0 ——
        // 那样「暂停了」和「配置错了」在数据上分不开。
        await #expect(processExitsWith: .failure) {
            var project = Project(id: UUID(), name: "n",
                                  repositoryPath: URL(fileURLWithPath: "/tmp"),
                                  remoteHost: "github.com", owner: "o", repository: "r",
                                  defaultBranch: "main", repositoryPolicy: .personal,
                                  createdAt: Date(), updatedAt: Date())
            project.setConcurrency(0)
        }
    }
}
