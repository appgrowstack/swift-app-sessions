import Foundation

/// How long taking a frame holds the main thread, and what the recording does about it
/// (sessions.md 3.2): over ``slowP95Ms`` at the 95th percentile a frame is taken every 2 seconds,
/// over ``verySlowP95Ms`` every 5 seconds, and over ``stopP95Ms`` the session's recording stops
/// (`degraded`).
///
/// A device that takes 35ms a frame (a large SwiftUI screen drawn at 1pt to 1px) is not stopped:
/// it is spaced out to one frame in 5 seconds, a hitch of two display frames now and then. Stopping
/// at 33ms left every App Store session of the first app with only its first 13 frames.
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
        /// One frame every 5 seconds.
        case verySlow
        /// Stop the session's recording.
        case degraded
    }

    public var slowP95Ms: Double
    public var verySlowP95Ms: Double
    public var stopP95Ms: Double?
    public var warmUpFrames: Int
    public var window: Int
    public var minFrames: Int

    private var skipped = 0
    private var durations: [Double] = []
    public private(set) var verdict: Verdict = .normal

    public init(slowP95Ms: Double = 16, verySlowP95Ms: Double = 33, stopP95Ms: Double? = 100,
                warmUpFrames: Int = 3, window: Int = 30, minFrames: Int = 10) {
        self.slowP95Ms = slowP95Ms
        self.verySlowP95Ms = verySlowP95Ms
        self.stopP95Ms = stopP95Ms
        self.warmUpFrames = warmUpFrames
        self.window = window
        self.minFrames = minFrames
    }

    /// The milliseconds between frames the verdict allows (`live` takes two a second).
    public func intervalMs(live: Bool) -> Int {
        if live { return 500 }
        switch verdict {
        case .normal: return 1000
        case .slow: return 2000
        case .verySlow, .degraded: return 5000
        }
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
        } else if p95 > verySlowP95Ms {
            verdict = .verySlow
        } else {
            verdict = p95 > slowP95Ms ? .slow : .normal
        }
        return verdict
    }

    /// The 50th and 95th percentile of the frames counted so far (nil before the first).
    public var percentiles: (p50: Double, p95: Double)? {
        guard !durations.isEmpty else { return nil }
        let sorted = durations.sorted()
        return (sorted[min(sorted.count - 1, sorted.count / 2)],
                sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
    }

    /// Starts over (a new session).
    public mutating func reset() {
        skipped = 0
        durations = []
        verdict = .normal
    }
}
