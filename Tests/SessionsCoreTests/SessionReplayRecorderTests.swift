import Foundation
import Testing
@testable import SessionsCore
import SessionsTesting

/// Answers each segment from a queue (with nothing queued, `stored`) and keeps what it was given.
actor RecordingReplaySink: SessionReplaySink {
    private(set) var uploads: [SessionReplayUpload] = []
    private var replies: [Result<SessionReplayUploadReply, Error>] = []

    func enqueue(_ reply: Result<SessionReplayUploadReply, Error>) { replies.append(reply) }

    func upload(_ segment: SessionReplayUpload) async throws -> SessionReplayUploadReply {
        uploads.append(segment)
        return try (replies.isEmpty ? .success(.stored) : replies.removeFirst()).get()
    }
}

struct Unreachable: Error {}

@MainActor
struct SessionReplayRecorderTests {
    let clock = FakeSessionClock()
    let sink = RecordingSessionSink()
    let replaySink = RecordingReplaySink()
    let store = SessionReplayStore(directory: FileManager.default.temporaryDirectory.appending(path: "replay-\(UUID().uuidString)"))

    func launch(answer: SessionSinkReply) async -> (AppSessions, SessionReplayRecorder) {
        await sink.enqueue(answer)
        let sessions = AppSessions(sink: sink, deviceInfo: { .test() }, store: InMemorySessionStateStore(), clock: clock,
                                   ids: SequenceSessionIDs())
        let recorder = SessionReplayRecorder(sessions: sessions, sink: replaySink, store: store, clock: clock)
        sessions.start()
        await sessions.waitForSending()
        return (sessions, recorder)
    }

    func image(_ fingerprint: String) -> SessionReplayRecorder.Frame {
        .image(Data(repeating: 1, count: 100), mime: "image/jpeg", w: 393, h: 852, masked: true, fingerprint: fingerprint)
    }

    /// One frame a second for `seconds`, each a new picture.
    func frames(_ recorder: SessionReplayRecorder, seconds: Int) {
        for i in 0..<seconds {
            clock.advance(ms: 1000)
            recorder.add(image("f\(i)"), atMs: clock.nowMs())
        }
    }

    @Test func recordSendsEverySegmentWithTheToken() async throws {
        let token = "1795900000." + String(repeating: "a", count: 64)
        let (sessions, recorder) = await launch(answer: .accepted(replay: .record, uploadToken: token))
        frames(recorder, seconds: 62)
        await recorder.flush(closing: true)
        let uploads = await replaySink.uploads
        #expect(uploads.map(\.seq) == [0, 1])
        #expect(uploads.allSatisfy { $0.token == token && $0.sessionID == sessions.currentSessionID })
        let first = try SessionReplaySegment.decode(uploads[0].body)
        #expect(first.header.frames.first?.kind == .image)
        #expect(first.header.tTo - first.header.tFrom >= 60_000)
        #expect(recorder.waitingSegments == 0)
    }

    @Test func framesTellTheSessionWhetherTapsCanBeJudgedDead() async {
        let (sessions, recorder) = await launch(answer: .accepted(replay: .buffer))
        #expect(!sessions.isCapturing)
        clock.advance(ms: 1000)
        recorder.add(image("x"), atMs: clock.nowMs())
        #expect(sessions.isCapturing)
        clock.advance(ms: 1000)
        recorder.add(.blank(.noCapture, w: 393, h: 852), atMs: clock.nowMs())
        #expect(!sessions.isCapturing)
        clock.advance(ms: 1000)
        recorder.add(image("x"), atMs: clock.nowMs())
        #expect(sessions.isCapturing)
        recorder.paused = .lowPower
        #expect(!sessions.isCapturing)
    }

    @Test func aTapOnAScreenThatDidNotChangeIsDead() async {
        let (sessions, recorder) = await launch(answer: .accepted(replay: .buffer))
        sessions.screen("habit_form")
        clock.advance(ms: 1000)
        recorder.add(image("form"), atMs: clock.nowMs())
        clock.advance(ms: 100)
        sessions.tap(x: 196.5, y: 800, target: "save")
        clock.advance(ms: 900)
        recorder.add(image("form"), atMs: clock.nowMs())
        clock.advance(ms: 1000)
        recorder.add(image("form"), atMs: clock.nowMs())
        clock.advance(ms: 1000)
        sessions.tick()
        await sessions.flush()
        let deads = await sink.events.map(\.event).filter { $0.kind == "dead" }
        #expect(deads == [.dead(t: 1100, x: 5000, y: 9390, screen: "habit_form")])
    }

    @Test func theSamePictureIsASameFrame() async throws {
        let (_, recorder) = await launch(answer: .accepted(replay: .record, uploadToken: "1795900000." + String(repeating: "b", count: 64)))
        clock.advance(ms: 1000)
        recorder.add(image("x"), atMs: clock.nowMs())
        clock.advance(ms: 1000)
        recorder.add(image("x"), atMs: clock.nowMs())
        clock.advance(ms: 1000)
        recorder.add(.blank(.noCapture, w: 393, h: 852), atMs: clock.nowMs())
        await recorder.flush(closing: true)
        let segment = try SessionReplaySegment.decode(try #require(await replaySink.uploads.first).body)
        #expect(segment.header.frames.map(\.kind) == [.image, .same, .blank])
        #expect(segment.header.frames[2].reason == .noCapture)
        #expect(segment.images.count == 1)
    }

    @Test func theNextBatchSaysWhatTheRecordingDid() async throws {
        let (sessions, recorder) = await launch(answer: .accepted(replay: .record, uploadToken: "1795900000." + String(repeating: "d", count: 64)))
        clock.advance(ms: 1000)
        recorder.add(image("x"), atMs: clock.nowMs())
        clock.advance(ms: 1000)
        recorder.add(image("x"), atMs: clock.nowMs())
        clock.advance(ms: 1000)
        recorder.add(.blank(.maskingFailed, w: 393, h: 852), atMs: clock.nowMs())
        recorder.frameCost = (p50: 21.4, p95: 38.6)
        recorder.paused = .degraded
        await sessions.flush()
        let events = await sink.batches.flatMap(\.events)
        let stats = events.compactMap { event -> SessionReplayStats? in
            if case .replayStats(_, let stats) = event { return stats }
            return nil
        }
        #expect(stats == [SessionReplayStats(captured: 1, dropped: .init(same: 1, maskingFailed: 1), mainMsP50: 21, mainMsP95: 39, stopped: "degraded")])
        // Nothing new: no second one.
        await sessions.flush()
        #expect(await sink.batches.flatMap(\.events).filter { $0.kind == "replay_stats" }.count == 1)
    }

    @Test func replayStatsRoundTrips() throws {
        let event = SessionEvent.replayStats(t: 5000, stats: SessionReplayStats(captured: 3, dropped: .init(same: 2), mainMsP50: 12, mainMsP95: 30, stopped: nil))
        let data = try JSONEncoder().encode(event)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["k"] as? String == "replay_stats")
        #expect((json["dropped"] as? [String: Int]) == ["same": 2, "masking_failed": 0, "no_capture": 0, "secure": 0])
        #expect(json["stopped"] == nil)
        #expect(try JSONDecoder().decode(SessionEvent.self, from: data) == event)
    }

    @Test func framesFasterThanOneASecondAreLeftOut() async throws {
        let (_, recorder) = await launch(answer: .accepted(replay: .record, uploadToken: "1795900000." + String(repeating: "c", count: 64)))
        clock.advance(ms: 1000)
        recorder.add(image("a"), atMs: clock.nowMs())
        clock.advance(ms: 300)
        recorder.add(image("b"), atMs: clock.nowMs())
        await recorder.flush(closing: true)
        let segment = try SessionReplaySegment.decode(try #require(await replaySink.uploads.first).body)
        #expect(segment.header.frames.count == 1)
    }

    @Test func bufferKeepsTheLastMinuteAndSendsNothing() async throws {
        let (sessions, recorder) = await launch(answer: .accepted(replay: .buffer, uploadToken: "1795900000." + String(repeating: "d", count: 64)))
        frames(recorder, seconds: 150)
        await recorder.flush()
        #expect(await replaySink.uploads.isEmpty)
        let kept = store.segments(try #require(sessions.currentSessionID))
        #expect(!kept.isEmpty)
        #expect(kept.allSatisfy { $0.tTo >= 150_000 - 60_000 - 10_000 })
    }

    @Test func aPriorityConditionSendsTheBuffer() async throws {
        let (sessions, recorder) = await launch(answer: .accepted(replay: .buffer, uploadToken: "1795900000." + String(repeating: "e", count: 64)))
        frames(recorder, seconds: 30)
        sessions.hang(startedAtMs: clock.nowMs() - 3000, ms: 3000)
        #expect(sessions.priorityHit)
        frames(recorder, seconds: 1)
        await recorder.flush(closing: true)
        #expect(!(await replaySink.uploads.isEmpty))
    }

    @Test func noTokenNoUpload() async throws {
        let (_, recorder) = await launch(answer: .accepted(replay: .record))
        frames(recorder, seconds: 5)
        await recorder.flush(closing: true)
        #expect(await replaySink.uploads.isEmpty)
        #expect(recorder.waitingSegments == 1)
    }

    @Test func aRefusedTokenDropsTheSession() async throws {
        let (sessions, recorder) = await launch(answer: .accepted(replay: .record, uploadToken: "1795900000." + String(repeating: "f", count: 64)))
        frames(recorder, seconds: 61)
        recorder.closeSegment()
        await replaySink.enqueue(.success(.dropSession))
        await recorder.flush()
        #expect(await replaySink.uploads.count == 1)
        #expect(store.segments(try #require(sessions.currentSessionID)).isEmpty)
        #expect(!recorder.wantsFrames)
    }

    @Test func aFailedUploadKeepsTheSegment() async throws {
        let (_, recorder) = await launch(answer: .accepted(replay: .record, uploadToken: "1795900000." + String(repeating: "0", count: 64)))
        frames(recorder, seconds: 3)
        await replaySink.enqueue(.failure(Unreachable()))
        await recorder.flush(closing: true)
        #expect(recorder.waitingSegments == 1)
        await recorder.flush()
        #expect(recorder.waitingSegments == 0)
    }

    @Test func meteredSendsOnlyPrioritySessions() async throws {
        let (_, recorder) = await launch(answer: .accepted(replay: .record, uploadToken: "1795900000." + String(repeating: "1", count: 64)))
        recorder.network = .metered
        frames(recorder, seconds: 3)
        await recorder.flush(closing: true)
        #expect(await replaySink.uploads.isEmpty)
        recorder.network = .unmetered
        await recorder.flush()
        #expect(await replaySink.uploads.count == 1)
    }

    @Test func theSessionStopsRecordingAtItsLimit() async throws {
        let (sessions, recorder) = await launch(answer: .accepted(replay: .record, uploadToken: "1795900000." + String(repeating: "2", count: 64)))
        clock.advance(ms: 30 * 60_000)
        recorder.add(image("late"), atMs: clock.nowMs())
        #expect(!recorder.wantsFrames)
        #expect(recorder.stopReason == .sessionLimit)
        #expect(sessions.currentSessionID != nil)
    }
}
