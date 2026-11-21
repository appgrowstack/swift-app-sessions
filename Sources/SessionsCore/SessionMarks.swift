import Foundation

/// Which app events become marks (`mark`), the index the receiver finds sessions by. A mark is
/// made from the event's own values before the kept props are chosen.
public struct SessionMarkRules: Sendable {
    public struct Rule: Sendable {
        public var kind: SessionMarkKind
        /// The property that holds `ref`. Without it, or when the event lacks it, `ref` is `fixedRef`
        /// or the event's name.
        public var refProp: String?
        public var fixedRef: String?
        /// The property that holds the side (`campaign_*` only).
        public var sideProp: String?

        public init(kind: SessionMarkKind, refProp: String? = nil, fixedRef: String? = nil, sideProp: String? = nil) {
            self.kind = kind
            self.refProp = refProp
            self.fixedRef = fixedRef
            self.sideProp = sideProp
        }
    }

    public var rules: [String: Rule]

    public init(rules: [String: Rule]) { self.rules = rules }

    /// The events of swift-analytics' shared catalog and of swift-app-campaign. A ticket has no
    /// event in either: the app calls ``AppSessions/mark(_:ref:side:)`` when one is sent.
    public static let standard = SessionMarkRules(rules: [
        "campaign_shown": Rule(kind: .campaignShown, refProp: "campaign", sideProp: "side"),
        "campaign_eligible": Rule(kind: .campaignEligible, refProp: "campaign", sideProp: "side"),
        "paywall_shown": Rule(kind: .paywallShown, refProp: "source"),
        "purchase_completed": Rule(kind: .purchaseCompleted, refProp: "product"),
        "onboarding_step": Rule(kind: .onboardingStep, refProp: "step"),
        "onboarding_completed": Rule(kind: .onboardingStep, fixedRef: "completed"),
        "notify_opened": Rule(kind: .notifyOpened, refProp: "notification")
    ])

    /// The mark for an event, if it makes one.
    public func mark(for name: String, props: [String: SessionValue?], at t: Int) -> SessionEvent? {
        guard let rule = rules[name] else { return nil }
        let fromProp = rule.refProp.flatMap { props[$0] ?? nil }.map(Self.text)
        let ref = String((fromProp ?? rule.fixedRef ?? name).prefix(80))
        let side = rule.sideProp.flatMap { props[$0] ?? nil }?.string.flatMap { ["treatment", "holdout"].contains($0) ? $0 : nil }
        return .mark(t: t, kind: rule.kind, ref: ref.isEmpty ? name : ref, side: side)
    }

    static func text(_ value: SessionValue) -> String {
        switch value {
        case .string(let text): text
        case .int(let number): String(number)
        case .double(let number): String(number)
        case .bool(let flag): String(flag)
        }
    }
}
