import Foundation
import Observation

/// Keeps every batch on the device, one JSON line per batch in a file per session
/// (`<directory>/sessions/batches/<started_at>-<session_id>.jsonl`). Past `maxBytes` the oldest
/// sessions' files are removed. Nothing leaves the device; a tester screen can share ``files()``.
public actor FileSessionSink: SessionSink {
    public let directory: URL
    public let maxBytes: Int

    public init(directory: URL, maxBytes: Int = 20 * 1024 * 1024) {
        self.directory = directory.appending(path: "sessions/batches", directoryHint: .isDirectory)
        self.maxBytes = maxBytes
    }

    /// In Application Support.
    public init(maxBytes: Int = 20 * 1024 * 1024) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.init(directory: base, maxBytes: maxBytes)
    }

    public func send(_ batch: SessionBatch) async throws -> SessionSinkReply {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "\(batch.session.startedAt)-\(batch.session.sessionID).jsonl")
        var line = try batch.jsonData()
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: file)
        }
        trim(keeping: file)
        return .accepted()
    }

    /// The files, oldest session first.
    public func files() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") }.sorted().map { directory.appending(path: $0) }
    }

    /// Every batch kept, oldest first.
    public func batches() -> [SessionBatch] {
        let decoder = JSONDecoder()
        return files().flatMap { file -> [SessionBatch] in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? decoder.decode(SessionBatch.self, from: Data($0.utf8)) }
        }
    }

    public func removeAll() {
        for file in files() { try? FileManager.default.removeItem(at: file) }
    }

    private func trim(keeping current: URL) {
        let fm = FileManager.default
        var all = files().map { ($0, (try? fm.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? 0) }
        var total = all.reduce(0) { $0 + $1.1 }
        while total > maxBytes, let oldest = all.first, oldest.0 != current {
            try? fm.removeItem(at: oldest.0)
            total -= oldest.1
            all.removeFirst()
        }
    }
}

/// Keeps the last batches in memory to look at while developing (a tester screen can list
/// ``batches``) and hands each to `log` as JSON text.
@Observable
public final class DebugSessionSink: SessionSink, @unchecked Sendable {
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private let log: (@Sendable (String) -> Void)?
    private var kept: [SessionBatch] = []

    public init(limit: Int = 50, log: (@Sendable (String) -> Void)? = { print("[sessions] \($0)") }) {
        self.limit = limit
        self.log = log
    }

    public var batches: [SessionBatch] { lock.withLock { kept } }

    public func send(_ batch: SessionBatch) async throws -> SessionSinkReply {
        lock.withLock {
            kept.append(batch)
            if kept.count > limit { kept.removeFirst(kept.count - limit) }
        }
        if let log, let data = try? batch.jsonData(), let text = String(data: data, encoding: .utf8) { log(text) }
        return .accepted()
    }

    public func removeAll() { lock.withLock { kept.removeAll() } }
}
