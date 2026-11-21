import Foundation

/// The rules of the light record as pure functions: no clock, storage or network. The recorder
/// uses the same code, and `schema/cases/sessions` checks every one against Kotlin and TypeScript.
public enum SessionRules {
    /// 30 minutes in the background starts a new session (30 minutes exactly included).
    public static let backgroundTimeoutMs = 1_800_000
    public static let rageWindowMs = 1000
    public static let rageRadius: Double = 30
    public static let rageMinTaps = 3
    public static let deadWindowMs = 1500
    public static let quickBackMs = 2000
    /// A text value longer than this (UTF-16 code units) is dropped from kept props.
    public static let maxPropLength = 48
    public static let gridColumns = 40
    public static let gridRows = 80

    // MARK: - Split

    public enum LifecycleStep: String, Sendable, Codable {
        case launch, background, foreground
    }

    public struct SplitSession: Sendable, Equatable {
        public enum By: String, Sendable, Equatable {
            case backgroundTimeout = "background_timeout"
            case launch
        }

        public var start: Int
        /// When a background timeout ended it: the time it went to the background.
        public var end: Int?
        public var by: By?
    }

    public struct Split: Sendable, Equatable {
        /// Which session (from 0) each step belongs to.
        public var sessionOfStep: [Int]
        public var sessions: [SplitSession]
    }

    /// Launch always starts a session. Coming to the foreground starts one when the app was in the
    /// background for ``backgroundTimeoutMs`` or longer. A change of date does not split.
    public static func split(_ steps: [(t: Int, k: LifecycleStep)]) -> Split {
        var sessions: [SplitSession] = []
        var sessionOf: [Int] = []
        var backgroundAt: Int?
        for step in steps {
            switch step.k {
            case .launch:
                if !sessions.isEmpty { sessions[sessions.count - 1].by = .launch }
                sessions.append(SplitSession(start: step.t))
                backgroundAt = nil
            case .background:
                if sessions.isEmpty { sessions.append(SplitSession(start: step.t)) }
                backgroundAt = step.t
            case .foreground:
                if sessions.isEmpty {
                    sessions.append(SplitSession(start: step.t))
                } else if let at = backgroundAt, step.t - at >= backgroundTimeoutMs {
                    sessions[sessions.count - 1].end = at
                    sessions[sessions.count - 1].by = .backgroundTimeout
                    sessions.append(SplitSession(start: step.t))
                }
                backgroundAt = nil
            }
            sessionOf.append(sessions.count - 1)
        }
        return Split(sessionOfStep: sessionOf, sessions: sessions)
    }

    // MARK: - Tap position

    public struct NormalizedTap: Sendable, Equatable {
        public var x: Int
        public var y: Int
        public var orientation: SessionOrientation
        public var col: Int
        public var row: Int
        /// `row × 40 + col` (0–3199).
        public var cell: Int
    }

    /// A tap in screen points and the window's frame in screen points → 0–10000 of the window and
    /// the cell of the 40 × 80 grid.
    public static func normalizeTap(x: Double, y: Double, window: SessionRect) -> NormalizedTap {
        let nx = fraction(x - window.x, of: window.w)
        let ny = fraction(y - window.y, of: window.h)
        let col = min(gridColumns - 1, nx * gridColumns / 10000)
        let row = min(gridRows - 1, ny * gridRows / 10000)
        return NormalizedTap(x: nx, y: ny, orientation: window.size.orientation, col: col, row: row,
                             cell: row * gridColumns + col)
    }

    /// `round(value × 10000 / whole)` with .5 going up, kept in 0–10000.
    static func fraction(_ value: Double, of whole: Double) -> Int {
        guard whole > 0 else { return 0 }
        let scaled = (value * 10000 / whole + 0.5).rounded(.down)
        return Int(min(10000, max(0, scaled)))
    }

    // MARK: - Rage

    public struct Tap: Sendable, Equatable {
        public var t: Int
        public var x: Double
        public var y: Double

        public init(t: Int, x: Double, y: Double) {
            self.t = t
            self.x = x
            self.y = y
        }
    }

    public struct Rage: Sendable, Equatable {
        /// The time of the third tap.
        public var t: Int
        public var x: Int
        public var y: Int
        public var count: Int
    }

    /// Taps in window points → rage taps. See ``RageDetector``.
    public static func rage(_ taps: [Tap], window: SessionSize) -> [Rage] {
        var detector = RageDetector(window: window)
        var found = taps.compactMap { detector.add($0) }
        if let last = detector.finish() { found.append(last) }
        return found
    }

    // MARK: - Dead

    public struct After: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case screen, event, frame
        }

        public var t: Int
        public var k: Kind
        public var fingerprint: String?

        public init(t: Int, k: Kind, fingerprint: String? = nil) {
            self.t = t
            self.k = k
            self.fingerprint = fingerprint
        }
    }

    /// Whether a tap did nothing: no screen, no app event and no change of the frame in
    /// `(t, t + 1500]`. Without frames to compare (not capturing, or none in the window) it is not dead.
    public static func isDead(capturing: Bool, tapAt t: Int, fingerprintBefore: String, after: [After]) -> Bool {
        guard capturing else { return false }
        let inWindow = after.filter { $0.t > t && $0.t <= t + deadWindowMs }
        if inWindow.contains(where: { $0.k == .screen || $0.k == .event }) { return false }
        let frames = inWindow.filter { $0.k == .frame }
        guard !frames.isEmpty else { return false }
        return frames.allSatisfy { $0.fingerprint == fingerprintBefore }
    }

    // MARK: - Navigation and quick back

    public enum NavigationOp: String, Sendable, Codable {
        case launch, push, tab, sheet, pop, dismiss
    }

    public struct NavigationStep: Sendable, Equatable {
        public var t: Int
        public var op: NavigationOp
        /// The screen shown after the move.
        public var screen: String
        public var by: SessionBackVia?

        public init(t: Int, op: NavigationOp, screen: String, by: SessionBackVia? = nil) {
            self.t = t
            self.op = op
            self.screen = screen
            self.by = by
        }
    }

    public enum NavigationEvent: Sendable, Equatable {
        case screen(t: Int, screen: String, via: SessionScreenVia)
        case back(t: Int, screen: String, via: SessionBackVia)
        case quickBack(t: Int, screen: String, ms: Int)
    }

    /// Moves between screens → the `screen`, `back` and `quick_back` events. See ``Navigator``.
    public static func navigate(_ steps: [NavigationStep]) -> [NavigationEvent] {
        var navigator = Navigator()
        return steps.flatMap { navigator.move($0) }
    }

    // MARK: - End reason

    /// What the next launch knows about the previous session.
    public struct EndInput: Sendable, Equatable {
        public var platform: SessionPlatform
        /// Android only. Nil means 30 or later.
        public var androidAPI: Int?
        public var previousRecord: Bool
        /// The "running" flag written when the app came to the front and cleared when it went to the back.
        public var runningFlag: Bool
        /// The `k` of the previous session's last event.
        public var lastEvent: String?
        /// iOS: MetricKit had a crash diagnostic for it at launch.
        public var metricKitCrash: Bool
        /// iOS: MetricKit delivered a crash diagnostic for it after the launch.
        public var lateMetricKitCrash: Bool
        /// Android 30+: the newest `ApplicationExitInfo` reason, as `REASON_…`.
        public var exitReason: String?
        /// Android before 30: the SDK's uncaught exception handler wrote a record.
        public var crashHandler: Bool

        public init(platform: SessionPlatform, androidAPI: Int? = nil, previousRecord: Bool, runningFlag: Bool,
                    lastEvent: String? = nil, metricKitCrash: Bool = false, lateMetricKitCrash: Bool = false,
                    exitReason: String? = nil, crashHandler: Bool = false) {
            self.platform = platform
            self.androidAPI = androidAPI
            self.previousRecord = previousRecord
            self.runningFlag = runningFlag
            self.lastEvent = lastEvent
            self.metricKitCrash = metricKitCrash
            self.lateMetricKitCrash = lateMetricKitCrash
            self.exitReason = exitReason
            self.crashHandler = crashHandler
        }
    }

    public struct EndDecision: Sendable, Equatable {
        public var reason: SessionEndReason
        /// The reason after a late MetricKit crash diagnostic. The recorder sends `end` again with it.
        public var revised: SessionEndReason?
    }

    public static func endReason(_ input: EndInput) -> EndDecision {
        let reason = baseEndReason(input)
        var revised: SessionEndReason?
        if input.platform == .ios, input.lateMetricKitCrash, input.runningFlag, reason == .killed || reason == .hung {
            revised = .crashed
        }
        return EndDecision(reason: reason, revised: revised)
    }

    private static func baseEndReason(_ input: EndInput) -> SessionEndReason {
        guard input.previousRecord else { return .unknown }
        let android = input.platform == .android
        let modernAndroid = (input.androidAPI ?? 30) >= 30
        if android, modernAndroid, input.exitReason == "REASON_USER_REQUESTED" { return .userClosed }
        guard input.runningFlag else { return .backgroundTimeout }
        let crashed: Bool
        if android {
            crashed = modernAndroid
                ? input.exitReason == "REASON_CRASH" || input.exitReason == "REASON_CRASH_NATIVE"
                : input.crashHandler
        } else {
            crashed = input.metricKitCrash
        }
        if crashed { return .crashed }
        if input.lastEvent == "hang" || (android && modernAndroid && input.exitReason == "REASON_ANR") { return .hung }
        if android, !modernAndroid { return .unknown }
        return .killed
    }

    // MARK: - Scroll depth

    public struct ScrollSample: Sendable, Equatable {
        public var offsetY: Double
        public var height: Double
        public var contentHeight: Double
        public var row: Int?

        public init(offsetY: Double, height: Double, contentHeight: Double, row: Int? = nil) {
            self.offsetY = offsetY
            self.height = height
            self.contentHeight = contentHeight
            self.row = row
        }

        /// How deep the bottom edge of what is visible is (0–10000). Content shorter than the view is 10000.
        public var ratio: Int {
            guard contentHeight > height else { return 10000 }
            let value = ((offsetY + height) * 10000 / contentHeight).rounded(.down)
            return Int(min(10000, max(0, value)))
        }
    }

    public struct ScrollDepth: Sendable, Equatable {
        public var maxRatio: Int
        public var maxRow: Int?
    }

    public static func scrollDepth(_ samples: [ScrollSample]) -> ScrollDepth {
        ScrollDepth(maxRatio: samples.map(\.ratio).max() ?? 0, maxRow: samples.compactMap(\.row).max())
    }

    // MARK: - Kept props

    public enum EventSource: String, Sendable {
        /// The shared catalog of swift-analytics (``commonCatalog``).
        case common
        case app
    }

    /// The events of swift-analytics' shared catalog. Their values are choices, counts and yes/no.
    public static let commonCatalog: Set<String> = [
        "first_open", "internal_device", "screen_viewed", "tapped", "onboarding_step", "onboarding_completed",
        "signed_in", "experiment_assigned", "paywall_shown", "paywall_loaded", "paywall_scrolled",
        "paywall_plan_selected", "paywall_purchase_tapped", "paywall_purchase_result", "paywall_backgrounded",
        "paywall_closed", "purchase_completed", "restore_completed", "review_requested", "whats_new_shown",
        "whats_new_closed"
    ]

    public struct KeptProps: Sendable, Equatable {
        public var props: [String: SessionValue]
        /// A text value longer than 48 was dropped (a sign that something someone wrote got in).
        public var propsDropped: Bool
    }

    /// Which of an app event's props are kept (sessions.md 9.4). `nil` in `props` stands for a value
    /// that is not text, a number or yes/no (a list, an object, null): it is dropped without the flag.
    public static func keepProps(source: EventSource, name: String, props: [String: SessionValue?],
                                 keepProps: [String: [String]]) -> KeptProps {
        let chosen: [String: SessionValue?]
        if source == .common || name.hasPrefix("campaign_") || name.hasPrefix("campaigns_") {
            chosen = props
        } else if let names = keepProps[name] {
            chosen = props.filter { names.contains($0.key) }
        } else {
            chosen = [:]
        }
        var kept: [String: SessionValue] = [:]
        var dropped = false
        for (key, value) in chosen {
            guard let value else { continue }
            // NaN and infinity are not JSON numbers: kept, they would make every later save of the state and
            // every send of the batch fail
            if case .double(let number) = value, !number.isFinite { continue }
            if case .string(let text) = value, text.utf16.count > maxPropLength {
                dropped = true
                continue
            }
            kept[key] = value
        }
        return KeptProps(props: kept, propsDropped: dropped)
    }

    // MARK: - Sampling

    public enum Feature: String, Sendable {
        case on, off, paused
    }

    public enum PriorityReason: String, Sendable, CaseIterable, Comparable {
        case rage, dead, hang, ticket
        case campaignQuickEnd = "campaign_quick_end"
        case paywallNoPurchase = "paywall_no_purchase"
        case onboardingUnfinished = "onboarding_unfinished"

        public static func < (lhs: Self, rhs: Self) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    public enum Upload: String, Sendable {
        case none, all, buffered
    }

    /// `sessions_session.replay`: `none` (not captured), `buffer`, `record` or `priority`.
    public enum SessionReplayState: String, Sendable {
        case none, buffer, record, priority
    }

    public struct SamplingInput: Sendable {
        public var project: String
        public var sessionID: String
        public var feature: Feature
        public var replayEnabled: Bool
        public var sample: Double
        public var dailyCap: Int
        public var internalDevice: Bool
        public var recordedToday: Int
        public var events: [SessionEvent]

        public init(project: String, sessionID: String, feature: Feature, replayEnabled: Bool, sample: Double,
                    dailyCap: Int, internalDevice: Bool, recordedToday: Int, events: [SessionEvent]) {
            self.project = project
            self.sessionID = sessionID
            self.feature = feature
            self.replayEnabled = replayEnabled
            self.sample = sample
            self.dailyCap = dailyCap
            self.internalDevice = internalDevice
            self.recordedToday = recordedToday
            self.events = events
        }
    }

    public struct Sampling: Sendable, Equatable {
        public var accept: Bool
        public var answer: SessionReplayMode?
        public var capture: Bool
        public var hash: UInt32?
        public var upload: Upload
        public var uploadFromT: Int?
        public var priority: [PriorityReason]
        public var previousSessionUpload: Bool
        public var sessionReplay: SessionReplayState?
    }

    /// Whether to send the recording (sessions.md 5).
    public static func sampling(_ input: SamplingInput) -> Sampling {
        guard input.feature == .on else {
            return Sampling(accept: false, answer: nil, capture: false, upload: .none, priority: [],
                            previousSessionUpload: false, sessionReplay: nil)
        }
        guard input.replayEnabled else {
            return Sampling(accept: true, answer: .buffer, capture: false, upload: .none, priority: [],
                            previousSessionUpload: false, sessionReplay: SessionReplayState.none)
        }
        let previous = input.events.contains {
            if case .start(_, let end, _, _) = $0 { return [.crashed, .hung, .killed].contains(end) }
            return false
        }
        let hits = priorityHits(input.events)
        let priority = hits.keys.sorted()
        if input.internalDevice {
            return Sampling(accept: true, answer: .record, capture: true, upload: .all, priority: priority,
                            previousSessionUpload: previous, sessionReplay: .record)
        }
        var hash: UInt32?
        if input.recordedToday < input.dailyCap {
            let value = hash32("\(input.project):\(input.sessionID):replay")
            hash = value
            if Double(value) / 4_294_967_296 < input.sample {
                return Sampling(accept: true, answer: .record, capture: true, hash: value, upload: .all,
                                priority: priority, previousSessionUpload: previous, sessionReplay: .record)
            }
        }
        if let hitT = hits.values.min() {
            return Sampling(accept: true, answer: .buffer, capture: true, hash: hash, upload: .buffered,
                            uploadFromT: max(0, hitT - 60_000), priority: priority,
                            previousSessionUpload: previous, sessionReplay: .priority)
        }
        return Sampling(accept: true, answer: .buffer, capture: true, hash: hash, upload: .none, priority: [],
                        previousSessionUpload: previous, sessionReplay: .buffer)
    }

    /// The priority conditions met by the events, each with the time it was first met.
    public static func priorityHits(_ events: [SessionEvent]) -> [PriorityReason: Int] {
        var hits: [PriorityReason: Int] = [:]
        func hit(_ reason: PriorityReason, _ t: Int) { if hits[reason] == nil { hits[reason] = t } }
        var deadCount = 0
        var first = false
        var onboardingCompleted = false
        var campaignShownAt: Int?
        var paywallOpen = false
        for event in events {
            switch event {
            case .start(_, _, _, let isFirst):
                first = isFirst
            case .rage(let t, _, _, _, _):
                hit(.rage, t)
            case .dead(let t, _, _, _):
                deadCount += 1
                if deadCount == 3 { hit(.dead, t) }
            case .hang(let t, _):
                hit(.hang, t)
            case .mark(let t, let kind, let ref, _):
                switch kind {
                case .ticket: hit(.ticket, t)
                case .campaignShown: campaignShownAt = t
                case .paywallShown: paywallOpen = true
                case .purchaseCompleted: paywallOpen = false
                case .onboardingStep where ref == "completed": onboardingCompleted = true
                default: break
                }
            case .event(let t, let name, _, _):
                if name == "paywall_closed", paywallOpen {
                    hit(.paywallNoPurchase, t)
                    paywallOpen = false
                }
            case .end(let t, _):
                if let shown = campaignShownAt, t - shown <= 60_000 { hit(.campaignQuickEnd, t) }
                if paywallOpen { hit(.paywallNoPurchase, t) }
                if first, !onboardingCompleted { hit(.onboardingUnfinished, t) }
            default:
                break
            }
        }
        return hits
    }

    // MARK: - Hash

    /// FNV-1a over UTF-16 code units with murmur3's final mix (the same `hash32` as the server's).
    public static func hash32(_ input: String) -> UInt32 {
        var hash: UInt32 = 0x811c9dc5
        for unit in input.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x01000193
        }
        hash ^= hash >> 16
        hash = hash &* 0x85ebca6b
        hash ^= hash >> 13
        hash = hash &* 0xc2b2ae35
        hash ^= hash >> 16
        return hash
    }
}

/// Rage taps one tap at a time. A cluster starts at a tap; a later tap within 1000 ms and 30 pt of
/// the cluster's first tap joins it, any other tap closes it and starts the next. A closed cluster
/// of 3 or more taps is one rage at its third tap, positioned at its first tap.
public struct RageDetector: Sendable {
    public var window: SessionSize
    private var cluster: [SessionRules.Tap] = []

    public init(window: SessionSize) { self.window = window }

    /// Adds a tap. Returns the rage of the cluster it closed, if any.
    public mutating func add(_ tap: SessionRules.Tap) -> SessionRules.Rage? {
        if let origin = cluster.first, tap.t - origin.t <= SessionRules.rageWindowMs,
           hypot(tap.x - origin.x, tap.y - origin.y) <= SessionRules.rageRadius {
            cluster.append(tap)
            return nil
        }
        let closed = finish()
        cluster = [tap]
        return closed
    }

    /// Closes the cluster when no later tap can join it any more (`now` past its first tap + 1000 ms).
    public mutating func expire(now: Int) -> SessionRules.Rage? {
        guard let origin = cluster.first, now - origin.t > SessionRules.rageWindowMs else { return nil }
        return finish()
    }

    /// Closes the cluster now (leaving the screen, going to the background).
    public mutating func finish() -> SessionRules.Rage? {
        defer { cluster = [] }
        guard cluster.count >= SessionRules.rageMinTaps, let origin = cluster.first else { return nil }
        return SessionRules.Rage(t: cluster[2].t,
                                 x: SessionRules.fraction(origin.x, of: window.w),
                                 y: SessionRules.fraction(origin.y, of: window.h),
                                 count: cluster.count)
    }
}

/// Moves between screens one at a time: the screen shown, and for `pop` and `dismiss` the `back`,
/// the `quick_back` when it came within 2000 ms of entering, and the screen it went back to.
public struct Navigator: Sendable {
    public private(set) var current: String?
    public private(set) var enteredAt: Int?

    public init() {}

    public mutating func move(_ step: SessionRules.NavigationStep) -> [SessionRules.NavigationEvent] {
        var events: [SessionRules.NavigationEvent] = []
        let via: SessionScreenVia
        switch step.op {
        case .launch: via = .launch
        case .push: via = .push
        case .tab: via = .tab
        case .sheet: via = .sheet
        case .pop, .dismiss:
            via = .pop
            if let current {
                events.append(.back(t: step.t, screen: current, via: step.by ?? .button))
                if let enteredAt, step.t - enteredAt <= SessionRules.quickBackMs {
                    events.append(.quickBack(t: step.t, screen: current, ms: step.t - enteredAt))
                }
            }
        }
        events.append(.screen(t: step.t, screen: step.screen, via: via))
        current = step.screen
        enteredAt = step.t
        return events
    }

    /// Enters a screen without a known move (a new session on the same screen).
    public mutating func enter(_ screen: String, at t: Int) {
        current = screen
        enteredAt = t
    }
}
