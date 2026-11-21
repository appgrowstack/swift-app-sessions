import Foundation

/// The device's values for one session, fixed at its start (`SessionDevice` in the batch schema).
public struct SessionDevice: Sendable, Equatable, Codable {
    public var sessionID: String
    /// When the session started (milliseconds since 1970). Event times count from here.
    public var startedAt: Int
    public var installID: String
    public var uid: String?
    public var platform: SessionPlatform
    public var appVersion: String
    public var build: String
    /// `appstore`, `testflight`, `play`, `play_test` or `debug`.
    public var channel: String
    public var lang: String
    public var region: String
    public var timeZone: String
    public var osVersion: String
    public var deviceModel: String
    public var screen: Screen
    public var sdkVersion: String

    public struct Screen: Sendable, Equatable, Codable {
        public var w: Double
        public var h: Double
        public var scale: Double

        public init(w: Double, h: Double, scale: Double) {
            self.w = w
            self.h = h
            self.scale = scale
        }
    }

    public init(sessionID: String, startedAt: Int, info: SessionDeviceInfo, installID: String) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.installID = installID
        self.uid = info.uid
        self.platform = info.platform
        self.appVersion = info.appVersion
        self.build = info.build
        self.channel = info.channel
        self.lang = info.lang
        self.region = info.region
        self.timeZone = info.timeZone
        self.osVersion = info.osVersion
        self.deviceModel = info.deviceModel
        self.screen = info.screen
        self.sdkVersion = info.sdkVersion
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case startedAt = "started_at"
        case installID = "install_id"
        case uid, platform
        case appVersion = "app_version"
        case build, channel, lang, region
        case timeZone = "time_zone"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case screen
        case sdkVersion = "sdk_version"
    }
}

/// What the platform knows about the device and the app. `SessionsCapture` fills it from UIKit
/// (`SessionDeviceInfo.current(channel:)`); tests and other platforms build it by hand.
public struct SessionDeviceInfo: Sendable, Equatable {
    /// The app's own install id when it has one. Without it the recorder keeps its own (a lowercase UUID).
    public var installID: String?
    public var uid: String?
    public var platform: SessionPlatform
    public var appVersion: String
    public var build: String
    public var channel: String
    public var lang: String
    public var region: String
    public var timeZone: String
    public var osVersion: String
    public var deviceModel: String
    public var screen: SessionDevice.Screen
    public var sdkVersion: String

    public init(installID: String? = nil, uid: String? = nil, platform: SessionPlatform = .ios, appVersion: String,
                build: String, channel: String, lang: String, region: String, timeZone: String, osVersion: String,
                deviceModel: String, screen: SessionDevice.Screen, sdkVersion: String = SessionsSDK.version) {
        self.installID = installID
        self.uid = uid
        self.platform = platform
        self.appVersion = appVersion
        self.build = build
        self.channel = channel
        self.lang = lang
        self.region = region
        self.timeZone = timeZone
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.screen = screen
        self.sdkVersion = sdkVersion
    }
}

/// One batch of a session's events (`SessionBatch`). `seq` counts from 0 within the session; a
/// batch sent again keeps its `seq`, so the receiver can drop the second copy.
public struct SessionBatch: Sendable, Equatable, Codable {
    public var session: SessionDevice
    public var seq: Int
    public var events: [SessionEvent]

    public init(session: SessionDevice, seq: Int, events: [SessionEvent]) {
        self.session = session
        self.seq = seq
        self.events = events
    }

    /// The batch as the JSON body of the schema.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// What a sink answers for a batch.
public enum SessionSinkReply: Sendable, Equatable {
    /// Taken. `replay` is the receiver's decision for the recording (nil: no decision, stay on
    /// `buffer`). `keepProps` replaces the kept properties when the receiver has newer ones.
    case accepted(replay: SessionReplayMode? = nil, keepProps: [String: [String]]? = nil)
    /// The receiver does not take sessions (sessions turned off or paused). The recorder drops what
    /// it holds for this session and records nothing more until the next session.
    case disabled
}

/// Where batches go. The package has two that need nothing else: ``FileSessionSink`` (keeps them
/// on the device) and ``DebugSessionSink`` (keeps the last ones in memory to look at). A throw
/// keeps the batch to send again later.
public protocol SessionSink: Sendable {
    func send(_ batch: SessionBatch) async throws -> SessionSinkReply
}

