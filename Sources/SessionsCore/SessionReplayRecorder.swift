import Foundation

/// One segment to send: `PUT /v1/sessions/:session_id/segments/:seq` with the session's upload token.
public struct SessionReplayUpload: Sendable, Equatable {
    public var sessionID: String
    public var seq: Int
    public var token: String
    /// The `.agsr` bytes.
    public var body: Data

    public init(sessionID: String, seq: Int, token: String, body: Data) {
        self.sessionID = sessionID
        self.seq = seq
        self.token = token
        self.body = body
    }
}

/// What a replay sink answers for a segment. A throw keeps it to send again later.
public enum SessionReplayUploadReply: Sendable, Equatable {
    /// Taken (or taken before): the device drops it.
    case stored
    /// This segment will never be taken (a body the receiver cannot read, too large): drop it.
    case dropSegment
    /// No segment of this session will be taken (the token is not this session's, or it expired;
    /// the session is unknown; sessions are off): drop all of them.
    case dropSession
}

/// Where the recording's segments go. ``SessionReplayRecorder`` keeps a segment until it is
/// `stored` or dropped; a throw keeps it for the next try.
public protocol SessionReplaySink: Sendable {
    func upload(_ segment: SessionReplayUpload) async throws -> SessionReplayUploadReply
}

/// The recording (sessions.md 3.2): frames into segments (`.agsr`), kept on the device and sent by
/// the rules of sessions.md 5. `SessionsCapture` takes the frames (``SessionReplayCapture``); this
/// type decides what to keep and what to send.
///
/// - `record` (the sink's answer): every segment is sent
/// - `buffer`: only the last 60 seconds are kept; when a priority condition is met in the session
///   (``AppSessions/priorityHit``) they are sent, and every later one too. When the previous session
///   ended `crashed`, `hung` or `killed`, what is left of it is sent
/// - Over a metered or constrained network only priority sessions are sent, up to 3MB a day
/// - A session's recording stops at 30 minutes or 20MB; the device keeps 50MB for 7 days at most
@MainActor
public final class SessionReplayRecorder {
    public struct Configuration: Sendable {
        /// A segment closes after this long (record) …
        public var segmentMs: Int
        /// … or this long while buffering, so the last 60 seconds can be kept without the older ones.
        public var bufferSegmentMs: Int
        /// … or when its images weigh this much (the whole segment stays under 1MB) …
        public var segmentBytes: Int
        /// … or at this many frames (the schema's 600).
        public var maxFramesPerSegment: Int
        /// While buffering, segments older than this are dropped.
        public var bufferMs: Int
        /// At most one frame this often goes into the recording.
        public var minFrameIntervalMs: Int
        public var sessionMaxMs: Int
        public var sessionMaxBytes: Int
        public var storeMaxBytes: Int
        public var keepMs: Int
        /// While in the front, segments go out this often.
        public var uploadIntervalMs: Int
        /// Priority sessions over a metered network, per day.
        public var meteredDailyBytes: Int

        public init(segmentMs: Int = 60_000, bufferSegmentMs: Int = 10_000, segmentBytes: Int = 900_000,
                    maxFramesPerSegment: Int = 600, bufferMs: Int = 60_000, minFrameIntervalMs: Int = 900,
                    sessionMaxMs: Int = 30 * 60_000, sessionMaxBytes: Int = 20 * 1024 * 1024,
                    storeMaxBytes: Int = 50 * 1024 * 1024, keepMs: Int = 7 * 86_400_000,
                    uploadIntervalMs: Int = 60_000, meteredDailyBytes: Int = 3 * 1024 * 1024) {
            self.segmentMs = segmentMs
            self.bufferSegmentMs = bufferSegmentMs
            self.segmentBytes = segmentBytes
            self.maxFramesPerSegment = maxFramesPerSegment
            self.bufferMs = bufferMs
            self.minFrameIntervalMs = minFrameIntervalMs
            self.sessionMaxMs = sessionMaxMs
            self.sessionMaxBytes = sessionMaxBytes
            self.storeMaxBytes = storeMaxBytes
            self.keepMs = keepMs
            self.uploadIntervalMs = uploadIntervalMs
            self.meteredDailyBytes = meteredDailyBytes
        }
    }

    /// The network segments would go over.
    public enum Network: Sendable, Equatable {
        case unmetered
        /// Metered (cellular, a hotspot) or constrained (Low Data Mode).
        case metered
        case offline
    }

    /// Why the recording takes no frames (`ReplayStopReason`).
    public enum StopReason: String, Sendable, Equatable {
        case lowPower = "low_power"
        case thermal
        case battery
        case degraded
        case sessionLimit = "session_limit"
        case disabled
        case storage
    }

    /// One frame from the capture.
    public enum Frame: Sendable, Equatable {
        /// A picture, already painted over where it must be hidden. `fingerprint` is the brightness
        /// of a small copy: the same fingerprint as the frame before makes a `same` frame.
        case image(Data, mime: String, w: Int, h: Int, masked: Bool, fingerprint: String)
        /// Not taken.
        case blank(SessionBlankReason, w: Int, h: Int)
    }

    public let sessions: AppSessions
    public let sink: any SessionReplaySink
    public let store: SessionReplayStore
    public let configuration: Configuration
    private let clock: any SessionClock

    public var network: Network = .unmetered
    /// Set by the capture while the device should not record (Low Power Mode, heat, a low battery,
    /// frames too slow to take). Frames are not taken; the light record goes on.
    public var paused: StopReason? {
        didSet { if paused != nil { closeSegment() } }
    }

    private var builder: Builder?
    private var metas: [String: SessionReplayMeta] = [:]
    private var uploading = false
    private var lastUploadAt = 0
    private var lastFrameT: [String: Int] = [:]

    private struct Builder {
        var sessionID: String
        var seq: Int
        var frames: [SessionReplayFrame] = []
        var images: [Data] = []
        var imageBytes = 0
        var lastFingerprint: String?
    }

    public init(sessions: AppSessions, sink: any SessionReplaySink, store: SessionReplayStore = .standard(),
                clock: any SessionClock = SystemSessionClock(), configuration: Configuration = .init()) {
        self.sessions = sessions
        self.sink = sink
        self.store = store
        self.clock = clock
        self.configuration = configuration
        sessions.onUploadToken = { [weak self] sessionID, token in self?.tokenArrived(token, for: sessionID) }
        sessions.onPriority = { [weak self] sessionID in self?.priorityMet(in: sessionID) }
        sessions.onSessionStart = { [weak self] sessionID in self?.sessionStarted(sessionID) }
    }

    // MARK: - What the capture reads

    /// Frames are wanted now: a session is open, its recording has not stopped, and nothing paused it.
    public var wantsFrames: Bool {
        guard paused == nil, let id = sessions.currentSessionID else { return false }
        return !(metas[id]?.stopped ?? false)
    }

    /// Why no frames are taken, if they are not.
    public var stopReason: StopReason? {
        if let paused { return paused }
        if let id = sessions.currentSessionID, metas[id]?.stopped == true { return .sessionLimit }
        return nil
    }

    /// Segments waiting on the device.
    public var waitingSegments: Int { store.sessionIDs().reduce(0) { $0 + store.segments($1).count } }

    // MARK: - Frames

    /// Adds a frame taken at `atMs` (milliseconds since 1970) to the current session's recording.
    public func add(_ frame: Frame, atMs: Int) {
        guard paused == nil, let id = sessions.currentSessionID, let startedAt = sessions.currentSessionStartedAt else { return }
        if builder?.sessionID != id { closeSegment() }
        var meta = self.meta(for: id, startedAt: startedAt)
        guard !meta.stopped else { return }
        let t = max(0, atMs - startedAt)
        if let last = lastFrameT[id], t - last < configuration.minFrameIntervalMs { return }
        lastFrameT[id] = t
        if t >= configuration.sessionMaxMs || meta.bytes >= configuration.sessionMaxBytes {
            closeSegment()
            meta = self.meta(for: id, startedAt: startedAt)
            meta.stopped = true
            save(meta)
            return
        }
        var current = builder ?? Builder(sessionID: id, seq: meta.nextSeq)
        switch frame {
        case .image(let data, let mime, let w, let h, let masked, let fingerprint):
            if fingerprint == current.lastFingerprint, current.frames.last?.kind != .blank {
                current.frames.append(SessionReplayFrame(t: t, kind: .same, w: w, h: h, masked: masked))
            } else {
                if current.imageBytes + data.count > configuration.segmentBytes, !current.frames.isEmpty {
                    builder = current
                    closeSegment()
                    current = Builder(sessionID: id, seq: self.meta(for: id, startedAt: startedAt).nextSeq)
                }
                current.frames.append(SessionReplayFrame(t: t, kind: .image, mime: mime, w: w, h: h, masked: masked))
                current.images.append(data)
                current.imageBytes += data.count
                current.lastFingerprint = fingerprint
            }
            sessions.isCapturing = true
        case .blank(let reason, let w, let h):
            current.frames.append(SessionReplayFrame(t: t, kind: .blank, w: max(1, w), h: max(1, h), masked: false, reason: reason))
            current.lastFingerprint = nil
        }
        builder = current
        let span = t - (current.frames.first?.t ?? t)
        let limit = syncedMeta(id).mode == .record || meta.priority ? configuration.segmentMs : configuration.bufferSegmentMs
        if span >= limit || current.frames.count >= configuration.maxFramesPerSegment || current.imageBytes >= configuration.segmentBytes {
            closeSegment()
        }
    }

    /// Writes the frames gathered so far as a segment.
    public func closeSegment() {
        guard let current = builder, let first = current.frames.first, let last = current.frames.last else {
            builder = nil
            return
        }
        builder = nil
        let header = SessionReplaySegmentHeader(sessionID: current.sessionID, seq: current.seq, tFrom: first.t, tTo: last.t, frames: current.frames)
        guard let data = try? SessionReplaySegment(header: header, images: current.images).encoded(),
              data.count <= SessionReplaySegment.maxBytes,
              var meta = metas[current.sessionID] ?? store.meta(current.sessionID) else { return }
        store.write(data, sessionID: current.sessionID, seq: current.seq, tFrom: first.t, tTo: last.t)
        meta.nextSeq = max(meta.nextSeq, current.seq + 1)
        meta.bytes += data.count
        save(meta)
        let synced = syncedMeta(current.sessionID)
        if synced.mode == .buffer, !synced.priority {
            for segment in store.segments(current.sessionID) where segment.tTo < last.t - configuration.bufferMs {
                store.remove(segment)
            }
        }
        prune()
    }

    // MARK: - Sending

    /// Sends what may leave the device now, oldest session first. `closing` also writes the segment
    /// being gathered (going to the back). Stops at the first throw and keeps the rest.
    public func flush(closing: Bool = false) async {
        if closing { closeSegment() }
        guard !uploading, network != .offline else { return }
        uploading = true
        defer { uploading = false }
        lastUploadAt = clock.nowMs()
        let day = Self.utcDay(clock.nowMs())
        let ids = store.sessionIDs().compactMap { id in metas[id] ?? store.meta(id) }.sorted { $0.startedAt < $1.startedAt }.map(\.sessionID)
        for id in ids {
            let meta = syncedMeta(id)
            guard meta.mayUpload, let token = meta.token else { continue }
            if network == .metered, !meta.priority { continue }
            for segment in store.segments(id) {
                if network == .metered, store.meteredBytes(day: day) + segment.bytes > configuration.meteredDailyBytes { return }
                guard let body = store.read(segment) else {
                    store.remove(segment)
                    continue
                }
                let reply: SessionReplayUploadReply
                do {
                    reply = try await sink.upload(SessionReplayUpload(sessionID: id, seq: segment.seq, token: token, body: body))
                } catch {
                    return
                }
                if network == .metered { store.addMetered(body.count, day: day) }
                switch reply {
                case .stored, .dropSegment:
                    store.remove(segment)
                case .dropSession:
                    var dropped = self.meta(for: id, startedAt: meta.startedAt)
                    dropped.token = nil
                    dropped.stopped = true
                    save(dropped)
                    for rest in store.segments(id) { store.remove(rest) }
                }
            }
            if id != sessions.currentSessionID, store.segments(id).isEmpty {
                store.removeSession(id)
                metas[id] = nil
            }
        }
    }

    /// Call every few seconds while in the front: closes a segment that is due and sends every
    /// ``Configuration/uploadIntervalMs``.
    public func tick() {
        if let current = builder, let first = current.frames.first, let startedAt = sessions.currentSessionStartedAt {
            let t = clock.nowMs() - startedAt
            let limit = syncedMeta(current.sessionID).mode == .record ? configuration.segmentMs : configuration.bufferSegmentMs
            if t - first.t >= limit { closeSegment() }
        }
        if clock.nowMs() - lastUploadAt >= configuration.uploadIntervalMs {
            Task { await flush() }
        }
    }

    // MARK: - Inside

    private func meta(for id: String, startedAt: Int) -> SessionReplayMeta {
        if let meta = metas[id] { return meta }
        let meta = store.meta(id) ?? SessionReplayMeta(sessionID: id, startedAt: startedAt)
        metas[id] = meta
        return meta
    }

    /// The meta with the current session's decision from the sink.
    private func syncedMeta(_ id: String) -> SessionReplayMeta {
        guard var meta = metas[id] ?? store.meta(id) else {
            return SessionReplayMeta(sessionID: id, startedAt: 0)
        }
        if id == sessions.currentSessionID {
            let mode = sessions.replayMode
            let priority = meta.priority || sessions.priorityHit
            if mode != meta.mode || priority != meta.priority {
                meta.mode = mode
                meta.priority = priority
                save(meta)
            }
        }
        return meta
    }

    private func save(_ meta: SessionReplayMeta) {
        metas[meta.sessionID] = meta
        store.saveMeta(meta)
    }

    private func tokenArrived(_ token: String, for sessionID: String) {
        var meta = metas[sessionID] ?? store.meta(sessionID)
            ?? SessionReplayMeta(sessionID: sessionID, startedAt: sessions.currentSessionID == sessionID ? (sessions.currentSessionStartedAt ?? clock.nowMs()) : clock.nowMs())
        meta.token = token
        save(meta)
    }

    private func priorityMet(in sessionID: String) {
        guard var meta = metas[sessionID] ?? store.meta(sessionID) else { return }
        meta.priority = true
        save(meta)
        Task { await flush() }
    }

    private func sessionStarted(_ sessionID: String) {
        closeSegment()
        if sessions.previousSessionEndedBadly, let previous = sessions.previousSessionID,
           var meta = metas[previous] ?? store.meta(previous) {
            meta.priority = true
            save(meta)
        }
        metas[sessionID] = nil
    }

    /// Drops sessions older than ``Configuration/keepMs`` and, over ``Configuration/storeMaxBytes``,
    /// the oldest segments of sessions that will not be sent first, then the oldest of the rest.
    private func prune() {
        let now = clock.nowMs()
        for id in store.sessionIDs() {
            guard let meta = metas[id] ?? store.meta(id) else {
                store.removeSession(id)
                continue
            }
            if now - meta.startedAt > configuration.keepMs {
                store.removeSession(id)
                metas[id] = nil
            }
        }
        var total = store.totalBytes()
        guard total > configuration.storeMaxBytes else { return }
        let all = store.sessionIDs().compactMap { metas[$0] ?? store.meta($0) }
        let order = all.sorted { a, b in
            if a.mayUpload != b.mayUpload { return !a.mayUpload }
            return a.startedAt < b.startedAt
        }
        for meta in order {
            for segment in store.segments(meta.sessionID) {
                guard total > configuration.storeMaxBytes else { return }
                store.remove(segment)
                total -= segment.bytes
            }
        }
    }

    static func utcDay(_ ms: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}
