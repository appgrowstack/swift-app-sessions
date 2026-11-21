import Foundation

/// The rules of the light record as pure functions: no clock, storage or network. The recorder
/// uses the same code, and `schema/cases/sessions` checks every one against Kotlin and TypeScript.
/// This file holds the constants and the types; the functions are in `SessionRules+<context>.swift`
/// (Split, Taps, Navigation, EndReason, Scroll, Props, Sampling), the same split as Kotlin's `SessionRules<context>.kt`.
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
}
