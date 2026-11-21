import Foundation

/// A value kept from an app event's properties: text, a number or a yes/no. Nothing else is kept.
public enum SessionValue: Sendable, Hashable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

public enum SessionPlatform: String, Sendable, Codable, CaseIterable {
    case ios
    case android
}

/// How a session ended (sessions.md 3.1).
public enum SessionEndReason: String, Sendable, Codable, CaseIterable {
    /// In the background for 30 minutes. The end is the time it went to the background.
    case backgroundTimeout = "background_timeout"
    /// Android only: the person closed the app from the recent apps.
    case userClosed = "user_closed"
    case crashed
    /// The main thread stopped answering (a hang on iOS, an ANR on Android).
    case hung
    /// Stopped by the system for another reason (memory, the watchdog).
    case killed
    /// Nothing about the previous session was left on the device.
    case unknown
}

/// How a screen was entered. Closing a sheet back to the screen under it is `pop`.
public enum SessionScreenVia: String, Sendable, Codable, CaseIterable {
    case launch, push, pop, tab, sheet, unknown
}

/// How the person went back: an edge swipe, a back or close button, or Android's back key or gesture.
public enum SessionBackVia: String, Sendable, Codable, CaseIterable {
    case gesture, button, system
}

public enum SessionOrientation: String, Sendable, Codable, CaseIterable {
    case portrait, landscape
}

/// The kinds of marks the server indexes sessions by.
public enum SessionMarkKind: String, Sendable, Codable, CaseIterable {
    case campaignShown = "campaign_shown"
    case campaignEligible = "campaign_eligible"
    case paywallShown = "paywall_shown"
    case purchaseCompleted = "purchase_completed"
    case ticket
    case notifyOpened = "notify_opened"
    case onboardingStep = "onboarding_step"
}

/// Where the sink's answer says to take the session's recording. Without an answer, `buffer`.
public enum SessionReplayMode: String, Sendable, Codable {
    /// Send the whole recording.
    case record
    /// Keep the last 60 seconds and send only when a priority condition happens.
    case buffer
}

/// A size in points (dp on Android).
public struct SessionSize: Sendable, Hashable, Codable {
    public var w: Double
    public var h: Double

    public init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }

    public var orientation: SessionOrientation { w > h ? .landscape : .portrait }
}

/// A rectangle in points; `x` and `y` are the top left corner.
public struct SessionRect: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var size: SessionSize { SessionSize(w: w, h: h) }
}
