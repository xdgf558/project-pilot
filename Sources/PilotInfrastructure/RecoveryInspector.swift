import Foundation
import PilotCore

/// 一份快照的只读诊断。
public enum SnapshotDiagnosis: Sendable, Equatable {
    case missing(URL)
    case healthy(HealthySnapshot)
    /// 文件完好,但由更新版本写入,当前代码只能读。
    case readOnly(HealthySnapshot, diskVersion: SchemaVersion)
    case corrupted(url: URL, reason: String)
    case io(url: URL, detail: String)
}

/// 快照完好时能告诉人的摘要。时间戳已经是可读形式。
public struct HealthySnapshot: Sendable, Equatable {
    public let url: URL
    public let revision: Revision
    public let lastEventSequence: Int64
    public let schemaVersion: SchemaVersion
    public let createdAt: String
    public let updatedAt: String
}

/// 一份事件日志的只读诊断。
public enum EventLogDiagnosis: Sendable, Equatable {
    case missing(URL)
    case empty(URL)
    case healthy(HealthyEventLog)
    case corrupted(url: URL, line: Int, reason: String)
    case io(url: URL, detail: String)
}

public struct HealthyEventLog: Sendable, Equatable {
    public let url: URL
    public let count: Int
    public let lastSequence: Int64
    public let firstTimestamp: String
    public let lastTimestamp: String
}

/// 快照游标和日志末尾对得上吗。
public enum RelationDiagnosis: Sendable, Equatable {
    case consistent
    /// 快照或日志本身坏了 / 不存在,对不上号没有意义。
    case notApplicable
    /// 快照声称已经重放到日志里还不存在的序号。
    case cursorAhead(cursor: Int64, lastInLog: Int64)
    /// 日志比快照新,重放可以补上。
    case pendingEvents(count: Int)
    /// 有快照游标但日志文件不在。
    case snapshotMissingEvents(cursor: Int64)
}

/// 一次只读检查的完整报告。
public struct RecoveryReport: Sendable, Equatable {
    public let snapshot: SnapshotDiagnosis
    public let events: EventLogDiagnosis
    public let relation: RelationDiagnosis

    /// 给人看的说明:哪个文件、哪一行、时间是几点。
    public func formattedDescription() -> String {
        var lines: [String] = []
        lines.append("快照:\(Self.describeSnapshot(snapshot))")
        lines.append("日志:\(Self.describeEvents(events))")
        lines.append("关系:\(Self.describeRelation(relation))")
        return lines.joined(separator: "\n")
    }

    private static func describeSnapshot(_ diagnosis: SnapshotDiagnosis) -> String {
        switch diagnosis {
        case .missing(let url):
            return "「\(url.path)」不存在(首次运行或文件被移走)。"
        case .healthy(let info):
            return "「\(info.url.path)」完好,r\(info.revision.rawValue),"
                + "重放到 #\(info.lastEventSequence),创建 \(info.createdAt),更新 \(info.updatedAt)。"
        case .readOnly(let info, let version):
            return "「\(info.url.path)」由更新版本(\(version.description))写入,当前只能读。"
                + "重放到 #\(info.lastEventSequence),更新 \(info.updatedAt)。"
        case .corrupted(let url, let reason):
            return "「\(url.path)」损坏:\(reason)。本工具只读,不会覆盖。"
        case .io(let url, let detail):
            return "「\(url.path)」读失败:\(detail)。"
        }
    }

    private static func describeEvents(_ diagnosis: EventLogDiagnosis) -> String {
        switch diagnosis {
        case .missing(let url):
            return "「\(url.path)」不存在。"
        case .empty(let url):
            return "「\(url.path)」存在但是空的。"
        case .healthy(let info):
            return "「\(info.url.path)」完好,\(info.count) 条,最后一条 #\(info.lastSequence),"
                + "从 \(info.firstTimestamp) 到 \(info.lastTimestamp)。"
        case .corrupted(let url, let line, let reason):
            return "「\(url.path)」第 \(line) 行损坏:\(reason)。本工具只读,不会覆盖。"
        case .io(let url, let detail):
            return "「\(url.path)」读失败:\(detail)。"
        }
    }

    private static func describeRelation(_ diagnosis: RelationDiagnosis) -> String {
        switch diagnosis {
        case .consistent:
            return "快照游标与日志末尾一致。"
        case .notApplicable:
            return "快照或日志无法完整读取,对关系不下结论。"
        case .cursorAhead(let cursor, let last):
            return "快照声称重放到 #\(cursor),日志只到 #\(last)。两者可能不是一对,或日志被截断。"
        case .pendingEvents(let count):
            return "日志比快照新 \(count) 条,可以从游标接着重放。"
        case .snapshotMissingEvents(let cursor):
            return "快照重放到 #\(cursor),但日志文件不在。"
        }
    }
}

/// 恢复工具的只读检查器(P1-11)。
///
/// ## 职责
///
/// - **只读打开**。只走 `load` / `exists` / `read`,不创建、不写、不删、不替换。
///   损坏的修复是显式动作,检查的副作用不许销毁现场。
/// - **错误定位**。快照给到文件与原因;日志给到文件与行号。
/// - **可读时间戳**。把 P1-01 欠下的 Double 收成 UTC 毫秒时间。
///
/// ## 不做
///
/// 不覆盖、不备份、不重放折回领域对象、不画界面(Phase 8 渲染这份报告)、
/// 不引入 `pilotctl inspect`(参数解析仍保持零依赖)。
public struct RecoveryInspector: Sendable {
    private let fileSystem: any FileSystem
    private let store: ProjectStore<JSONValue>
    private let eventLog: EventLog

    public init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
        self.store = ProjectStore(fileSystem: fileSystem)
        self.eventLog = EventLog(fileSystem: fileSystem)
    }

    public func inspect(snapshot snapshotURL: URL, events eventsURL: URL) -> RecoveryReport {
        let snapshot = diagnoseSnapshot(at: snapshotURL)
        let events = diagnoseEvents(at: eventsURL)
        return RecoveryReport(
            snapshot: snapshot,
            events: events,
            relation: Self.relate(snapshot: snapshot, events: events))
    }

    private func diagnoseSnapshot(at url: URL) -> SnapshotDiagnosis {
        do {
            guard let loaded = try store.load(from: url) else { return .missing(url) }
            let info = HealthySnapshot(
                url: url,
                revision: loaded.envelope.revision,
                lastEventSequence: loaded.envelope.lastEventSequence,
                schemaVersion: loaded.envelope.schemaVersion,
                createdAt: ReadableTimestamp.format(loaded.envelope.createdAt),
                updatedAt: ReadableTimestamp.format(loaded.envelope.updatedAt))
            if loaded.isReadOnly {
                return .readOnly(info, diskVersion: loaded.envelope.schemaVersion)
            }
            return .healthy(info)
        } catch let error as ProjectStoreError {
            if case .corrupted(_, let reason) = error {
                return .corrupted(url: url, reason: reason)
            }
            return .io(url: url, detail: error.localizedDescription)
        } catch let error as FileSystemError {
            return .io(url: url, detail: String(describing: error))
        } catch {
            return .io(url: url, detail: String(describing: error))
        }
    }

    private func diagnoseEvents(at url: URL) -> EventLogDiagnosis {
        do {
            guard fileSystem.exists(at: url) else { return .missing(url) }
            let events = try eventLog.load(from: url)
            guard let first = events.first, let last = events.last else {
                return .empty(url)
            }
            return .healthy(HealthyEventLog(
                url: url,
                count: events.count,
                lastSequence: last.sequence,
                firstTimestamp: ReadableTimestamp.format(first.timestamp),
                lastTimestamp: ReadableTimestamp.format(last.timestamp)))
        } catch let error as EventLogError {
            if case .corrupted(_, let line, let reason) = error {
                return .corrupted(url: url, line: line, reason: reason)
            }
            return .io(url: url, detail: error.localizedDescription)
        } catch let error as FileSystemError {
            return .io(url: url, detail: String(describing: error))
        } catch {
            return .io(url: url, detail: String(describing: error))
        }
    }

    private static func relate(
        snapshot: SnapshotDiagnosis,
        events: EventLogDiagnosis
    ) -> RelationDiagnosis {
        let cursor: Int64
        switch snapshot {
        case .healthy(let info), .readOnly(let info, _):
            cursor = info.lastEventSequence
        case .missing, .corrupted, .io:
            return .notApplicable
        }

        switch events {
        case .missing:
            return cursor == 0 ? .consistent : .snapshotMissingEvents(cursor: cursor)
        case .empty:
            return cursor == 0 ? .consistent : .cursorAhead(cursor: cursor, lastInLog: 0)
        case .healthy(let info):
            if cursor > info.lastSequence {
                return .cursorAhead(cursor: cursor, lastInLog: info.lastSequence)
            }
            if cursor < info.lastSequence {
                return .pendingEvents(count: Int(info.lastSequence - cursor))
            }
            return .consistent
        case .corrupted, .io:
            return .notApplicable
        }
    }
}
