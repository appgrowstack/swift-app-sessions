import Foundation

/// Watches the main thread from a thread of its own: every `intervalMs` it sends the main queue a
/// small task, and when the task does not run for `thresholdMs` the main thread is hung. While it
/// is hung the store's hang marker is set, so a session killed in the hang still ends as `hung`;
/// when the main thread answers again, `report` gets when it stopped and for how long.
public final class HangMonitor: @unchecked Sendable {
    public let thresholdMs: Int
    public let intervalMs: Int
    private let clock: any SessionClock
    private let store: any SessionStateStore
    private let report: @MainActor @Sendable (_ startedAtMs: Int, _ ms: Int) -> Void
    private let lock = NSLock()
    private var running = false
    private var answeredAt: Int?

    public init(thresholdMs: Int = 2000, intervalMs: Int = 500, clock: any SessionClock = SystemSessionClock(),
                store: any SessionStateStore, report: @escaping @MainActor @Sendable (_ startedAtMs: Int, _ ms: Int) -> Void) {
        self.thresholdMs = thresholdMs
        self.intervalMs = intervalMs
        self.clock = clock
        self.store = store
        self.report = report
    }

    /// Watches `sessions` and reports to it.
    @MainActor
    public convenience init(sessions: AppSessions, store: any SessionStateStore, thresholdMs: Int = 2000) {
        self.init(thresholdMs: thresholdMs, store: store) { [weak sessions] startedAt, ms in
            sessions?.hang(startedAtMs: startedAt, ms: ms)
        }
    }

    public func start() {
        let begin = lock.withLock { () -> Bool in
            guard !running else { return false }
            running = true
            return true
        }
        guard begin else { return }
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "app-sessions.hang-monitor"
        thread.qualityOfService = .utility
        thread.start()
    }

    public func stop() { lock.withLock { running = false } }

    private var isRunning: Bool { lock.withLock { running } }

    private func loop() {
        while isRunning {
            let sentAt = clock.nowMs()
            lock.withLock { answeredAt = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let now = self.clock.nowMs()
                self.lock.withLock { self.answeredAt = now }
            }
            Thread.sleep(forTimeInterval: Double(intervalMs) / 1000)
            var marked = false
            while isRunning {
                if let answered = lock.withLock({ answeredAt }) {
                    let ms = answered - sentAt
                    if marked || ms >= thresholdMs {
                        let report = self.report
                        DispatchQueue.main.async { MainActor.assumeIsolated { report(sentAt, ms) } }
                    }
                    break
                }
                if !marked, clock.nowMs() - sentAt >= thresholdMs {
                    store.setHangMarker(true)
                    marked = true
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }
}
