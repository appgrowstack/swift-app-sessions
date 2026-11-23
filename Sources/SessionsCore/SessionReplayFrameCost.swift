import Foundation

/// How long taking a frame holds the main thread, and what the recording does about it
/// (sessions.md 3.2): over ``slowP95Ms`` at the 95th percentile a frame is taken every 2 seconds;
/// over ``stopP95Ms`` the session's recording stops (`degraded`).
///
/// - The first ``warmUpFrames`` frames are not counted: they are taken while the app is still
///   laying out its first screens and say nothing about the frames after them
/// - The percentile is read over the last ``window`` frames, once ``minFrames`` are counted
/// - ``stopP95Ms`` nil never stops (the simulator draws on the CPU; its times are not a device's)
public struct SessionReplayFrameCost: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// One frame a second.
        case normal
        /// One frame every 2 seconds.
        case slow
        /// Stop the session's recording.
        case degraded
    }

    public var slowP95Ms: Double
    public var stopP95Ms: Double?
    public var warmUpFrames: Int
    public var window: Int
    public var minFrames: Int

    private var skipped = 0
    private var durations: [Double] = []
    public private(set) var verdict: Verdict = .normal

    public init(slowP95Ms: Double = 16, stopP95Ms: Double? = 33, warmUpFrames: Int = 3, window: Int = 30, minFrames: Int = 10) {
        self.slowP95Ms = slowP95Ms
        self.stopP95Ms = stopP95Ms
        self.warmUpFrames = warmUpFrames
        self.window = window
        self.minFrames = minFrames
    }

    /// The milliseconds between frames the verdict allows (`live` takes two a second).
    public func intervalMs(live: Bool) -> Int {
        if live { return 500 }
        return verdict == .slow ? 2000 : 1000
    }

    /// Counts one frame's main-thread time. A `degraded` verdict stays until ``reset()``.
    @discardableResult
    public mutating func add(_ ms: Double) -> Verdict {
        guard verdict != .degraded else { return .degraded }
        guard ms.isFinite, ms >= 0 else { return verdict }
        if skipped < warmUpFrames {
            skipped += 1
            return verdict
        }
        durations.append(ms)
        if durations.count > window { durations.removeFirst(durations.count - window) }
        guard durations.count >= minFrames else { return verdict }
        let sorted = durations.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        if let stop = stopP95Ms, p95 > stop {
            verdict = .degraded
        } else {
            verdict = p95 > slowP95Ms ? .slow : .normal
        }
        return verdict
    }

    /// Starts over (a new session).
    public mutating func reset() {
        skipped = 0
        durations = []
        verdict = .normal
    }
}
