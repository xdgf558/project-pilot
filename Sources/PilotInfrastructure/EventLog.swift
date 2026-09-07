import Foundation
import PilotCore

/// 事件日志的错误。每个 case 都带 url 与可操作的说明 ——
/// 「哪个文件、期望什么、实际得到什么」。
public enum EventLogError: Error, Equatable, Sendable, LocalizedError {
    /// 文件存在但读不出合法的 NDJSON 日志:某行不是事件、中间有空行、
    /// 或序号出现空洞 / 乱序。**损坏的数据不会被当作空日志**(v0.2 §3 规则 10),
    /// 也不会被追加覆盖 —— 修复走恢复工具(P1-11),不在这里悄悄进行。
    case corrupted(url: URL, line: Int, reason: String)
    /// 乐观并发校验失败:磁盘上最后一条的序号与调用方读取时的不一致。
    /// 数据没有丢,只是你的副本过期了 —— 重新读取、接到真正的末尾再追加。
    case sequenceConflict(url: URL, onDiskLast: Int64, expectedLast: Int64)
    /// 要追加的事件序号没有从 expectedLast 前进一格,或批次内部不连续。
    /// 序号不连续,快照的 lastEventSequence 就再也对不上重放起点。
    case sequenceNotAdvanced(url: URL, expected: Int64, actual: Int64)
    /// 一次追加零条事件。空追加不改变任何东西,却会让调用方以为写进去了。
    case emptyAppend(url: URL)
    /// 重放游标为负。快照的 lastEventSequence 从不小于 0。
    case invalidCursor(url: URL, sequence: Int64)
    /// 快照声称已经重放到一个日志里还不存在的序号。
    /// 游标超前要么是快照和日志不是一对,要么是日志被截断 —— 都不能假装「没有新事件」。
    case cursorAheadOfLog(url: URL, cursor: Int64, lastInLog: Int64)

    public var errorDescription: String? {
        switch self {
        case .corrupted(let url, let line, let reason):
            return "「\(url.path)」第 \(line) 行无法读取:\(reason)。"
                + "损坏的日志不会当作空数据使用。请从备份恢复,或用恢复工具打开定位(P1-11)。"
        case .sequenceConflict(let url, let onDiskLast, let expectedLast):
            return "追加被拒:\(url.path) 在你读取之后被别人写过"
                + "(盘上最后一条是 #\(onDiskLast),你基于 #\(expectedLast) 追加)。"
                + "重新读取后再接到末尾,不要覆盖。"
        case .sequenceNotAdvanced(let url, let expected, let actual):
            return "追加被拒:\(url.path) 的下一条序号必须是 #\(expected),实际是 #\(actual)。"
                + "序号不连续,快照就不知道该从哪开始重放。"
        case .emptyAppend(let url):
            return "追加被拒:\(url.path) 收到 0 条事件。空追加不会写入任何东西。"
        case .invalidCursor(let url, let sequence):
            return "重放被拒:\(url.path) 的游标不能为负,实际是 \(sequence)。"
        case .cursorAheadOfLog(let url, let cursor, let lastInLog):
            return "重放被拒:\(url.path) 的快照声称已重放到 #\(cursor),"
                + "但日志只到 #\(lastInLog)。快照和日志可能不是一对,或日志被截断。"
        }
    }
}

/// 只追加的事件日志(P1-06)。
///
/// ## 职责
///
/// - **NDJSON 落盘**。一条事件占一行,编码器是 `CanonicalJSON.makeEventEncoder()`
///   (不能 prettyPrinted,否则一行变多行,整份日志报废)。
/// - **sequence 游标**。事件序号从 1 起单调 +1;快照的 `lastEventSequence`
///   是重放起点 —— `events(after:)` / `eventsToReplay` 只返回游标之后的事件。
/// - **乐观追加**。写入必须带上调用方读到的最后序号;新事件必须恰好从
///   那里前进。两道检查缺一不可:前者拒绝基于过期副本的追加,
///   后者保证计数器真的在走。
/// - **原子写**。同目录唯一临时文件 → 写 → `replaceItem`。
///   不使用 POSIX append:写到一半会留下半截最后一行,
///   半截和损坏在读回时无法区分。rename 原子性让崩溃时旧日志完好。
///
/// ## 不做
///
/// 不把事件折回领域对象(命令集与派生状态是 P1-07 / P5-01);
/// 不按 requestId 去重(P6-02);不做压缩或截断;不给单条事件加校验和
/// (`Event` 模型没有这个字段,完整性靠「能解开 + 序号连续」)。
public struct EventLog: Sendable {
    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    // MARK: - 读取

    /// 读出全部事件。文件不存在或为空时返回 `[]`(首次运行)——
    /// 不伪造一条「日志创建」事件。损坏抛 `EventLogError.corrupted`。
    ///
    /// 读**不加锁**:replace 的原子性保证读到的要么是旧文件要么是新文件。
    public func load(from url: URL) throws -> [Event] {
        try readEvents(at: url)
    }

    /// 返回 `sequence` 之后的事件。`sequence` 就是快照上的 `lastEventSequence`。
    public func events(from url: URL, after sequence: Int64) throws -> [Event] {
        guard sequence >= 0 else {
            throw EventLogError.invalidCursor(url: url, sequence: sequence)
        }
        let all = try readEvents(at: url)
        let last = all.last?.sequence ?? 0
        guard sequence <= last else {
            throw EventLogError.cursorAheadOfLog(url: url, cursor: sequence, lastInLog: last)
        }
        return all.filter { $0.sequence > sequence }
    }

    /// 从快照的 `lastEventSequence` 接着重放。本层只给出要放的事件,
    /// 不解释 payload、不改领域对象。
    public func eventsToReplay<Payload: Codable & Sendable>(
        from snapshot: DataEnvelope<Payload>,
        log url: URL
    ) throws -> [Event] {
        try events(from: url, after: snapshot.lastEventSequence)
    }

    // MARK: - 写入

    /// 乐观追加。
    ///
    /// `expectedLast` 是调用方最后一次读到的序号(空日志传 `0`)。
    /// 第一条要写入的事件序号必须恰好是 `expectedLast + 1`,其后连续 +1。
    public func append(_ events: [Event], to url: URL, after expectedLast: Int64) throws {
        guard !events.isEmpty else { throw EventLogError.emptyAppend(url: url) }

        try fileSystem.createDirectory(at: url.deletingLastPathComponent())
        try fileSystem.withExclusiveLock(at: url) {
            let onDisk = try readEvents(at: url)
            let onDiskLast = onDisk.last?.sequence ?? 0
            guard onDiskLast == expectedLast else {
                throw EventLogError.sequenceConflict(
                    url: url, onDiskLast: onDiskLast, expectedLast: expectedLast)
            }

            var expected = expectedLast + 1
            for event in events {
                guard event.sequence == expected else {
                    throw EventLogError.sequenceNotAdvanced(
                        url: url, expected: expected, actual: event.sequence)
                }
                expected += 1
            }

            var combined = onDisk
            combined.append(contentsOf: events)
            try writeAtomically(try Self.encodeLog(combined), to: url)
        }
    }

    // MARK: - 内部

    /// 读出并验证一份日志。文件不存在返回空。
    ///
    /// 读取路径与写入路径共用:追加前同样校验磁盘上的现存数据 ——
    /// 损坏的日志不许被覆盖,修复是 P1-11 的显式动作。
    private func readEvents(at url: URL) throws -> [Event] {
        guard fileSystem.exists(at: url) else { return [] }
        let raw = try fileSystem.read(at: url)
        return try Self.decodeLog(raw, url: url)
    }

    static func decodeLog(_ raw: Data, url: URL) throws -> [Event] {
        if raw.isEmpty { return [] }
        guard let text = String(data: raw, encoding: .utf8) else {
            throw EventLogError.corrupted(url: url, line: 1, reason: "不是合法 UTF-8。")
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        if lines.isEmpty { return [] }

        var events: [Event] = []
        let decoder = CanonicalJSON.makeDecoder()
        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            if line.isEmpty {
                throw EventLogError.corrupted(
                    url: url, line: lineNumber,
                    reason: "第 \(lineNumber) 行是空行。NDJSON 不允许中间空行。")
            }

            let event: Event
            do {
                event = try decoder.decode(Event.self, from: Data(line.utf8))
            } catch {
                throw EventLogError.corrupted(
                    url: url, line: lineNumber, reason: Self.summarize(error))
            }

            let expected = Int64(lineNumber)
            guard event.sequence == expected else {
                throw EventLogError.corrupted(
                    url: url, line: lineNumber,
                    reason: "第 \(lineNumber) 行的序号应为 \(expected),实际是 \(event.sequence)。"
                        + "日志出现空洞或乱序。")
            }
            events.append(event)
        }
        return events
    }

    static func encodeLog(_ events: [Event]) throws -> Data {
        let encoder = CanonicalJSON.makeEventEncoder()
        var output = Data()
        for event in events {
            output.append(try encoder.encode(event))
            output.append(contentsOf: Data("\n".utf8))
        }
        return output
    }

    /// 同目录唯一临时文件 → 写 → 原子替换。替换失败时清掉临时文件,
    /// 不留垃圾;目标文件在失败路径上完好如初。
    private func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
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
