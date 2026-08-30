import Foundation
import Testing
import PilotCore
import PilotTestSupport

@Suite("Job")
struct JobTests {

    private func makeJob(
        attempt: Int = 1,
        status: JobStatus = .running,
        processId: Int32? = 71439,
        identity: ProcessStartIdentity? = ProcessStartIdentity(rawValue: "1787196028.492046")
    ) -> Job {
        Job(
            id: UUID(sequenceNumber: 1),
            projectId: UUID(sequenceNumber: 100),
            taskId: UUID(sequenceNumber: 12),
            attempt: attempt,
            executor: .claude,
            executorVersion: "2.0.1",
            model: "claude-opus-5",
            authMode: .subscription,
            worktreePath: URL(fileURLWithPath: "/tmp/worktrees/pilot-12"),
            branchName: "phase1/p1-05-snapshot-store",
            processId: processId,
            processStartIdentity: identity,
            status: status,
            startedAt: Date(timeIntervalSince1970: 1000),
            heartbeatAt: Date(timeIntervalSince1970: 1030),
            resultPath: URL(fileURLWithPath: "/tmp/jobs/1/result.json"),
            stdoutPath: URL(fileURLWithPath: "/tmp/jobs/1/stdout.log"),
            stderrPath: URL(fileURLWithPath: "/tmp/jobs/1/stderr.log")
        )
    }

    @Test("往返相等")
    func roundTrips() throws {
        let original = makeJob()
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(original)
        #expect(try CanonicalJSON.makeDecoder().decode(Job.self, from: data) == original)
    }

    @Test("排队中的作业没有进程信息也能往返")
    func queuedJobRoundTrips() throws {
        let queued = Job(
            id: UUID(sequenceNumber: 2), projectId: UUID(sequenceNumber: 100),
            taskId: UUID(sequenceNumber: 13), executor: .codex,
            executorVersion: "0.9.0", authMode: .apiKey,
            worktreePath: URL(fileURLWithPath: "/tmp/w"), branchName: "x",
            status: .queued
        )
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(queued)
        let decoded = try CanonicalJSON.makeDecoder().decode(Job.self, from: data)
        #expect(decoded == queued)
        #expect(decoded.processId == nil)
        #expect(decoded.processStartIdentity == nil)
    }

    // MARK: - 进程身份

    @Test("只有 PID 没有身份时不算可核验")
    func pidAloneIsNotVerifiable() {
        // 这是 v0.2 §2.5 单独保存 processStartIdentity 的全部理由:
        // 系统会重用 PID。只凭 PID 下手,可能杀掉一个完全无关的进程。
        #expect(makeJob(identity: nil).hasVerifiableProcessIdentity == false)
        #expect(makeJob(processId: nil).hasVerifiableProcessIdentity == false)
        #expect(makeJob().hasVerifiableProcessIdentity)
    }

    @Test("空的进程身份解码失败")
    func rejectsEmptyIdentity() {
        // 空串会让所有作业的身份互相相等 —— 比没有身份更危险,
        // 因为它看起来像「有身份」。
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder()
                .decode(ProcessStartIdentity.self, from: Data("\"\"".utf8))
        } == .dataCorrupted)
    }

    @Test("进程身份对内容不做解释")
    func identityIsOpaque() throws {
        // 取什么作为身份是 PilotInfrastructure 的事(P2-03 / P6-06)。
        // 这里只做相等比较,所以任何非空字符串都应当能存能取。
        for raw in ["1787196028.492046", "boot-42/pid-71439/1787196028", "任意不透明串"] {
            let identity = ProcessStartIdentity(rawValue: raw)
            let data = try CanonicalJSON.makeSnapshotEncoder().encode(identity)
            #expect(try CanonicalJSON.makeDecoder()
                .decode(ProcessStartIdentity.self, from: data) == identity)
        }
    }

    // MARK: - 状态

    @Test("终态判定")
    func terminalStates() {
        for status in [JobStatus.succeeded, .failed, .canceled, .orphaned] {
            #expect(status.isTerminal, "\(status.rawValue)")
        }
        for status in [JobStatus.queued, .starting, .running, .canceling] {
            #expect(status.isTerminal == false, "\(status.rawValue)")
        }
    }

    @Test("哪些状态该有活着的进程")
    func statesExpectingLiveProcess() {
        // 收尸流程(P6-07)只需要检查这几种。queued 还没起进程,
        // 终态的进程已经没了 —— 对它们做进程核验是白费。
        #expect(Set(JobStatus.allCases.filter(\.expectsLiveProcess))
                == [.starting, .running, .canceling])
    }

    @Test("orphaned 是终态,但含义是「结果不明」")
    func orphanedIsTerminalButUnresolved() {
        // 进程没了而结果不明:可能崩了、被系统杀了、机器重启过。
        // 它是终态是因为这次作业不会再自己往前走了,不是因为有了结论。
        #expect(JobStatus.orphaned.isTerminal)
        #expect(JobStatus.orphaned.expectsLiveProcess == false)
    }

    // MARK: - 校验

    @Test("attempt 小于 1 解码失败")
    func rejectsInvalidAttempt() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeJob())
        let broken = try JSONMutation.replacing(data, key: "attempt", with: 0)
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Job.self, from: broken)
        } == .dataCorrupted)
    }

    @Test("空分支名解码失败")
    func rejectsEmptyBranchName() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeJob())
        let broken = try JSONMutation.replacing(data, key: "branchName", with: "")
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Job.self, from: broken)
        } == .dataCorrupted)
    }

    @Test("未知枚举值解码失败", arguments: [
        ("status", "paused"), ("executor", "gemini"), ("authMode", "oauth"),
    ])
    func rejectsUnknownEnumValue(_ key: String, _ unknown: String) throws {
        // 这三个都是**我们自己定义**的枚举 —— 未知值意味着数据损坏,必须报错。
        // 与 PullRequestSnapshot 里镜像 GitHub 的那些正好相反。
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeJob())
        let broken = try JSONMutation.replacing(data, key: key, with: unknown)
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Job.self, from: broken)
        } == .dataCorrupted, "\(key)=\(unknown)")
    }

    @Test("枚举 raw value 写死")
    func rawValuesArePinned() {
        #expect(Set(JobStatus.allCases.map(\.rawValue)) == [
            "queued", "starting", "running", "succeeded",
            "failed", "canceling", "canceled", "orphaned",
        ])
        #expect(Set(ExecutorKind.allCases.map(\.rawValue)) == ["codex", "claude"])
        #expect(Set(AuthMode.allCases.map(\.rawValue)) == ["subscription", "apiKey", "external"])
    }
}
