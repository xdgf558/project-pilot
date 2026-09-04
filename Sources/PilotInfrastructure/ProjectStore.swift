import Foundation
import PilotCore

/// 一次成功读取的快照。
///
/// `isReadOnly` 为 true 表示磁盘上的 schemaVersion 比当前代码新:
/// 可以读,写入会被拒绝(2026-09-03 确认的策略,见 ADR-0015)。
/// 这不是损坏 —— 是安全降级,与 P4-03「遇到不认识的状态继续只读」同源。
public struct LoadedSnapshot<Payload: Codable & Sendable>: Sendable {
    public let envelope: DataEnvelope<Payload>
    public let url: URL
    public let isReadOnly: Bool

    public init(envelope: DataEnvelope<Payload>, url: URL, isReadOnly: Bool) {
        self.envelope = envelope
        self.url = url
        self.isReadOnly = isReadOnly
    }
}

/// 快照仓库的错误。每个 case 都带 url 与可操作的说明 ——
/// 「哪个文件、期望什么、实际得到什么」。
public enum ProjectStoreError: Error, Equatable, Sendable, LocalizedError {
    /// 文件存在但读不出合法的快照:JSON 解不开、envelope 不变量被破坏、
    /// 或校验和不匹配。**损坏的数据不会被当作空数据**(v0.2 §3 规则 10),
    /// 也不会被写入覆盖 —— 修复走恢复工具(P1-11),不在这里悄悄进行。
    case corrupted(url: URL, reason: String)
    /// 乐观并发校验失败:磁盘上的 revision 与调用方读取时的不一致。
    /// `onDisk` 为 nil 表示文件已消失。数据没有丢,只是你的副本过期了 ——
    /// 重新读取、重放修改、再保存。
    case revisionConflict(url: URL, onDisk: Revision?, expected: Revision)
    /// 调用方保存的 envelope.revision 没有从 expected 前进。
    /// revision 不前进,并发写入就互相看不见 —— 这不是风格要求,是正确性要求。
    case revisionNotAdvanced(url: URL, expected: Revision, saved: Revision)
    /// 磁盘数据由更新版本的 ProjectPilot 写入,当前版本只读。
    case readOnly(url: URL, diskVersion: SchemaVersion)

    public var errorDescription: String? {
        switch self {
        case .corrupted(let url, let reason):
            return "「\(url.path)」无法读取:\(reason)。损坏的文件不会当作空数据使用。"
                + "请从备份恢复,或用恢复工具打开定位(Phase 1 的 P1-11)。"
        case .revisionConflict(let url, let onDisk, let expected):
            let disk = onDisk.map { "盘上 r\($0.rawValue)" } ?? "文件已消失"
            return "保存被拒:\(url.path) 在你读取之后被别人写过(\(disk),你基于 r\(expected.rawValue) 修改)。"
                + "重新读取后再修改,不要覆盖。"
        case .revisionNotAdvanced(let url, let expected, let saved):
            return "保存被拒:\(url.path) 的 revision 必须从 r\(expected.rawValue) 前进到 r\(expected.rawValue + 1),"
                + "实际是 r\(saved.rawValue)。revision 不前进,并发的写入会互相覆盖。"
        case .readOnly(let url, let diskVersion):
            return "「\(url.path)」由更新版本(\(diskVersion.description))的 ProjectPilot 写入,"
                + "当前版本(v\(SchemaVersion.current.rawValue))只能读。升级 ProjectPilot 后可写。"
        }
    }
}

/// 快照仓库:envelope 的落盘与读取(P1-05)。
///
/// ## 职责
///
/// - **校验和的计算与验证**。P1-01 只定义了类型并留了占位 —— 计算归本层,
///   因为只有它知道实际写进磁盘的字节。覆盖范围:除 checksum 自身外的
///   整份 envelope(2026-09-03 确认,ADR-0015)—— 元数据(revision 等)
///   被位翻转同样拦得住,新增 envelope 字段自动纳入。
/// - **revision 乐观校验**。写入必须带上读取时的 revision;
///   新 envelope 的 revision 必须恰好前进一格。两道检查缺一不可:
///   前者拒绝「基于过期副本的覆盖」,后者保证计数器真的在走、
///   并发写入互相可见。
/// - **原子写**。同目录唯一临时文件 → 写 → `replaceItem`(POSIX rename,
///   同一卷内原子)。写到一半崩溃时旧文件完好 —— 崩溃恢复的地基。
/// - **版本策略**。schemaVersion 比当前新:可读,写被拒(安全降级,
///   P4-03 同源)。
///
/// ## 不做
///
/// 事件日志(P1-06)、命令层(P1-07)、损坏后的恢复与定位(P1-11)、
/// 并发压测(P1-12 —— InMemoryFileSystem 的故障注入就是为它准备的)。
/// fsync 级的断电持久性也不在这里:rename 的原子性防的是「写到一半」,
/// 不是机器掉电;那归 P1-12 一并验证。
public struct ProjectStore<Payload: Codable & Sendable>: Sendable {
    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    // MARK: - 读取

    /// 读取快照。文件不存在时返回 nil(首次运行)—— 调用方决定初始状态,
    /// 仓库层不伪造空快照。损坏抛 `ProjectStoreError.corrupted`。
    public func load(from url: URL) throws -> LoadedSnapshot<Payload>? {
        guard let envelope = try readEnvelope(at: url) else { return nil }
        let isReadOnly = envelope.schemaVersion > SchemaVersion.current
        return LoadedSnapshot(envelope: envelope, url: url, isReadOnly: isReadOnly)
    }

    // MARK: - 写入

    /// 乐观写入。
    ///
    /// `expected` 是调用方最后一次读到的 revision(首次创建传 `.initial`)。
    /// 要保存的 envelope.revision 必须恰好是 `expected.next`。
    public func save(
        _ envelope: DataEnvelope<Payload>,
        to url: URL,
        expecting expected: Revision
    ) throws {
        let onDisk = try readEnvelope(at: url)

        if let disk = onDisk {
            if disk.schemaVersion > SchemaVersion.current {
                throw ProjectStoreError.readOnly(url: url, diskVersion: disk.schemaVersion)
            }
            guard disk.revision == expected else {
                throw ProjectStoreError.revisionConflict(
                    url: url, onDisk: disk.revision, expected: expected)
            }
        } else if expected != .initial {
            // 文件消失了,而调用方以为自己读过它 —— 这也是冲突:
            // 基于一个已经不存在的副本继续写,同样会覆盖别人。
            throw ProjectStoreError.revisionConflict(url: url, onDisk: nil, expected: expected)
        }

        guard envelope.revision == expected.next else {
            throw ProjectStoreError.revisionNotAdvanced(
                url: url, expected: expected, saved: envelope.revision)
        }

        let stamped = Self.withChecksum(try Self.integrityHash(for: envelope), on: envelope)
        try writeAtomically(Self.canonicalData(stamped), to: url)
    }

    // MARK: - 内部

    /// 读出并验证一份 envelope。文件不存在返回 nil。
    ///
    /// 读取路径与写入路径共用:写入前同样校验磁盘上的现存数据 ——
    /// 损坏的文件不许被覆盖,修复是 P1-11 的显式动作,不是写入的副作用。
    private func readEnvelope(at url: URL) throws -> DataEnvelope<Payload>? {
        guard fileSystem.exists(at: url) else { return nil }
        let raw = try fileSystem.read(at: url)

        let envelope: DataEnvelope<Payload>
        do {
            envelope = try CanonicalJSON.makeDecoder().decode(DataEnvelope<Payload>.self, from: raw)
        } catch {
            throw ProjectStoreError.corrupted(url: url, reason: Self.summarize(error))
        }

        let computed = try Self.integrityHash(for: envelope)
        guard computed == envelope.checksum else {
            throw ProjectStoreError.corrupted(
                url: url,
                reason: "校验和不匹配:文件记录 \(envelope.checksum),"
                    + "按当前规范重算得 \(computed)。内容或元数据已被改动。")
        }
        return envelope
    }

    /// 校验和覆盖**除 checksum 自身外**的整份 envelope。
    ///
    /// 做法是把 checksum 置零后按当前规范重编码再哈希;验证时对解码结果
    /// 做同样的事。前提是「解码后按当前规范重编码,字节稳定」——
    /// 这个前提由 CanonicalJSON 的往返测试钉死(P1-01);它一旦破了,
    /// 表现是完好的文件被误报损坏 —— 必须先修编码,不能放宽这里的比较。
    static func integrityHash(for envelope: DataEnvelope<Payload>) throws -> Checksum {
        let bytes = try Self.canonicalData(withChecksum(Checksum(value: 0), on: envelope))
        return Checksum(hashing: bytes)
    }

    private static func withChecksum(
        _ checksum: Checksum,
        on envelope: DataEnvelope<Payload>
    ) -> DataEnvelope<Payload> {
        DataEnvelope(
            schemaVersion: envelope.schemaVersion,
            revision: envelope.revision,
            lastEventSequence: envelope.lastEventSequence,
            createdAt: envelope.createdAt,
            updatedAt: envelope.updatedAt,
            checksum: checksum,
            payload: envelope.payload,
            unknownFields: envelope.unknownFields)
    }

    private static func canonicalData(_ envelope: DataEnvelope<Payload>) throws -> Data {
        try CanonicalJSON.makeSnapshotEncoder().encode(envelope)
    }

    /// 同目录唯一临时文件 → 写 → 原子替换。替换失败时清掉临时文件,
    /// 不留垃圾;目标文件在失败路径上完好如初。
    private func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try fileSystem.createDirectory(at: directory)
        let temporary = directory.appendingPathComponent(
            "." + url.lastPathComponent + ".tmp-" + UUID().uuidString)
        do {
            try fileSystem.write(data, to: temporary)
            try fileSystem.replaceItem(at: url, withItemAt: temporary)
        } catch {
            try? fileSystem.removeItem(at: temporary)
            throw error
        }
    }

    private static func summarize(_ error: some Error) -> String {
        String(describing: error)
    }
}
