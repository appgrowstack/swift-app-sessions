import Foundation

/// What the recording keeps about one session next to its segments (`meta.json`).
public struct SessionReplayMeta: Sendable, Equatable, Codable {
    public var sessionID: String
    /// When the session started (milliseconds since 1970).
    public var startedAt: Int
    /// The session's upload token, once the sink handed it over.
    public var token: String?
    /// The sink's decision: `record` sends everything, `buffer` keeps the last 60 seconds.
    public var mode: SessionReplayMode
    /// A priority condition was met: the buffered segments and the later ones are sent.
    public var priority: Bool
    /// The `seq` the next segment gets.
    public var nextSeq: Int
    /// Bytes of segments made for the session (sent or not).
    public var bytes: Int
    /// The session's recording stopped (`session_limit`).
    public var stopped: Bool

    public init(sessionID: String, startedAt: Int, token: String? = nil, mode: SessionReplayMode = .buffer,
                priority: Bool = false, nextSeq: Int = 0, bytes: Int = 0, stopped: Bool = false) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.token = token
        self.mode = mode
        self.priority = priority
        self.nextSeq = nextSeq
        self.bytes = bytes
        self.stopped = stopped
    }

    /// The segments may leave the device.
    public var mayUpload: Bool { token != nil && (mode == .record || priority) }
}

/// A segment waiting on the device.
public struct SessionReplayStoredSegment: Sendable, Equatable {
    public var sessionID: String
    public var seq: Int
    public var tFrom: Int
    public var tTo: Int
    public var bytes: Int
}

/// Where the recording keeps segments until they are sent: `<directory>/sessions/replay/<session id>/`
/// with `meta.json` and `<seq>-<t_from>-<t_to>.agsr`. Kept in Application Support so the system does
/// not clear them before they are sent; the recorder keeps the total under its limit.
public struct SessionReplayStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.appending(path: "sessions", directoryHint: .isDirectory)
            .appending(path: "replay", directoryHint: .isDirectory)
    }

    public static func standard() -> SessionReplayStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return SessionReplayStore(directory: base)
    }

    private func folder(_ sessionID: String) -> URL {
        directory.appending(path: sessionID, directoryHint: .isDirectory)
    }

    // MARK: - Sessions

    public func sessionIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix("ses_") }
    }

    public func meta(_ sessionID: String) -> SessionReplayMeta? {
        guard let data = try? Data(contentsOf: folder(sessionID).appending(path: "meta.json")) else { return nil }
        return try? JSONDecoder().decode(SessionReplayMeta.self, from: data)
    }

    public func saveMeta(_ meta: SessionReplayMeta) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        try? FileManager.default.createDirectory(at: folder(meta.sessionID), withIntermediateDirectories: true)
        try? data.write(to: folder(meta.sessionID).appending(path: "meta.json"), options: .atomic)
    }

    public func removeSession(_ sessionID: String) {
        try? FileManager.default.removeItem(at: folder(sessionID))
    }

    // MARK: - Segments

    public func write(_ data: Data, sessionID: String, seq: Int, tFrom: Int, tTo: Int) {
        try? FileManager.default.createDirectory(at: folder(sessionID), withIntermediateDirectories: true)
        try? data.write(to: folder(sessionID).appending(path: "\(seq)-\(tFrom)-\(tTo).agsr"), options: .atomic)
    }

    /// The session's segments, oldest first.
    public func segments(_ sessionID: String) -> [SessionReplayStoredSegment] {
        let dir = folder(sessionID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name -> SessionReplayStoredSegment? in
            guard name.hasSuffix(".agsr") else { return nil }
            let parts = name.dropLast(5).split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appending(path: name).path)[.size] as? Int) ?? 0
            return SessionReplayStoredSegment(sessionID: sessionID, seq: parts[0], tFrom: parts[1], tTo: parts[2], bytes: size)
        }.sorted { $0.seq < $1.seq }
    }

    public func read(_ segment: SessionReplayStoredSegment) -> Data? {
        try? Data(contentsOf: folder(segment.sessionID).appending(path: "\(segment.seq)-\(segment.tFrom)-\(segment.tTo).agsr"))
    }

    public func remove(_ segment: SessionReplayStoredSegment) {
        try? FileManager.default.removeItem(at: folder(segment.sessionID).appending(path: "\(segment.seq)-\(segment.tFrom)-\(segment.tTo).agsr"))
    }

    /// Bytes of every segment kept.
    public func totalBytes() -> Int {
        sessionIDs().reduce(0) { sum, id in sum + segments(id).reduce(0) { $0 + $1.bytes } }
    }

    // MARK: - The metered allowance

    /// Bytes sent over a metered network on `day` (`yyyymmdd`, UTC).
    public func meteredBytes(day: String) -> Int {
        guard let data = try? Data(contentsOf: directory.appending(path: "metered.json")),
              let value = try? JSONDecoder().decode([String: Int].self, from: data) else { return 0 }
        return value[day] ?? 0
    }

    public func addMetered(_ bytes: Int, day: String) {
        let value = [day: meteredBytes(day: day) + bytes]
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: "metered.json"), options: .atomic)
    }
}
