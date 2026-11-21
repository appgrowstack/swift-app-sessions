import Foundation
import Testing
@testable import SessionsCore
import SessionsTesting

@MainActor
struct AppSessionsTests {
    let clock = FakeSessionClock()
    let store = InMemorySessionStateStore()
    let sink = RecordingSessionSink()
    let ids = SequenceSessionIDs()

    func make(platform: SessionPlatform = .ios, configuration: AppSessions.Configuration = .init(keepProps: ["memo_created": ["view"]]),
              ids: SequenceSessionIDs? = nil) -> AppSessions {
        AppSessions(sink: sink, deviceInfo: { .test(platform: platform) }, store: store, clock: clock, ids: ids ?? self.ids,
                    configuration: configuration)
    }

    func launch(platform: SessionPlatform = .ios, exit: SessionExitInfo = .none) async -> AppSessions {
        let sessions = make(platform: platform)
        sessions.start(exit: exit)
        await sessions.waitForSending()
        return sessions
    }

    func kinds(_ session: String? = nil) async -> [String] {
        await sink.events.filter { session == nil || $0.session == session }.map(\.event.kind)
    }

    // MARK: - Sessions

    @Test func firstLaunchStartsTheFirstSession() async throws {
        let sessions = make()
        sessions.start()
        await sessions.flush()
        let batches = await sink.batches
        let batch = try #require(batches.first)
        #expect(batch.seq == 0)
        #expect(batch.session.sessionID == "ses_test0000000000000001")
        #expect(batch.session.installID == "install-0001")
        #expect(batch.session.startedAt == clock.nowMs())
        #expect(batch.events == [.start(t: 0, previousEnd: .unknown, previousSessionID: nil, first: true)])
        #expect(store.stored?.running == true)
    }

    @Test func shortBackgroundKeepsTheSession() async {
        let sessions = make()
        sessions.start()
        sessions.screen("bookshelf")
        clock.advance(ms: 60_000)
        sessions.enterBackground()
        clock.advance(ms: 1_799_999)
        sessions.enterForeground()
        await sessions.flush()
        #expect(await kinds() == ["start", "screen", "background", "foreground"])
        #expect(sessions.currentSessionID == "ses_test0000000000000001")
    }

    @Test func thirtyMinutesInTheBackgroundStartsANewSessionOnTheSameScreen() async throws {
        let sessions = make()
        sessions.start()
        sessions.screen("bookshelf")
        clock.advance(ms: 60_000)
        sessions.enterBackground()
        clock.advance(ms: 1_800_000)
        sessions.enterForeground()
        await sessions.flush()
        let events = await sink.events
        let first = events.filter { $0.session == "ses_test0000000000000001" }.map(\.event)
        #expect(first.last == .end(t: 60_000, reason: .backgroundTimeout))
        let second = events.filter { $0.session == "ses_test0000000000000002" }.map(\.event)
        #expect(second.first == .start(t: 0, previousEnd: .backgroundTimeout, previousSessionID: "ses_test0000000000000001", first: false))
        #expect(second.dropFirst().first == .screen(t: 0, screen: "bookshelf", via: .unknown, w: 393, h: 852, orientation: .portrait))
    }

    @Test func relaunchAfterBackgroundEndsAsBackgroundTimeout() async {
        let first = await launch()
        first.screen("bookshelf")
        clock.advance(ms: 5000)
        first.enterBackground()
        await first.waitForSending()

        clock.advance(ms: 3_600_000)
        let second = make()
        second.start()
        await second.waitForSending()
        let events = await sink.events.map(\.event)
        #expect(events.contains(.end(t: 5000, reason: .backgroundTimeout)))
        #expect(events.last == .start(t: 0, previousEnd: .backgroundTimeout, previousSessionID: "ses_test0000000000000001", first: false))
    }

    @Test func relaunchWhileRunningEndsAsKilledWithWhatWasLeft() async throws {
        let first = await launch()
        await sink.setFailing(true)
        first.screen("bookshelf")
        clock.advance(ms: 2000)
        first.tap(x: 100, y: 100)
        first.tick()

        await sink.setFailing(false)
        _ = await launch()
        let batches = await sink.batches.filter { $0.session.sessionID == "ses_test0000000000000001" }
        #expect(batches.map(\.seq) == [0, 1])
        #expect(batches[1].events.map(\.kind) == ["screen", "tap", "end"])
        #expect(batches[1].events.last == .end(t: 2000, reason: .killed))
    }

    @Test func hangMarkerLeftByAKilledHangEndsAsHung() async {
        _ = await launch()
        store.setHangMarker(true)
        _ = await launch()
        #expect(await sink.events.map(\.event).contains(.end(t: 0, reason: .hung)))
        #expect(store.hangMarker() == false)
    }

    @Test func crashFromMetricKitAtLaunchEndsAsCrashed() async {
        _ = await launch()
        _ = await launch(exit: SessionExitInfo(metricKitCrash: true))
        #expect(await sink.events.map(\.event).contains(.end(t: 0, reason: .crashed)))
    }

    @Test func lateMetricKitCrashSendsTheEndAgain() async throws {
        _ = await launch()
        let second = await launch()
        second.previousSessionCrashReported()
        await second.waitForSending()
        let previous = await sink.batches.filter { $0.session.sessionID == "ses_test0000000000000001" }
        #expect(previous.flatMap(\.events).filter { $0.kind == "end" } == [.end(t: 0, reason: .killed), .end(t: 0, reason: .crashed)])
        #expect(previous.map(\.seq) == [0, 1, 2])
        second.previousSessionCrashReported()
        await second.waitForSending()
        #expect(await sink.batches.filter { $0.session.sessionID == "ses_test0000000000000001" }.count == 3)
    }

    @Test func androidUserClosedFromExitInfo() async {
        _ = await launch(platform: .android)
        _ = await launch(platform: .android, exit: SessionExitInfo(exitReason: "REASON_USER_REQUESTED"))
        #expect(await sink.events.map(\.event).contains(.end(t: 0, reason: .userClosed)))
    }

    // MARK: - Screens and taps

    @Test func screensInferPushPopAndQuickBack() async {
        let sessions = make()
        sessions.start()
        sessions.observe("screen_viewed", ["screen": .string("bookshelf")])
        clock.advance(ms: 5000)
        sessions.observe("screen_viewed", ["screen": .string("book_detail")])
        clock.advance(ms: 1500)
        sessions.noteBack(via: .gesture)
        sessions.observe("screen_viewed", ["screen": .string("bookshelf")])
        await sessions.flush()
        let screens = await sink.events.map(\.event).filter { ["screen", "back", "quick_back"].contains($0.kind) }
        #expect(screens == [
            .screen(t: 0, screen: "bookshelf", via: .launch, w: 393, h: 852, orientation: .portrait),
            .screen(t: 5000, screen: "book_detail", via: .push, w: 393, h: 852, orientation: .portrait),
            .back(t: 6500, screen: "book_detail", via: .gesture),
            .quickBack(t: 6500, screen: "book_detail", ms: 1500),
            .screen(t: 6500, screen: "bookshelf", via: .pop, w: 393, h: 852, orientation: .portrait)
        ])
    }

    @Test func tabAndSheetAreNotInferred() async {
        let sessions = make()
        sessions.start()
        sessions.screen("bookshelf")
        sessions.screen("settings", op: .tab)
        sessions.screen("bookshelf", op: .tab)
        await sessions.flush()
        #expect(await kinds() == ["start", "screen", "screen", "screen"])
    }

    @Test func tapsAreNormalizedAndRageIsFound() async {
        let sessions = make()
        sessions.start()
        sessions.screen("book_detail")
        for _ in 0..<4 {
            clock.advance(ms: 200)
            sessions.tap(x: 300, y: 700, target: "save_button")
        }
        clock.advance(ms: 1500)
        sessions.tick()
        await sessions.flush()
        let events = await sink.events.map(\.event)
        #expect(events.contains(.tap(t: 200, x: 7634, y: 8216, screen: "book_detail", target: "save_button")))
        #expect(events.filter { $0.kind == "rage" } == [.rage(t: 600, x: 7634, y: 8216, count: 4, screen: "book_detail")])
        #expect(!events.contains { $0.kind == "dead" })
    }

    @Test func tapsInASplitWindowAreMeasuredAgainstTheWindow() async {
        let sessions = make()
        sessions.start()
        sessions.screen("bookshelf")
        sessions.tap(x: 1027, y: 512, window: SessionRect(x: 688, y: 0, w: 678, h: 1024))
        await sessions.flush()
        #expect(await sink.events.map(\.event).contains(.tap(t: 0, x: 5000, y: 5000, screen: "bookshelf", target: nil)))
    }

    @Test func scrollDepthIsSentWhenTheScreenIsLeft() async {
        let sessions = make()
        sessions.start()
        sessions.screen("bookshelf")
        sessions.scroll(.init(offsetY: 0, height: 700, contentHeight: 2400))
        sessions.scroll(.init(offsetY: 100, height: 700, contentHeight: 2400))
        sessions.scrollRow(12, list: "books")
        sessions.scrollRow(3, list: "books")
        clock.advance(ms: 4000)
        sessions.screen("book_detail")
        await sessions.flush()
        let scrolls = await sink.events.map(\.event).filter { $0.kind == "scroll" }
        #expect(scrolls == [
            .scroll(t: 4000, screen: "bookshelf", list: nil, maxRatio: 3333, maxRow: nil),
            .scroll(t: 4000, screen: "bookshelf", list: "books", maxRatio: 0, maxRow: 12)
        ])
    }

    @Test func scrollDepthOfTheLastScreenIsSentAtTheNextLaunch() async {
        let first = await launch()
        first.screen("bookshelf")
        first.scroll(.init(offsetY: 0, height: 700, contentHeight: 600))
        first.enterBackground()
        await first.waitForSending()
        _ = await launch()
        #expect(await sink.events.map(\.event).contains(.scroll(t: 0, screen: "bookshelf", list: nil, maxRatio: 10000, maxRow: nil)))
    }

    // MARK: - Events and marks

    @Test func appEventsKeepOnlyListedPropsAndMakeMarks() async {
        let sessions = make()
        sessions.start()
        sessions.observe("memo_created", ["view": .string("list"), "length": .int(120)])
        sessions.observe("book_added", ["isbn": .string("9784101010014")])
        sessions.observe("paywall_shown", ["source": .string("ai_summary"), "pw_id": .string("ab12cd34")])
        sessions.observe("campaign_shown", ["campaign": .string("trial-2nd"), "side": .string("treatment")])
        sessions.observe("onboarding_completed")
        sessions.mark(.ticket, ref: "tkt_01HZX3K9Q2")
        sessions.observe("screen_viewed", ["screen": .string("book_note"), "title": .string(String(repeating: "あ", count: 49))])
        await sessions.flush()
        let events = await sink.events.map(\.event).filter { $0.kind == "event" || $0.kind == "mark" }
        #expect(events == [
            .event(t: 0, name: "memo_created", props: ["view": .string("list")], propsDropped: false),
            .event(t: 0, name: "book_added", props: [:], propsDropped: false),
            .event(t: 0, name: "paywall_shown", props: ["source": .string("ai_summary"), "pw_id": .string("ab12cd34")], propsDropped: false),
            .mark(t: 0, kind: .paywallShown, ref: "ai_summary", side: nil),
            .event(t: 0, name: "campaign_shown", props: ["campaign": .string("trial-2nd"), "side": .string("treatment")], propsDropped: false),
            .mark(t: 0, kind: .campaignShown, ref: "trial-2nd", side: "treatment"),
            .event(t: 0, name: "onboarding_completed", props: [:], propsDropped: false),
            .mark(t: 0, kind: .onboardingStep, ref: "completed", side: nil),
            .mark(t: 0, kind: .ticket, ref: "tkt_01HZX3K9Q2", side: nil),
            .event(t: 0, name: "screen_viewed", props: ["screen": .string("book_note")], propsDropped: true)
        ])
    }

    @Test func keepPropsFromTheSinkReplaceTheConfigured() async {
        let sessions = make()
        await sink.enqueue(.accepted(replay: .record, keepProps: ["book_added": ["via"]]))
        sessions.start()
        await sessions.flush()
        #expect(sessions.replayMode == .record)
        sessions.observe("book_added", ["via": .string("search"), "isbn": .string("1")])
        await sessions.flush()
        #expect(await sink.events.map(\.event).last == .event(t: 0, name: "book_added", props: ["via": .string("search")], propsDropped: false))
    }

    @Test func hangIsRecordedAndClearsTheMarker() async {
        let sessions = make()
        sessions.start()
        clock.advance(ms: 10_000)
        store.setHangMarker(true)
        sessions.hang(startedAtMs: clock.nowMs() - 3000, ms: 2600)
        await sessions.flush()
        #expect(await sink.events.map(\.event).contains(.hang(t: 7000, ms: 2600)))
        #expect(!store.hangMarker())
        #expect(store.stored?.open?.lastKind == "hang")
    }

    // MARK: - Sending

    @Test func batchesKeepTheirSeqWhenSentAgain() async {
        let sessions = make()
        await sink.setFailing(true)
        sessions.start()
        await sessions.flush()
        sessions.screen("bookshelf")
        await sessions.flush()
        #expect(sessions.waitingBatches == 2)
        await sink.setFailing(false)
        await sessions.flush()
        #expect(await sink.batches.map(\.seq) == [0, 1])
        #expect(sessions.waitingBatches == 0)
    }

    @Test func aBatchHoldsAtMost500Events() async {
        let sessions = make()
        sessions.start()
        for index in 0..<600 { sessions.observe("book_added", ["n": .int(index)]) }
        await sessions.flush()
        #expect(await sink.batches.map(\.events.count) == [500, 101])
    }

    @Test func disabledDropsTheSession() async {
        let sessions = make()
        await sink.enqueue(.disabled)
        sessions.start()
        await sessions.flush()
        sessions.screen("bookshelf")
        await sessions.flush()
        #expect(await sink.batches.count == 1)
        #expect(sessions.waitingBatches == 0)
    }

    @Test func tickSendsOnlyWhenDue() async {
        let sessions = make()
        sessions.start()
        await sessions.flush()
        sessions.screen("bookshelf")
        clock.advance(ms: 10_000)
        sessions.tick()
        await sessions.waitForSending()
        #expect(await sink.batches.count == 1)
        clock.advance(ms: 20_000)
        sessions.tick()
        await sessions.waitForSending()
        #expect(await sink.batches.count == 2)
    }

    @Test func batchJSONMatchesTheSchemaNames() throws {
        let device = SessionDevice(sessionID: "ses_test0000000000000001", startedAt: 1, info: .test(uid: "u1"), installID: "install-0001")
        let batch = SessionBatch(session: device, seq: 0, events: [
            .start(t: 0, previousEnd: .unknown, previousSessionID: nil, first: true),
            .quickBack(t: 5, screen: "a", ms: 5),
            .event(t: 6, name: "x", props: [:], propsDropped: false)
        ])
        let json = try JSONSerialization.jsonObject(with: batch.jsonData()) as! [String: Any]
        let session = json["session"] as! [String: Any]
        #expect(Set(session.keys) == ["session_id", "started_at", "install_id", "uid", "platform", "app_version", "build",
                                      "channel", "lang", "region", "time_zone", "os_version", "device_model", "screen", "sdk_version"])
        let events = json["events"] as! [[String: Any]]
        #expect(Set(events[0].keys) == ["k", "t", "previous_end", "first"])
        #expect(events[1]["k"] as? String == "quick_back")
        #expect(Set(events[2].keys) == ["k", "t", "name"])
        #expect(try JSONDecoder().decode(SessionBatch.self, from: batch.jsonData()) == batch)
    }

    // MARK: - Sinks

    @Test func fileSinkKeepsBatchesAndRemovesTheOldest() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sessions-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = FileSessionSink(directory: directory, maxBytes: 1500)
        func batch(_ id: Int, _ startedAt: Int) -> SessionBatch {
            SessionBatch(session: SessionDevice(sessionID: String(format: "ses_test%016d", id), startedAt: startedAt,
                                                info: .test(), installID: "install-0001"),
                         seq: 0, events: [.start(t: 0, previousEnd: .unknown, previousSessionID: nil, first: true)])
        }
        for id in 1...4 { _ = try await sink.send(batch(id, 1000 + id)) }
        let kept = await sink.batches()
        #expect(kept.count < 4)
        #expect(kept.last == batch(4, 1004))
        await sink.removeAll()
        #expect(await sink.files().isEmpty)
    }

    @Test func debugSinkKeepsTheLastBatches() async throws {
        let sink = DebugSessionSink(limit: 2, log: nil)
        let device = SessionDevice(sessionID: "ses_test0000000000000001", startedAt: 1, info: .test(), installID: "i-00000001")
        for seq in 0..<3 { _ = try await sink.send(SessionBatch(session: device, seq: seq, events: [])) }
        #expect(sink.batches.map(\.seq) == [1, 2])
    }

    @Test func fileStateStoreRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sessions-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSessionStateStore(directory: directory)
        #expect(store.load() == nil)
        let state = SessionStoredState(installID: "install-0001", hadSession: true, running: true)
        store.save(state)
        #expect(store.load() == state)
        store.setHangMarker(true)
        #expect(store.hangMarker())
        store.setHangMarker(false)
        #expect(!store.hangMarker())
    }

    @Test func sessionIDsHaveTheSchemaShape() {
        let id = RandomSessionIDs().makeSessionID()
        #expect(id.range(of: "^ses_[A-Za-z0-9]{20}$", options: .regularExpression) != nil)
        #expect(RandomSessionIDs().makeInstallID().range(of: "^[a-z0-9-]{8,64}$", options: .regularExpression) != nil)
    }
}
