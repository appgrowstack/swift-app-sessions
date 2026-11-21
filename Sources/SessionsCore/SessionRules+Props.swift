import Foundation

// SessionRules: Which props of an app event are kept.
extension SessionRules {
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
}
