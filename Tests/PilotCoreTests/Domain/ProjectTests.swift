import Foundation
import Testing
import PilotCore
import PilotTestSupport

@Suite("Project")
struct ProjectTests {

    private func makeProject(
        name: String = "ProjectPilot",
        remoteHost: String = "github.com",
        concurrency: Int = 1,
        trustedAt: Date? = Date(timeIntervalSince1970: 500)
    ) -> Project {
        Project(
            id: UUID(sequenceNumber: 100),
            name: name,
            repositoryPath: URL(fileURLWithPath: "/Users/me/code/project-pilot"),
            remoteHost: remoteHost,
            owner: "xdgf558",
            repository: "project-pilot",
            defaultBranch: "main",
            trustedAt: trustedAt,
            schedulerMode: .assisted,
            projectConcurrency: concurrency,
            repositoryPolicy: .personal,
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000)
        )
    }

    @Test("往返相等")
    func roundTrips() throws {
        let original = makeProject()
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(original)
        #expect(try CanonicalJSON.makeDecoder().decode(Project.self, from: data) == original)
    }

    @Test("未信任的项目也能往返")
    func roundTripsUntrusted() throws {
        let untrusted = makeProject(trustedAt: nil)
        #expect(untrusted.isTrusted == false)
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(untrusted)
        let decoded = try CanonicalJSON.makeDecoder().decode(Project.self, from: data)
        #expect(decoded == untrusted)
        #expect(decoded.trustedAt == nil)
    }

    @Test("isTrusted 跟随 trustedAt")
    func trustFlagFollowsTimestamp() {
        #expect(makeProject(trustedAt: Date()).isTrusted)
        #expect(makeProject(trustedAt: nil).isTrusted == false)
    }

    // MARK: - 刻意不校验的东西

    @Test("非 github.com 的 host 会被接受,不在数据层拒绝", arguments: ["gitlab.com", "git.example.internal", ""])
    func acceptsUnsupportedHost(_ host: String) throws {
        // v0.2 §0.3 说 v1 只支持 GitHub.com,但 §2.4 同时定义了
        // unsupportedRepository 这个 blocker —— 说明不支持的仓库是能被存下来、
        // 作为阻塞展示的,不是在数据层拒绝。
        //
        // 在这里拒绝的后果是:用户接入一个 GitLab 仓库时,系统连一条
        // 像样的错误都给不出来,只能在解码时崩掉。
        let project = makeProject(remoteHost: host)
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(project)
        #expect(try CanonicalJSON.makeDecoder().decode(Project.self, from: data).remoteHost == host)
    }

    @Test("automatic 调度模式可以存,即使 M-Solo 不实现")
    func acceptsAutomaticSchedulerMode() throws {
        // v0.3 D-02 说 M-Solo 只做到 assisted。但枚举保留 automatic ——
        // 数据模型按 v0.2 定,实现范围按 v0.3 定。现在删掉,
        // 将来加回来就是一次数据格式变更。
        var project = makeProject()
        project.schedulerMode = .automatic
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(project)
        #expect(try CanonicalJSON.makeDecoder().decode(Project.self, from: data).schedulerMode == .automatic)
    }

    // MARK: - 失败用例

    @Test("空项目名解码失败")
    func rejectsEmptyName() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeProject())
        let broken = try replacing(data, key: "name", with: "\"\"")
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Project.self, from: broken)
        } == .dataCorrupted)
    }

    @Test("并发上限小于 1 解码失败", arguments: ["0", "-1"])
    func rejectsInvalidConcurrency(_ value: String) throws {
        // 想让项目停下来用暂停,不是把上限设成 0 ——
        // 那样「暂停了」和「配置错了」在数据上分不开。
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeProject())
        let broken = try replacing(data, key: "projectConcurrency", with: value)
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Project.self, from: broken)
        } == .dataCorrupted)
    }

    @Test("并发上限类型不符时报 typeMismatch")
    func rejectsWrongTypeForConcurrency() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeProject())
        let broken = try replacing(data, key: "projectConcurrency", with: "\"1\"")
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Project.self, from: broken)
        } == .typeMismatch)
    }

    @Test("未知的调度模式解码失败")
    func rejectsUnknownSchedulerMode() throws {
        let data = try CanonicalJSON.makeSnapshotEncoder().encode(makeProject())
        let broken = try replacing(data, key: "schedulerMode", with: "\"turbo\"")
        #expect(decodingErrorKind {
            _ = try CanonicalJSON.makeDecoder().decode(Project.self, from: broken)
        } == .dataCorrupted)
    }

    @Test("枚举 raw value 写死")
    func rawValuesArePinned() {
        #expect(Set(SchedulerMode.allCases.map(\.rawValue)) == ["manual", "assisted", "automatic"])
        #expect(Set(RepositoryPolicy.allCases.map(\.rawValue)) == ["personal", "protected"])
    }
}

private func replacing(_ data: Data, key: String, with value: String) throws -> Data {
    let text = try #require(String(data: data, encoding: .utf8))
    let pattern = "\"\(key)\" : "
    let range = try #require(text.range(of: pattern))
    let afterKey = text[range.upperBound...]
    let end = try #require(afterKey.firstIndex(where: { $0 == "," || $0 == "\n" }))
    return Data((text[..<range.upperBound] + value + afterKey[end...]).utf8)
}
