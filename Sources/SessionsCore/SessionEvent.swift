import Foundation

/// One thing that happened in a session (`SessionEvent` in `schema/sessions/batch.schema.json`).
/// `t` is milliseconds from the start of the session. Positions are 0–10000 of the window.
public enum SessionEvent: Sendable, Equatable, Codable {
    case start(t: Int, previousEnd: SessionEndReason, previousSessionID: String?, first: Bool)
    case screen(t: Int, screen: String, via: SessionScreenVia, w: Double, h: Double, orientation: SessionOrientation)
    case tap(t: Int, x: Int, y: Int, screen: String, target: String?)
    case rage(t: Int, x: Int, y: Int, count: Int, screen: String)
    case dead(t: Int, x: Int, y: Int, screen: String)
    case back(t: Int, screen: String, via: SessionBackVia)
    case quickBack(t: Int, screen: String, ms: Int)
    case scroll(t: Int, screen: String, list: String?, maxRatio: Int, maxRow: Int?)
    case keyboard(t: Int, shown: Bool)
    case event(t: Int, name: String, props: [String: SessionValue], propsDropped: Bool)
    case mark(t: Int, kind: SessionMarkKind, ref: String, side: String?)
    case hang(t: Int, ms: Int)
    case background(t: Int)
    case foreground(t: Int)
    case end(t: Int, reason: SessionEndReason)
    /// The recording since the last batch (sessions.md 7.6 reads it).
    case replayStats(t: Int, stats: SessionReplayStats)

    public var t: Int {
        switch self {
        case .start(let t, _, _, _), .screen(let t, _, _, _, _, _), .tap(let t, _, _, _, _), .rage(let t, _, _, _, _),
             .dead(let t, _, _, _), .back(let t, _, _), .quickBack(let t, _, _), .scroll(let t, _, _, _, _),
             .keyboard(let t, _), .event(let t, _, _, _), .mark(let t, _, _, _), .hang(let t, _),
             .background(let t), .foreground(let t), .end(let t, _), .replayStats(let t, _):
            return t
        }
    }

    /// The `k` of the event in the batch.
    public var kind: String {
        switch self {
        case .start: "start"
        case .screen: "screen"
        case .tap: "tap"
        case .rage: "rage"
        case .dead: "dead"
        case .back: "back"
        case .quickBack: "quick_back"
        case .scroll: "scroll"
        case .keyboard: "keyboard"
        case .event: "event"
        case .mark: "mark"
        case .hang: "hang"
        case .background: "background"
        case .foreground: "foreground"
        case .end: "end"
        case .replayStats: "replay_stats"
        }
    }

    enum Key: String, CodingKey {
        case k, t, previous_end, previous_session_id, first, screen, via, w, h, orientation, x, y, target, count, ms
        case list, max_ratio, max_row, shown, name, props, props_dropped, kind, ref, side, reason
        case captured, dropped, main_ms_p50, main_ms_p95, stopped
    }

    public struct UnknownKind: Error, CustomStringConvertible {
        public let k: String
        public var description: String { "unknown session event k: \(k)" }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let k = try c.decode(String.self, forKey: .k)
        let t = try c.decode(Int.self, forKey: .t)
        switch k {
        case "start":
            self = .start(t: t, previousEnd: try c.decode(SessionEndReason.self, forKey: .previous_end),
                          previousSessionID: try c.decodeIfPresent(String.self, forKey: .previous_session_id),
                          first: try c.decode(Bool.self, forKey: .first))
        case "screen":
            self = .screen(t: t, screen: try c.decode(String.self, forKey: .screen),
                           via: try c.decode(SessionScreenVia.self, forKey: .via),
                           w: try c.decode(Double.self, forKey: .w), h: try c.decode(Double.self, forKey: .h),
                           orientation: try c.decode(SessionOrientation.self, forKey: .orientation))
        case "tap":
            self = .tap(t: t, x: try c.decode(Int.self, forKey: .x), y: try c.decode(Int.self, forKey: .y),
                        screen: try c.decode(String.self, forKey: .screen),
                        target: try c.decodeIfPresent(String.self, forKey: .target))
        case "rage":
            self = .rage(t: t, x: try c.decode(Int.self, forKey: .x), y: try c.decode(Int.self, forKey: .y),
                         count: try c.decode(Int.self, forKey: .count), screen: try c.decode(String.self, forKey: .screen))
        case "dead":
            self = .dead(t: t, x: try c.decode(Int.self, forKey: .x), y: try c.decode(Int.self, forKey: .y),
                         screen: try c.decode(String.self, forKey: .screen))
        case "back":
            self = .back(t: t, screen: try c.decode(String.self, forKey: .screen),
                         via: try c.decode(SessionBackVia.self, forKey: .via))
        case "quick_back":
            self = .quickBack(t: t, screen: try c.decode(String.self, forKey: .screen), ms: try c.decode(Int.self, forKey: .ms))
        case "scroll":
            self = .scroll(t: t, screen: try c.decode(String.self, forKey: .screen),
                           list: try c.decodeIfPresent(String.self, forKey: .list),
                           maxRatio: try c.decode(Int.self, forKey: .max_ratio),
                           maxRow: try c.decodeIfPresent(Int.self, forKey: .max_row))
        case "keyboard":
            self = .keyboard(t: t, shown: try c.decode(Bool.self, forKey: .shown))
        case "event":
            self = .event(t: t, name: try c.decode(String.self, forKey: .name),
                          props: try c.decodeIfPresent([String: SessionValue].self, forKey: .props) ?? [:],
                          propsDropped: try c.decodeIfPresent(Bool.self, forKey: .props_dropped) ?? false)
        case "mark":
            self = .mark(t: t, kind: try c.decode(SessionMarkKind.self, forKey: .kind),
                         ref: try c.decode(String.self, forKey: .ref), side: try c.decodeIfPresent(String.self, forKey: .side))
        case "hang":
            self = .hang(t: t, ms: try c.decode(Int.self, forKey: .ms))
        case "background":
            self = .background(t: t)
        case "foreground":
            self = .foreground(t: t)
        case "end":
            self = .end(t: t, reason: try c.decode(SessionEndReason.self, forKey: .reason))
        case "replay_stats":
            let dropped = try c.decode(SessionReplayStats.Dropped.self, forKey: .dropped)
            self = .replayStats(t: t, stats: SessionReplayStats(
                captured: try c.decode(Int.self, forKey: .captured), dropped: dropped,
                mainMsP50: try c.decode(Double.self, forKey: .main_ms_p50),
                mainMsP95: try c.decode(Double.self, forKey: .main_ms_p95),
                stopped: try c.decodeIfPresent(String.self, forKey: .stopped)))
        default:
            throw UnknownKind(k: k)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(kind, forKey: .k)
        try c.encode(t, forKey: .t)
        switch self {
        case .start(_, let previousEnd, let previousSessionID, let first):
            try c.encode(previousEnd, forKey: .previous_end)
            try c.encodeIfPresent(previousSessionID, forKey: .previous_session_id)
            try c.encode(first, forKey: .first)
        case .screen(_, let screen, let via, let w, let h, let orientation):
            try c.encode(screen, forKey: .screen)
            try c.encode(via, forKey: .via)
            try c.encode(w, forKey: .w)
            try c.encode(h, forKey: .h)
            try c.encode(orientation, forKey: .orientation)
        case .tap(_, let x, let y, let screen, let target):
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(screen, forKey: .screen)
            try c.encodeIfPresent(target, forKey: .target)
        case .rage(_, let x, let y, let count, let screen):
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(count, forKey: .count)
            try c.encode(screen, forKey: .screen)
        case .dead(_, let x, let y, let screen):
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(screen, forKey: .screen)
        case .back(_, let screen, let via):
            try c.encode(screen, forKey: .screen)
            try c.encode(via, forKey: .via)
        case .quickBack(_, let screen, let ms):
            try c.encode(screen, forKey: .screen)
            try c.encode(ms, forKey: .ms)
        case .scroll(_, let screen, let list, let maxRatio, let maxRow):
            try c.encode(screen, forKey: .screen)
            try c.encodeIfPresent(list, forKey: .list)
            try c.encode(maxRatio, forKey: .max_ratio)
            try c.encodeIfPresent(maxRow, forKey: .max_row)
        case .keyboard(_, let shown):
            try c.encode(shown, forKey: .shown)
        case .event(_, let name, let props, let propsDropped):
            try c.encode(name, forKey: .name)
            if !props.isEmpty { try c.encode(props, forKey: .props) }
            if propsDropped { try c.encode(true, forKey: .props_dropped) }
        case .mark(_, let kind, let ref, let side):
            try c.encode(kind, forKey: .kind)
            try c.encode(ref, forKey: .ref)
            try c.encodeIfPresent(side, forKey: .side)
        case .hang(_, let ms):
            try c.encode(ms, forKey: .ms)
        case .background, .foreground:
            break
        case .end(_, let reason):
            try c.encode(reason, forKey: .reason)
        case .replayStats(_, let stats):
            try c.encode(stats.captured, forKey: .captured)
            try c.encode(stats.dropped, forKey: .dropped)
            try c.encode(stats.mainMsP50, forKey: .main_ms_p50)
            try c.encode(stats.mainMsP95, forKey: .main_ms_p95)
            try c.encodeIfPresent(stats.stopped, forKey: .stopped)
        }
    }
}

/// What the recording did since the last batch (`replay_stats` in `schema/sessions/batch.schema.json`):
/// frames with a picture, frames without one and why, the main thread's time a frame took, and why
/// the recording stopped when it did.
public struct SessionReplayStats: Sendable, Equatable {
    public struct Dropped: Sendable, Equatable, Codable {
        public var same: Int
        public var masking_failed: Int
        public var no_capture: Int
        public var secure: Int

        public init(same: Int = 0, maskingFailed: Int = 0, noCapture: Int = 0, secure: Int = 0) {
            self.same = same
            self.masking_failed = maskingFailed
            self.no_capture = noCapture
            self.secure = secure
        }

        public var isEmpty: Bool { same == 0 && masking_failed == 0 && no_capture == 0 && secure == 0 }
    }

    public var captured: Int
    public var dropped: Dropped
    public var mainMsP50: Double
    public var mainMsP95: Double
    /// `ReplayStopReason`: why frames stopped in this stretch, if they did.
    public var stopped: String?

    public init(captured: Int, dropped: Dropped, mainMsP50: Double, mainMsP95: Double, stopped: String? = nil) {
        self.captured = captured
        self.dropped = dropped
        self.mainMsP50 = mainMsP50
        self.mainMsP95 = mainMsP95
        self.stopped = stopped
    }
}
