import Foundation

// SessionRules: How deep a list was scrolled.
extension SessionRules {
    public static func scrollDepth(_ samples: [ScrollSample]) -> ScrollDepth {
        ScrollDepth(maxRatio: samples.map(\.ratio).max() ?? 0, maxRow: samples.compactMap(\.row).max())
    }
}
