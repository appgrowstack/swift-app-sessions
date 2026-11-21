import Foundation

// MARK: - Clock and ids

public protocol SessionClock: Sendable {
    /// Milliseconds since 1970.
    func nowMs() -> Int
}

public struct SystemSessionClock: SessionClock {
    public init() {}
    public func nowMs() -> Int { Int((Date().timeIntervalSince1970 * 1000).rounded(.down)) }
}

public protocol SessionIDGenerating: Sendable {
    /// `ses_` and 20 letters and digits.
    func makeSessionID() -> String
    /// A lowercase UUID, for a device that has no install id from the app.
    func makeInstallID() -> String
}

public struct RandomSessionIDs: SessionIDGenerating {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    public init() {}

    public func makeSessionID() -> String {
        var generator = SystemRandomNumberGenerator()
        return "ses_" + String((0..<20).map { _ in Self.alphabet.randomElement(using: &generator)! })
    }

    public func makeInstallID() -> String { UUID().uuidString.lowercased() }
}

// MARK: - What the next launch reads

/// The session that is still open, kept so the next launch can end it and send what was left.
public struct OpenSessionRecord: Sendable, Equatable, Codable {
    public var device: SessionDevice
    /// The `seq` the next batch of this session gets.
    public var nextSeq: Int
    public var lastKind: String
    public var lastT: Int
    /// Events not yet put into a batch.
    public var pending: [SessionEvent]
    /// The current screen's scroll depths, sent when it is left (or when the session is ended at the next launch).
    public var scrolls: [Scroll]

    public struct Scroll: Sendable, Equatable, Codable {
        public var screen: String
        public var list: String?
        public var maxRatio: Int
        public var maxRow: Int?
    }

    public init(device: SessionDevice, nextSeq: Int, lastKind: String, lastT: Int, pending: [SessionEvent],
                scrolls: [Scroll] = []) {
        self.device = device
        self.nextSeq = nextSeq
        self.lastKind = lastKind
        self.lastT = lastT
        self.pending = pending
        self.scrolls = scrolls
    }
}

/// The last session that ended, kept to send its `end` again when MetricKit's crash report comes late.
public struct ClosedSessionRecord: Sendable, Equatable, Codable {
    public var device: SessionDevice
    public var nextSeq: Int
    public var endT: Int
    public var reason: SessionEndReason
    /// What decided the reason, to decide it again with the late report.
    public var lastKind: String?
    public var runningFlag: Bool
}

public struct SessionStoredState: Sendable, Equatable, Codable {
    public var installID: String?
    /// A session has started on this install before (`first` is false from then on).
    public var hadSession: Bool
    /// Written when the app comes to the front, cleared when it goes to the back.
    public var running: Bool
    /// Android before API 30: the uncaught exception handler wrote that the app crashed.
    public var crashRecorded: Bool
    public var open: OpenSessionRecord?
    public var lastClosed: ClosedSessionRecord?
    /// Batches made but not taken by the sink yet, oldest first.
    public var outbox: [SessionBatch]

    public init(installID: String? = nil, hadSession: Bool = false, running: Bool = false, crashRecorded: Bool = false,
                open: OpenSessionRecord? = nil, lastClosed: ClosedSessionRecord? = nil, outbox: [SessionBatch] = []) {
        self.installID = installID
        self.hadSession = hadSession
        self.running = running
        self.crashRecorded = crashRecorded
        self.open = open
        self.lastClosed = lastClosed
        self.outbox = outbox
    }
}

/// Where the recorder keeps its state between launches. `save` is called on the main actor;
/// `setHangMarker` is called from the hang monitor's thread while the main thread is stuck, so a
/// session killed in a hang still ends as `hung`.
public protocol SessionStateStore: Sendable {
    func load() -> SessionStoredState?
    func save(_ state: SessionStoredState)
    func setHangMarker(_ on: Bool)
    func hangMarker() -> Bool
}

/// `<directory>/sessions/state.json` and the hang marker `<directory>/sessions/hang`.
public struct FileSessionStateStore: SessionStateStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.appending(path: "sessions", directoryHint: .isDirectory)
    }

    /// Application Support (the caches would be cleared under storage pressure).
    public static func standard() -> FileSessionStateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileSessionStateStore(directory: base)
    }

    public func load() -> SessionStoredState? {
        guard let data = try? Data(contentsOf: directory.appending(path: "state.json")) else { return nil }
        return try? JSONDecoder().decode(SessionStoredState.self, from: data)
    }

    public func save(_ state: SessionStoredState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: "state.json"), options: .atomic)
    }

    public func setHangMarker(_ on: Bool) {
        let file = directory.appending(path: "hang")
        if on {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func hangMarker() -> Bool { FileManager.default.fileExists(atPath: directory.appending(path: "hang").path) }
}

// MARK: - Exit information

/// What the platform knows at launch about how the previous run ended.
public struct SessionExitInfo: Sendable, Equatable {
    /// iOS: MetricKit already has a crash diagnostic for the previous run.
    public var metricKitCrash: Bool
    /// Android 30+: the newest `ApplicationExitInfo` reason (`REASON_CRASH` …).
    public var exitReason: String?
    /// Android: the API level. Nil means 30 or later.
    public var androidAPI: Int?

    public init(metricKitCrash: Bool = false, exitReason: String? = nil, androidAPI: Int? = nil) {
        self.metricKitCrash = metricKitCrash
        self.exitReason = exitReason
        self.androidAPI = androidAPI
    }

    public static let none = SessionExitInfo()
}
