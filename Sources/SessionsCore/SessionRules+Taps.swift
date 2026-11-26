import Foundation

// SessionRules: Where a tap landed, rage taps and dead taps.
extension SessionRules {
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

    /// Taps in window points → rage taps. See ``RageDetector``.
    public static func rage(_ taps: [Tap], window: SessionSize) -> [Rage] {
        var detector = RageDetector(window: window)
        var found = taps.compactMap { detector.add($0) }
        if let last = detector.finish() { found.append(last) }
        return found
    }

    /// A mark under the screen as the tap's name sees it: a named target (`.sessionTarget`) or the
    /// root of a layer drawn over the screen (`.sessionLayer`). `layers` is the path of layers the
    /// mark is in, outermost first; a layer's own mark ends with itself.
    public struct TapMark: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case target(String)
            case layer
        }

        public var kind: Kind
        public var frame: SessionRect
        public var layers: [String]

        public init(kind: Kind, frame: SessionRect, layers: [String] = []) {
            self.kind = kind
            self.frame = frame
            self.layers = layers
        }

        func contains(x: Double, y: Double) -> Bool {
            x >= frame.x && x < frame.x + frame.w && y >= frame.y && y < frame.y + frame.h
        }
    }

    /// The name of a tap at (`x`, `y`) from the marks under the screen, back to front (the order they
    /// are drawn in). The front layer is the deepest layer whose mark holds the point (the later one
    /// when two are as deep); only the targets of that layer count, or the targets outside every
    /// layer when no layer holds it. Of those, the smallest target holding the point names the tap
    /// (the later one when two are as small). A tap on a layer where none of its targets is under
    /// the finger has no name: a row under a dialog does not name a tap on the dialog.
    public static func tapTarget(x: Double, y: Double, marks: [TapMark]) -> String? {
        let under = marks.filter { $0.contains(x: x, y: y) }
        var front: [String] = []
        for mark in under where mark.kind == .layer && mark.layers.count >= front.count {
            front = mark.layers
        }
        var best: (name: String, area: Double)?
        for mark in under where mark.layers == front {
            guard case .target(let name) = mark.kind else { continue }
            let area = mark.frame.w * mark.frame.h
            if area <= (best?.area ?? .greatestFiniteMagnitude) { best = (name, area) }
        }
        return best?.name
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
