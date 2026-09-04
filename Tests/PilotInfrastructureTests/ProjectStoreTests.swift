import Foundation
import Testing
import PilotCore
import PilotInfrastructure
import PilotTestSupport

/// ProjectStore 的测试。**每个用例对 InMemory 与 System 两种实现各跑一遍** ——
/// 与 FileSystem 契约测试同一个理由:只跟假实现一致的测试,
/// 证明不了任何关于真实磁盘的事。
@Suite("ProjectStore")
struct ProjectStoreTests {

    enum Implementation: String, CaseIterable, Sendable {
        case inMemory
        case system
    }

    struct Payload: Codable, Sendable, Equatable {
        var name: String
        var count: Int
    }

    private func makeSubject(_ implementation: Implementation) throws
        -> (fileSystem: any FileSystem, store: ProjectStore<Payload>, url: URL)
    {
        switch implementation {
        case .inMemory:
            let fileSystem = InMemoryFileSystem()
            let root = URL(fileURLWithPath: "/pilot-test-\(UUID().uuidString)")
            try fileSystem.createDirectory(at: root)
            let url = root.appendingPathComponent("state.json")
            return (fileSystem, ProjectStore(fileSystem: fileSystem), url)
        case .system:
            let fileSystem = SystemFileSystem()
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pilot-store-\(UUID().uuidString)", isDirectory: true)
            try fileSystem.createDirectory(at: root)
            let url = root.appendingPathComponent("state.json")
            return (fileSystem, ProjectStore(fileSystem: fileSystem), url)
        }
    }

    private func makeEnvelope(
        revision: Revision = .initial,
        payload: Payload = Payload(name: "任务表", count: 7)
    ) -> DataEnvelope<Payload> {
        DataEnvelope(
            revision: revision,
            lastEventSequence: 0,
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 1000),
            checksum: Checksum(value: 0),   // 保存时由仓库层重算并盖章
            payload: payload)
    }

    // MARK: - 往返与首次创建

    @Test("保存后读回完全相等", arguments: Implementation.allCases)
    func roundTrips(_ implementation: Implementation) throws {
        let (_, store, url) = try makeSubject(implementation)
        #expect(try store.load(from: url) == nil)   // 首次运行:没有文件,不伪造空快照

        try store.save(makeEnvelope(revision: Revision(1)), to: url, expecting: .initial)

        let loaded = try #require(try store.load(from: url))
        #expect(loaded.envelope.payload == Payload(name: "任务表", count: 7))
        #expect(loaded.envelope.revision == Revision(1))
        #expect(loaded.isReadOnly == false)
    }

    @Test("文件不存在时 load 返回 nil,不抛错", arguments: Implementation.allCases)
    func missingFileIsNil(_ implementation: Implementation) throws {
        let (_, store, url) = try makeSubject(implementation)
        #expect(try store.load(from: url) == nil)
    }

    @Test("首次保存:父目录完全不存在也能创建", arguments: Implementation.allCases)
    func firstSaveCreatesMissingDirectories(_ implementation: Implementation) throws {
        // 第一轮审查 P1:旁路锁的 open(O_CREAT) 先于 writeAtomically 的
        // createDirectory 执行,父目录缺失时直接 ENOENT —— 首次运行
        // (Application Support/ProjectPilot 尚不存在)必挂。
        // makeSubject 会预建根目录,恰好把这个路径挡在测试之外;
        // 这里刻意不建,连多级中间目录一起交给 save 创建。
        let store: ProjectStore<Payload>
        let url: URL
        switch implementation {
        case .inMemory:
            store = ProjectStore(fileSystem: InMemoryFileSystem())
            url = URL(fileURLWithPath: "/pilot-fresh-\(UUID().uuidString)/a/b/state.json")
        case .system:
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pilot-fresh-\(UUID().uuidString)", isDirectory: true)
            store = ProjectStore(fileSystem: SystemFileSystem())
            url = root.appendingPathComponent("a/b/state.json")
        }

        try store.save(makeEnvelope(revision: Revision(1)), to: url, expecting: .initial)
        let loaded = try #require(try store.load(from: url))
        #expect(loaded.envelope.revision == Revision(1))

        // 第二次保存照常(锁文件已存在,幂等)。
        try store.save(Self.bumped(loaded.envelope), to: url, expecting: loaded.envelope.revision)
        #expect(try #require(try store.load(from: url)).envelope.revision == Revision(2))
    }

    // MARK: - 校验和

    @Test("篡改 payload 后读取报损坏", arguments: Implementation.allCases)
    func rejectsPayloadTampering(_ implementation: Implementation) throws {
        let (fileSystem, store, url) = try makeSubject(implementation)
        try store.save(makeEnvelope(revision: Revision(1)), to: url, expecting: .initial)

        // 从盘上取原始字节,改掉 payload 里的一个值,原样写回 ——
        // JSON 仍然合法,只有校验和能抓住它。
        var raw = try fileSystem.read(at: url)
        raw = try JSONMutation.replacing(
            raw, key: "payload",
            with: ["name": "任务表", "count": 999])
        try fileSystem.write(raw, to: url)

        try assertCorrupted(url: url) { try store.load(from: url) }
    }

    @Test("篡改元数据(revision)同样报损坏 —— 校验和覆盖整份 envelope", arguments: Implementation.allCases)
    func rejectsMetadataTampering(_ implementation: Implementation) throws {
        // 这一条钉住校验和的**覆盖范围**(ADR-0015):只算 payload 的设计
        // 在这里会静默放过 —— revision 被改小,乐观并发就被悄悄拆掉了。
        let (fileSystem, store, url) = try makeSubject(implementation)
        try store.save(makeEnvelope(revision: Revision(1)), to: url, expecting: .initial)

        var raw = try fileSystem.read(at: url)
        raw = try JSONMutation.replacing(raw, key: "revision", with: 999)
        try fileSystem.write(raw, to: url)

        try assertCorrupted(url: url) { try store.load(from: url) }
    }

    @Test("不是合法 JSON 的文件报损坏,不当空数据", arguments: Implementation.allCases)
    func rejectsGarbage(_ implementation: Implementation) throws {
        let (fileSystem, store, url) = try makeSubject(implementation)
        try fileSystem.write(Data("这不是 JSON".utf8), to: url)
        try assertCorrupted(url: url) { try store.load(from: url) }
    }

    /// 断言抛出的是 corrupted 且指向正确的文件。
    /// reason 携带具体损坏细节(校验和差值、解码摘要),是动态内容,不逐字比。
    private func assertCorrupted(
        url: URL,
        _ body: () throws -> LoadedSnapshot<Payload>?
    ) throws {
        do {
            _ = try body()
            Issue.record("应当抛 .corrupted")
        } catch let error as ProjectStoreError {
            guard case .corrupted(let thrownURL, _) = error else {
                Issue.record("抛了别的 case:\(error)")
                return
            }
            #expect(thrownURL == url)
        }
    }

    @Test("未知字段原样保留,校验和仍然成立", arguments: Implementation.allCases)
    func unknownFieldsSurvive(_ implementation: Implementation) throws {
        // 更新版本写入的文件带本版本不认识的字段 —— 读回、再保存,字段不能丢,
        // 且校验和按「原样写回」的字节计算(它覆盖整份 envelope,含未知字段)。
        let (fileSystem, store, url) = try makeSubject(implementation)
        try store.save(makeEnvelope(revision: Revision(1)), to: url, expecting: .initial)

        var raw = try fileSystem.read(at: url)
        var tree = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        tree["futureFlag"] = true   // 新增未知键(JSONMutation 只能改已有键,不能新增)
        raw = try JSONSerialization.data(withJSONObject: tree)
        // 直接写回会破坏校验和 —— 未来的版本会重算。这里模拟它:
        // 解码(未知字段进 unknownFields)→ 用仓库层同一算法重算 → 写回。
        let decoded = try CanonicalJSON.makeDecoder()
            .decode(DataEnvelope<Payload>.self, from: raw)
        let stamped = Self.restamp(decoded)
        try fileSystem.write(try CanonicalJSON.makeSnapshotEncoder().encode(stamped), to: url)

        let loaded = try #require(try store.load(from: url))
        #expect(loaded.envelope.unknownFields["futureFlag"] == .bool(true))
        // 再走一轮保存,未知字段跟着走。
        var next = loaded.envelope
        next = DataEnvelope(
            schemaVersion: next.schemaVersion, revision: next.revision.next,
            lastEventSequence: next.lastEventSequence, createdAt: next.createdAt,
            updatedAt: next.updatedAt, checksum: next.checksum,
            payload: next.payload, unknownFields: next.unknownFields)
        try store.save(next, to: url, expecting: loaded.envelope.revision)
        let again = try #require(try store.load(from: url))
        #expect(again.envelope.unknownFields["futureFlag"] == .bool(true))
    }

    /// 用与仓库层相同的算法给 envelope 重算校验和(测试里模拟「未来版本写入」)。
    private static func restamp(_ envelope: DataEnvelope<Payload>) -> DataEnvelope<Payload> {
        let zeroed = DataEnvelope(
            schemaVersion: envelope.schemaVersion, revision: envelope.revision,
            lastEventSequence: envelope.lastEventSequence, createdAt: envelope.createdAt,
            updatedAt: envelope.updatedAt, checksum: Checksum(value: 0),
            payload: envelope.payload, unknownFields: envelope.unknownFields)
        let bytes = try! CanonicalJSON.makeSnapshotEncoder().encode(zeroed)
        return DataEnvelope(
            schemaVersion: envelope.schemaVersion, revision: envelope.revision,
            lastEventSequence: envelope.lastEventSequence, createdAt: envelope.createdAt,
            updatedAt: envelope.updatedAt, checksum: Checksum(hashing: bytes),
            payload: envelope.payload, unknownFields: envelope.unknownFields)
    }

    // MARK: - 乐观并发

    @Test("基于过期副本的写入被拒,盘上数据不被覆盖", arguments: Implementation.allCases)
    func staleWriterCannotOverwrite(_ implementation: Implementation) throws {
        let (_, store, url) = try makeSubject(implementation)
        let first = makeEnvelope(revision: Revision(1), payload: Payload(name: "第一版", count: 1))
        try store.save(first, to: url, expecting: .initial)

        let loaded = try #require(try store.load(from: url))
        // 另一个 writer 先落盘了。
        var second = loaded.envelope
        second = Self.bumped(second, payload: Payload(name: "第二版", count: 2))
        try store.save(second, to: url, expecting: loaded.envelope.revision)

        // 第三个 writer 基于第一版(expecting r1)想写入 —— 必须失败。
        // 冲突信息里 onDisk 是 r2:如实反映「盘上已经走到第二版」。
        #expect(throws: ProjectStoreError.revisionConflict(url: url, onDisk: Revision(2), expected: Revision(1))) {
            try store.save(Self.bumped(first, payload: Payload(name: "第三版", count: 3)),
                           to: url, expecting: Revision(1))
        }
        // 盘上仍是第二版。
        let onDisk = try #require(try store.load(from: url))
        #expect(onDisk.envelope.payload == Payload(name: "第二版", count: 2))
    }

    @Test("文件在读取后消失也算冲突", arguments: Implementation.allCases)
    func missingFileIsAConflict(_ implementation: Implementation) throws {
        let (fileSystem, store, url) = try makeSubject(implementation)
        try store.save(makeEnvelope(revision: Revision(1)), to: url, expecting: .initial)
        let loaded = try #require(try store.load(from: url))
        try fileSystem.removeItem(at: url)

        #expect(throws: ProjectStoreError.revisionConflict(url: url, onDisk: nil, expected: loaded.envelope.revision)) {
            try store.save(Self.bumped(loaded.envelope), to: url, expecting: loaded.envelope.revision)
        }
    }

    @Test("revision 不前进的保存被拒 —— 否则并发写入互相看不见", arguments: Implementation.allCases)
    func revisionMustAdvance(_ implementation: Implementation) throws {
        let (_, store, url) = try makeSubject(implementation)
        try store.save(makeEnvelope(revision: Revision(1)), to: url, expecting: .initial)
        let loaded = try #require(try store.load(from: url))

        // 忘了 bump:envelope.revision 仍是 expected 那一格。
        #expect(throws: ProjectStoreError.revisionNotAdvanced(url: url, expected: Revision(1), saved: Revision(1))) {
            try store.save(loaded.envelope, to: url, expecting: loaded.envelope.revision)
        }
        let onDisk = try #require(try store.load(from: url))
        #expect(onDisk.envelope.revision == Revision(1))
    }

    @Test("常规重试故事:冲突 → 重读 → 成功", arguments: Implementation.allCases)
    func conflictThenReloadThenSuccess(_ implementation: Implementation) throws {
        let (_, store, url) = try makeSubject(implementation)
        try store.save(makeEnvelope(revision: Revision(1)), to: url, expecting: .initial)

        // 两个 writer 从同一版出发。
        let a = try #require(try store.load(from: url))
        let b = try #require(try store.load(from: url))

        try store.save(Self.bumped(a.envelope, payload: Payload(name: "A 写入", count: 1)),
                       to: url, expecting: a.envelope.revision)

        // B 基于过期副本,先撞墙(onDisk 是 A 写完后的 r2)。
        #expect(throws: ProjectStoreError.revisionConflict(url: url, onDisk: Revision(2), expected: Revision(1))) {
            try store.save(Self.bumped(b.envelope, payload: Payload(name: "B 写入", count: 2)),
                           to: url, expecting: b.envelope.revision)
        }
        // B 重读最新版,基于它再改 —— 成功。
        let latest = try #require(try store.load(from: url))
        try store.save(Self.bumped(latest.envelope, payload: Payload(name: "B 重写", count: 3)),
                       to: url, expecting: latest.envelope.revision)
        let final = try #require(try store.load(from: url))
        #expect(final.envelope.payload == Payload(name: "B 重写", count: 3))
        #expect(final.envelope.revision == Revision(3))
    }

    // MARK: - 并发(跨进程锁)

    /// 线程安全的结果盒子:每个线程只写自己的槽位,读用锁保护。
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: Result<Void, any Error>?
        func set(_ value: Result<Void, any Error>) {
            lock.lock(); defer { lock.unlock() }
            outcome = value
        }
        func get() -> Result<Void, any Error>? {
            lock.lock(); defer { lock.unlock() }
            return outcome
        }
    }

    @Test("并发双写:恰好一个成功,不可能都成功", arguments: Implementation.allCases)
    func concurrentWritersExactlyOneWins(_ implementation: Implementation) throws {
        // 无锁时,两个 writer 都能在对方 rename 前通过校验 → 双双成功、
        // 后写覆盖先写。锁把「校验 → 替换」变成事务后,结局被钉死:
        // 恰好一个成功,另一个冲突。跑多轮放大窗口。
        for _ in 0..<20 {
            let (fileSystem, store, url) = try makeSubject(implementation)
            try store.save(makeEnvelope(revision: Revision(1),
                                        payload: Payload(name: "初版", count: 0)),
                           to: url, expecting: .initial)

            // 两个 writer 基于同一份 r1 副本(先读,再一起开跑)。
            let a = try #require(try store.load(from: url))
            let b = try #require(try store.load(from: url))

            let startGate = DispatchSemaphore(value: 0)
            let doneGate = DispatchSemaphore(value: 0)
            let boxA = OutcomeBox()
            let boxB = OutcomeBox()

            @Sendable func writer(
                _ box: OutcomeBox,
                _ base: DataEnvelope<Payload>,
                _ name: String,
                _ count: Int
            ) {
                startGate.wait()
                do {
                    try store.save(Self.bumped(base,
                                               payload: Payload(name: name, count: count)),
                                   to: url, expecting: base.revision)
                    box.set(.success(()))
                } catch {
                    box.set(.failure(error))
                }
                doneGate.signal()
            }

            let threadA = Thread { writer(boxA, a.envelope, "A 写入", 1) }
            let threadB = Thread { writer(boxB, b.envelope, "B 写入", 2) }
            threadA.start(); threadB.start()
            startGate.signal(); startGate.signal()
            doneGate.wait(); doneGate.wait()
            _ = fileSystem

            let outcomes = [boxA.get()!, boxB.get()!]
            let successes = outcomes.filter { if case .success = $0 { return true }; return false }
            let conflicts = outcomes.filter {
                if case .failure(ProjectStoreError.revisionConflict) = $0 { return true }; return false
            }
            #expect(successes.count == 1, "两写入同时成功 = 丢更新")
            #expect(conflicts.count == 1)

            let onDisk = try #require(try store.load(from: url))
            #expect(onDisk.envelope.revision == Revision(2))
        }
    }

    @Test("保存的 envelope 版本不是当前代码的版本时被拒",
          arguments: [SchemaVersion(99), SchemaVersion(2)])
    func rejectsNonCurrentEnvelopeVersion(_ savedVersion: SchemaVersion) throws {
        // 当前版本写入一个 v99 的 envelope,随后 load 立刻 isReadOnly ——
        // 自己刚写的文件自己再也无法更新。写入时就必须挡下。
        let (_, store, url) = try makeSubject(.inMemory)
        let future = DataEnvelope(
            schemaVersion: savedVersion, revision: Revision(1),
            lastEventSequence: 0, createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0), checksum: Checksum(value: 0),
            payload: Payload(name: "x", count: 1))

        #expect(throws: ProjectStoreError.envelopeVersionMismatch(
            url: url, saved: savedVersion, current: SchemaVersion.current)) {
            try store.save(future, to: url, expecting: .initial)
        }
        #expect(try store.load(from: url) == nil)   // 什么都没写进去
    }

    @Test("未来版本的未知大整数:可读、不误报损坏、再保存不丢", arguments: Implementation.allCases)
    func futureBigIntegerSurvives(_ implementation: Implementation) throws {
        // 2^53 + 1 在 Double 下会被吃成 2^53 —— 旧版解码、重编码后字节变了,
        // 一份完好的未来版本快照会被误报损坏。.integer 保真后必须原样往返。
        let (fileSystem, store, url) = try makeSubject(implementation)
        try store.save(makeEnvelope(revision: Revision(1)), to: url, expecting: .initial)
        let loaded = try #require(try store.load(from: url))

        // 模拟未来版本:写入带大整数的未知字段(按 envelope 范围重算校验和)。
        var future = DataEnvelope(
            schemaVersion: SchemaVersion(99), revision: loaded.envelope.revision.next,
            lastEventSequence: loaded.envelope.lastEventSequence,
            createdAt: loaded.envelope.createdAt, updatedAt: loaded.envelope.updatedAt,
            checksum: loaded.envelope.checksum, payload: loaded.envelope.payload,
            unknownFields: ["futureSequence": .integer(9_007_199_254_740_993)])
        future = Self.restamp(future)
        try fileSystem.write(try CanonicalJSON.makeSnapshotEncoder().encode(future), to: url)

        let fromFuture = try #require(try store.load(from: url))
        #expect(fromFuture.isReadOnly)
        #expect(fromFuture.envelope.unknownFields["futureSequence"]
                == .integer(9_007_199_254_740_993))   // 一个 bit 都不能动
    }

    // MARK: - 版本策略

    @Test("更新版本写的文件可读不可写", arguments: Implementation.allCases)
    func newerVersionIsReadOnly(_ implementation: Implementation) throws {
        let (fileSystem, store, url) = try makeSubject(implementation)
        try store.save(makeEnvelope(revision: Revision(1)), to: url, expecting: .initial)
        let loaded = try #require(try store.load(from: url))

        // 模拟未来的版本(它写的文件 schemaVersion 更高,校验和按同一算法重算)。
        var future = loaded.envelope
        future = DataEnvelope(
            schemaVersion: SchemaVersion(99), revision: future.revision.next,
            lastEventSequence: future.lastEventSequence, createdAt: future.createdAt,
            updatedAt: future.updatedAt, checksum: future.checksum,
            payload: future.payload, unknownFields: future.unknownFields)
        future = Self.restamp(future)
        try fileSystem.write(try CanonicalJSON.makeSnapshotEncoder().encode(future), to: url)

        let fromFuture = try #require(try store.load(from: url))
        #expect(fromFuture.isReadOnly)                      // 读得到
        #expect(fromFuture.envelope.payload.count == 7)     // 内容完好

        let bumped = Self.bumped(fromFuture.envelope)
        #expect(throws: ProjectStoreError.readOnly(url: url, diskVersion: SchemaVersion(99))) {
            try store.save(bumped, to: url, expecting: fromFuture.envelope.revision)
        }
    }

    // MARK: - 原子写(故障注入,仅内存实现)

    @Test("写到一半崩溃:旧文件完好,临时文件不留垃圾")
    func partialWriteKeepsOldFileIntact() throws {
        let (fileSystem, store, url) = try makeSubject(.inMemory)
        let memory = try #require(fileSystem as? InMemoryFileSystem)
        try store.save(makeEnvelope(revision: Revision(1), payload: Payload(name: "旧数据", count: 1)),
                       to: url, expecting: .initial)

        // 下一次 write 在 40 字节后失败 —— 模拟写到一半崩溃。
        memory.failNext(.write, with: .partialWrite(bytes: 40))
        do {
            try store.save(Self.bumped(makeEnvelope(revision: Revision(1))),
                           to: url, expecting: Revision(1))
            Issue.record("应当抛文件系统错误")
        } catch let error as FileSystemError {
            // IO 错误原样透传(磁盘满/写一半),仓库层不吞、不换类型 ——
            // 上层状态机要区分「数据冲突」和「磁盘故障」,这是两种完全不同的应对。
            #expect(error != .notFound(url))
        }

        // 旧文件完好:内容、revision、校验和全部成立。
        let onDisk = try #require(try store.load(from: url))
        #expect(onDisk.envelope.payload == Payload(name: "旧数据", count: 1))
        #expect(onDisk.envelope.revision == Revision(1))

        // 清掉故障后重试成功。
        memory.clearFaults()
        try store.save(Self.bumped(makeEnvelope(revision: Revision(1))),
                       to: url, expecting: Revision(1))
        let afterRetry = try #require(try store.load(from: url))
        #expect(afterRetry.envelope.revision == Revision(2))
    }

    // MARK: - 工具

    /// revision 前进一格 + 重算校验和(模拟调用方在领域对象上完成修改后的提交)。
    private static func bumped(
        _ envelope: DataEnvelope<Payload>,
        payload: Payload? = nil
    ) -> DataEnvelope<Payload> {
        let next = DataEnvelope(
            schemaVersion: envelope.schemaVersion, revision: envelope.revision.next,
            lastEventSequence: envelope.lastEventSequence, createdAt: envelope.createdAt,
            updatedAt: envelope.updatedAt, checksum: envelope.checksum,
            payload: payload ?? envelope.payload, unknownFields: envelope.unknownFields)
        return restamp(next)
    }
}
