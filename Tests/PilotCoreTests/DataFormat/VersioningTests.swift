import Foundation
import Testing
import PilotCore
import PilotTestSupport

@Suite("SchemaVersion 与 Revision")
struct VersioningTests {

    @Test("版本可比较")
    func versionsCompare() {
        #expect(SchemaVersion(1) < SchemaVersion(2))
        #expect(SchemaVersion(3) > SchemaVersion(2))
        #expect(SchemaVersion(2) == SchemaVersion(2))
    }

    @Test("版本往返")
    func versionRoundTrips() throws {
        let data = try JSONEncoder().encode(SchemaVersion(7))
        #expect(String(data: data, encoding: .utf8) == "7")
        #expect(try JSONDecoder().decode(SchemaVersion.self, from: data) == SchemaVersion(7))
    }

    @Test("版本号小于 1 时解码失败", arguments: ["0", "-1"])
    func rejectsInvalidVersion(_ text: String) {
        // 0 和负数不是「旧版本」,是损坏 —— 必须报错而不是当成 v1。
        #expect(decodingErrorKind {
            _ = try JSONDecoder().decode(SchemaVersion.self, from: Data(text.utf8))
        } == .dataCorrupted)
    }

    @Test("revision 从 0 起,next 递增")
    func revisionAdvances() {
        #expect(Revision.initial == Revision(0))
        #expect(Revision(0).next == Revision(1))
        #expect(Revision(41).next == Revision(42))
    }

    @Test("revision 可比较")
    func revisionsCompare() {
        #expect(Revision(1) < Revision(2))
        #expect(Revision(2) == Revision(2))
    }

    @Test("版本号是字符串时报类型不符")
    func rejectsStringVersion() {
        // 正交对照:如果实现把所有失败都返回成 dataCorrupted,
        // 上面那条「小于 1 报 dataCorrupted」照样绿,收紧等于没收紧。
        #expect(decodingErrorKind {
            _ = try JSONDecoder().decode(SchemaVersion.self, from: Data("\"1\"".utf8))
        } == .typeMismatch)
    }

    @Test("revision 是字符串时报类型不符")
    func rejectsStringRevision() {
        #expect(decodingErrorKind {
            _ = try JSONDecoder().decode(Revision.self, from: Data("\"5\"".utf8))
        } == .typeMismatch)
    }

    @Test("负 revision 解码失败")
    func rejectsNegativeRevision() {
        #expect(decodingErrorKind {
            _ = try JSONDecoder().decode(Revision.self, from: Data("-1".utf8))
        } == .dataCorrupted)
    }
}
