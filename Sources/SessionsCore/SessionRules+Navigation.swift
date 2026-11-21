import Foundation

// SessionRules: Moves between screens and quick backs.
extension SessionRules {
    /// Moves between screens → the `screen`, `back` and `quick_back` events. See ``Navigator``.
    public static func navigate(_ steps: [NavigationStep]) -> [NavigationEvent] {
        var navigator = Navigator()
        return steps.flatMap { navigator.move($0) }
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
