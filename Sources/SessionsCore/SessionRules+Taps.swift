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
