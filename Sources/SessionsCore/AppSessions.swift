import Foundation

/// The light record of an app's sessions. Feed it the app's lifecycle, screens, taps, scrolls and
/// analytics events (`SessionsCapture` does most of it on iOS); it splits sessions, applies the
/// rules, keeps what it has between launches and hands batches to the sink.
///
/// ```swift
/// let sessions = AppSessions(sink: FileSessionSink(), channel: .appstore)   // SessionsCapture
/// sessions.start()                                                          // once, at launch
/// analytics.observe { name, props in sessions.observe(name, props) }        // the app's analytics bridge
/// ```
@MainActor
public final class AppSessions {
    public struct Configuration: Sendable {
        /// The app events whose props are kept, and which (the manifest's `events.keep_props`).
        public var keepProps: [String: [String]]
        public var marks: SessionMarkRules
        /// While in the front, a batch goes out at most this often (when there is something new).
        public var flushIntervalMs: Int
        /// Events kept for one session before the oldest are dropped (the sink is unreachable).
        public var maxPendingEvents: Int
        /// Batches kept for the sink before the oldest are dropped.
        public var maxOutboxBatches: Int
        public var maxEventsPerBatch: Int
        /// A back gesture or key reported this long before the screen change is its `via`.
        public var backHintMs: Int

        public init(keepProps: [String: [String]] = [:], marks: SessionMarkRules = .standard,
                    flushIntervalMs: Int = 30_000, maxPendingEvents: Int = 5000, maxOutboxBatches: Int = 200,
                    maxEventsPerBatch: Int = 500, backHintMs: Int = 1000) {
            self.keepProps = keepProps
            self.marks = marks
            self.flushIntervalMs = flushIntervalMs
            self.maxPendingEvents = maxPendingEvents
            self.maxOutboxBatches = maxOutboxBatches
            self.maxEventsPerBatch = maxEventsPerBatch
            self.backHintMs = backHintMs
        }
    }

    public let sink: any SessionSink
    public private(set) var configuration: Configuration
    private let deviceInfo: @MainActor () -> SessionDeviceInfo
    private let store: any SessionStateStore
    private let clock: any SessionClock
    private let ids: any SessionIDGenerating

    private var state = SessionStoredState()
    private var started = false
    private var backgroundAt: Int?
    private var lastFlushAt = 0
    private var flushing = false
    private var flushTask: Task<Void, Never>?
    private var dirty = false
    private var disabled = false
    private var window: SessionRect
    private var navigator = Navigator()
    private var stack: [String] = []
    private var rage: RageDetector
    private var backHint: (via: SessionBackVia, at: Int)?
    private var scrolls: [String: SessionRules.ScrollDepth] = [:]

    /// The recording's decision from the sink for this session. Without one, `buffer`.
    public private(set) var replayMode: SessionReplayMode = .buffer

    public init(sink: any SessionSink,
                deviceInfo: @escaping @MainActor () -> SessionDeviceInfo,
                store: any SessionStateStore = FileSessionStateStore.standard(),
                clock: any SessionClock = SystemSessionClock(),
                ids: any SessionIDGenerating = RandomSessionIDs(),
                configuration: Configuration = .init()) {
        self.sink = sink
        self.deviceInfo = deviceInfo
        self.store = store
        self.clock = clock
        self.ids = ids
        self.configuration = configuration
        let screen = deviceInfo().screen
        self.window = SessionRect(x: 0, y: 0, w: screen.w, h: screen.h)
        self.rage = RageDetector(window: SessionSize(w: screen.w, h: screen.h))
    }

    /// The recorder that was started last. The SwiftUI marks report to it.
    public private(set) static weak var current: AppSessions?

    // MARK: - What the app reads

    public var currentSessionID: String? { state.open?.device.sessionID }
    /// When the current session started (milliseconds since 1970).
    public var currentSessionStartedAt: Int? { state.open?.device.startedAt }
    /// The session that ended last, for matching a late crash report to it.
    public var previousSessionStartedAt: Int? { state.lastClosed?.device.startedAt }
    public var currentScreen: String? { navigator.current }
    /// The light record never captures frames (the recording does), so it never reports dead taps.
    public var isCapturing: Bool { false }
    /// Batches waiting for the sink.
    public var waitingBatches: Int { state.outbox.count + (state.open?.pending.isEmpty == false ? 1 : 0) }

    // MARK: - Lifecycle

    /// Once, at launch: ends the previous session with what is known about it and starts a new one.
    public func start(exit: SessionExitInfo = .none) {
        guard !started else { return }
        started = true
        AppSessions.current = self
        state = store.load() ?? SessionStoredState()
        let hung = store.hangMarker()
        store.setHangMarker(false)
        var previousEnd = SessionEndReason.unknown
        var previousID: String?
        if let open = state.open {
            let lastKind = hung ? "hang" : open.lastKind
            let decision = SessionRules.endReason(.init(
                platform: open.device.platform, androidAPI: exit.androidAPI, previousRecord: true,
                runningFlag: state.running, lastEvent: lastKind, metricKitCrash: exit.metricKitCrash,
                exitReason: exit.exitReason, crashHandler: state.crashRecorded))
            close(open, endAt: open.lastT, reason: decision.reason, lastKind: lastKind, runningFlag: state.running,
                  scrolls: open.scrolls)
            previousEnd = decision.reason
            previousID = open.device.sessionID
        } else if let closed = state.lastClosed {
            previousEnd = closed.reason
            previousID = closed.device.sessionID
        }
        state.crashRecorded = false
        begin(previousEnd: previousEnd, previousID: previousID, firstVia: .launch)
        scheduleFlush()
    }

    public func enterBackground() {
        guard state.open != nil, backgroundAt == nil else { return }
        closeRage()
        let now = clock.nowMs()
        record(.background(t: t(now)))
        backgroundAt = now
        state.running = false
        save()
        scheduleFlush()
    }

    public func enterForeground() {
        guard let open = state.open, let at = backgroundAt else { return }
        backgroundAt = nil
        let now = clock.nowMs()
        if now - at >= SessionRules.backgroundTimeoutMs {
            let screen = navigator.current
            close(open, endAt: at - open.device.startedAt, reason: .backgroundTimeout, lastKind: "background",
                  runningFlag: false, scrolls: pendingScrolls())
            begin(previousEnd: .backgroundTimeout, previousID: open.device.sessionID, firstVia: .unknown)
            if let screen { enterScreen(screen, via: .unknown) }
        } else {
            record(.foreground(t: t(now)))
            state.running = true
        }
        save()
        scheduleFlush()
    }

    /// Call every few seconds while in the front (`SessionsCapture` does): closes a finished rage
    /// cluster, keeps the state and sends a batch when one is due.
    public func tick() {
        guard state.open != nil, backgroundAt == nil else { return }
        if let found = rage.expire(now: t(clock.nowMs())) { recordRage(found) }
        if dirty { save() }
        if clock.nowMs() - lastFlushAt >= configuration.flushIntervalMs, state.open?.pending.isEmpty == false {
            scheduleFlush()
        }
    }

    // MARK: - Screens

    /// A screen was shown. Without `op`, going to the screen under the current one is `pop`, the
    /// first screen of a session is `launch`, and anything else is `push`.
    public func screen(_ name: String, op: SessionRules.NavigationOp? = nil, by: SessionBackVia? = nil) {
        guard state.open != nil, name != navigator.current else { return }
        let now = clock.nowMs()
        let move: SessionRules.NavigationOp
        if let op {
            move = op
        } else if navigator.current == nil {
            move = .launch
        } else if stack.count >= 2, stack[stack.count - 2] == name {
            move = .pop
        } else {
            move = .push
        }
        leaveScreen(at: now)
        var via = by
        if via == nil, move == .pop || move == .dismiss, let hint = backHint, now - hint.at <= configuration.backHintMs {
            via = hint.via
        }
        backHint = nil
        let events = navigator.move(.init(t: t(now), op: move, screen: name, by: via))
        switch move {
        case .launch, .tab: stack = [name]
        case .push, .sheet: stack.append(name)
        case .pop, .dismiss:
            if !stack.isEmpty { stack.removeLast() }
            if stack.last != name { if stack.isEmpty { stack = [name] } else { stack[stack.count - 1] = name } }
        }
        for event in events {
            switch event {
            case .screen(let t, let screen, let via):
                record(.screen(t: t, screen: screen, via: via, w: window.w, h: window.h, orientation: window.size.orientation))
            case .back(let t, let screen, let via):
                record(.back(t: t, screen: screen, via: via))
            case .quickBack(let t, let screen, let ms):
                record(.quickBack(t: t, screen: screen, ms: ms))
            }
        }
    }

    /// A back gesture (`gesture`) or Android's back key (`system`) is happening; the next screen
    /// change that goes back takes it as its `via`.
    public func noteBack(via: SessionBackVia) {
        backHint = (via, clock.nowMs())
    }

    /// The window the app is shown in, in screen points (taps are measured against it).
    public func updateWindow(_ frame: SessionRect) {
        guard frame.w > 0, frame.h > 0 else { return }
        window = frame
        rage.window = frame.size
    }

    // MARK: - Touches, scrolls, keyboard

    /// A finger left the screen at `x`, `y` (screen points) in `window` (nil: the last one given).
    public func tap(x: Double, y: Double, window frame: SessionRect? = nil, target: String? = nil) {
        guard state.open != nil, backgroundAt == nil else { return }
        if let frame { updateWindow(frame) }
        let now = t(clock.nowMs())
        let position = SessionRules.normalizeTap(x: x, y: y, window: window)
        record(.tap(t: now, x: position.x, y: position.y, screen: screenName, target: target))
        if let found = rage.add(.init(t: now, x: x - window.x, y: y - window.y)) { recordRage(found) }
    }

    /// The shape of a scroll view on the current screen. `list` is a list marked
    /// `.sessionScroll("…")`; nil is the screen's main scroll view.
    public func scroll(_ sample: SessionRules.ScrollSample, list: String? = nil) {
        guard state.open != nil else { return }
        let key = list ?? ""
        let previous = scrolls[key]
        let maxRow = [previous?.maxRow, sample.row].compactMap { $0 }.max()
        let depth = SessionRules.ScrollDepth(maxRatio: max(previous?.maxRatio ?? 0, sample.ratio), maxRow: maxRow)
        if depth != previous {
            scrolls[key] = depth
            dirty = true
        }
    }

    /// A row of a list marked `.sessionScroll("…")` came into view.
    public func scrollRow(_ row: Int, list: String) {
        guard state.open != nil, row >= 0 else { return }
        let previous = scrolls[list]
        let depth = SessionRules.ScrollDepth(maxRatio: previous?.maxRatio ?? 0, maxRow: max(previous?.maxRow ?? row, row))
        if depth != previous {
            scrolls[list] = depth
            dirty = true
        }
    }

    public func keyboard(shown: Bool) {
        guard state.open != nil else { return }
        record(.keyboard(t: t(clock.nowMs()), shown: shown))
    }

    // MARK: - App events and marks

    /// An analytics event. `screen_viewed` also moves to its `screen`. Some events also make a mark
    /// (``Configuration/marks``). `source` defaults to `common` for swift-analytics' shared catalog.
    /// A nil value stands for one that is not text, a number or yes/no; it is not kept.
    public func observe(_ name: String, _ props: [String: SessionValue?] = [:], source: SessionRules.EventSource? = nil) {
        guard state.open != nil else { return }
        if name == "screen_viewed", let screen = (props["screen"] ?? nil)?.string, Self.isScreenName(screen) {
            self.screen(screen)
        }
        let now = t(clock.nowMs())
        let from = source ?? (SessionRules.commonCatalog.contains(name) ? .common : .app)
        let kept = SessionRules.keepProps(source: from, name: name, props: props, keepProps: configuration.keepProps)
        let limited = Dictionary(uniqueKeysWithValues: kept.props.sorted { $0.key < $1.key }.prefix(32).map { ($0.key, $0.value) })
        record(.event(t: now, name: name, props: limited, propsDropped: kept.propsDropped))
        if let mark = configuration.marks.mark(for: name, props: props, at: now) { record(mark) }
    }

    /// A mark the app knows of without an event (a ticket sent from swift-app-support).
    public func mark(_ kind: SessionMarkKind, ref: String, side: String? = nil) {
        guard state.open != nil, !ref.isEmpty else { return }
        record(.mark(t: t(clock.nowMs()), kind: kind, ref: String(ref.prefix(80)), side: side))
    }

    // MARK: - Hangs and crashes

    /// The main thread did not answer from `startedAtMs` for `ms`. Reported by ``HangMonitor``.
    public func hang(startedAtMs: Int, ms: Int) {
        store.setHangMarker(false)
        guard state.open != nil, ms >= 2000 else { return }
        record(.hang(t: t(startedAtMs), ms: ms))
        save()
    }

    /// MetricKit delivered a crash report for the previous session after this launch. Sends that
    /// session's `end` again with the revised reason.
    public func previousSessionCrashReported() {
        guard var closed = state.lastClosed else { return }
        let decision = SessionRules.endReason(.init(
            platform: closed.device.platform, previousRecord: true, runningFlag: closed.runningFlag,
            lastEvent: closed.lastKind, lateMetricKitCrash: true))
        guard let revised = decision.revised, revised != closed.reason else { return }
        appendToOutbox(SessionBatch(session: closed.device, seq: closed.nextSeq, events: [.end(t: closed.endT, reason: revised)]))
        closed.nextSeq += 1
        closed.reason = revised
        state.lastClosed = closed
        save()
        scheduleFlush()
    }

    // MARK: - Sending

    /// Puts what is pending into a batch and hands every waiting batch to the sink, oldest first.
    /// Stops at the first throw and keeps the rest for later.
    public func flush() async {
        await waitForSending()
        while flushing { await Task.yield() }
        await send()
    }

    private func send() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        lastFlushAt = clock.nowMs()
        batchPending()
        save()
        while let batch = state.outbox.first {
            let reply: SessionSinkReply
            do { reply = try await sink.send(batch) } catch { break }
            state.outbox.removeAll { $0.session.sessionID == batch.session.sessionID && $0.seq == batch.seq }
            let current = batch.session.sessionID == currentSessionID
            switch reply {
            case .accepted(let replay, let keepProps):
                if current, let replay { replayMode = replay }
                if let keepProps { configuration.keepProps = keepProps }
            case .disabled:
                state.outbox.removeAll { $0.session.sessionID == batch.session.sessionID }
                if current {
                    disabled = true
                    state.open?.pending = []
                }
            }
            save()
        }
    }

    /// Returns when the sending started by the recorder itself (at launch, going to the back,
    /// a due tick) is done.
    public func waitForSending() async {
        while let task = flushTask { await task.value }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            await self?.send()
            self?.flushTask = nil
        }
    }

    // MARK: - Inside

    private var screenName: String { navigator.current ?? "unknown" }

    private func t(_ now: Int) -> Int {
        guard let start = state.open?.device.startedAt else { return 0 }
        return max(0, now - start)
    }

    private func begin(previousEnd: SessionEndReason, previousID: String?, firstVia: SessionScreenVia) {
        let now = clock.nowMs()
        let info = deviceInfo()
        let installID = (info.installID ?? state.installID ?? ids.makeInstallID()).lowercased()
        state.installID = installID
        let device = SessionDevice(sessionID: ids.makeSessionID(), startedAt: now, info: info, installID: installID)
        let first = !state.hadSession
        state.hadSession = true
        state.running = true
        state.open = OpenSessionRecord(device: device, nextSeq: 0, lastKind: "start", lastT: 0,
                                       pending: [.start(t: 0, previousEnd: previousEnd, previousSessionID: previousID, first: first)])
        disabled = false
        replayMode = .buffer
        navigator = Navigator()
        stack = []
        scrolls = [:]
        backHint = nil
        rage = RageDetector(window: window.size)
        save()
    }

    /// Ends `open`: the scroll depths it still had, `end`, and its batches into the outbox.
    private func close(_ open: OpenSessionRecord, endAt endT: Int, reason: SessionEndReason, lastKind: String?,
                       runningFlag: Bool, scrolls: [OpenSessionRecord.Scroll]) {
        var record = open
        if !disabled {
            record.pending += scrolls.map { .scroll(t: endT, screen: $0.screen, list: $0.list, maxRatio: $0.maxRatio, maxRow: $0.maxRow) }
            record.pending.append(.end(t: endT, reason: reason))
        }
        state.open = record
        batchPending()
        let next = state.open?.nextSeq ?? record.nextSeq
        state.lastClosed = ClosedSessionRecord(device: open.device, nextSeq: next, endT: endT, reason: reason,
                                               lastKind: lastKind, runningFlag: runningFlag)
        state.open = nil
    }

    private func leaveScreen(at now: Int) {
        closeRage()
        guard navigator.current != nil else { return }
        for scroll in pendingScrolls() {
            record(.scroll(t: t(now), screen: scroll.screen, list: scroll.list, maxRatio: scroll.maxRatio, maxRow: scroll.maxRow))
        }
        scrolls = [:]
    }

    private func enterScreen(_ name: String, via: SessionScreenVia) {
        let now = t(clock.nowMs())
        navigator.enter(name, at: now)
        if stack.isEmpty { stack = [name] }
        record(.screen(t: now, screen: name, via: via, w: window.w, h: window.h, orientation: window.size.orientation))
    }

    private func pendingScrolls() -> [OpenSessionRecord.Scroll] {
        guard let screen = navigator.current else { return [] }
        return scrolls.sorted { $0.key < $1.key }.map {
            OpenSessionRecord.Scroll(screen: screen, list: $0.key.isEmpty ? nil : $0.key, maxRatio: $0.value.maxRatio, maxRow: $0.value.maxRow)
        }
    }

    private func closeRage() {
        if let found = rage.finish() { recordRage(found) }
    }

    private func recordRage(_ found: SessionRules.Rage) {
        record(.rage(t: found.t, x: found.x, y: found.y, count: found.count, screen: screenName))
    }

    private func record(_ event: SessionEvent) {
        guard !disabled, var open = state.open else { return }
        open.pending.append(event)
        if open.pending.count > configuration.maxPendingEvents {
            open.pending.removeFirst(open.pending.count - configuration.maxPendingEvents)
        }
        open.lastKind = event.kind
        open.lastT = max(open.lastT, event.t)
        open.scrolls = pendingScrolls()
        state.open = open
        dirty = true
    }

    private func batchPending() {
        guard var open = state.open, !open.pending.isEmpty else { return }
        let size = max(1, configuration.maxEventsPerBatch)
        var index = 0
        while index < open.pending.count {
            let chunk = Array(open.pending[index..<min(index + size, open.pending.count)])
            appendToOutbox(SessionBatch(session: open.device, seq: open.nextSeq, events: chunk))
            open.nextSeq += 1
            index += size
        }
        open.pending = []
        state.open = open
    }

    private func appendToOutbox(_ batch: SessionBatch) {
        state.outbox.append(batch)
        if state.outbox.count > configuration.maxOutboxBatches {
            state.outbox.removeFirst(state.outbox.count - configuration.maxOutboxBatches)
        }
    }

    private func save() {
        if state.open != nil { state.open?.scrolls = pendingScrolls() }
        store.save(state)
        dirty = false
    }

    static func isScreenName(_ name: String) -> Bool {
        name.range(of: "^[a-z][a-z0-9_]{0,47}$", options: .regularExpression) != nil
    }
}
