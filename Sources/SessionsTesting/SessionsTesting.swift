import Foundation
import SessionsCore

/// A clock that moves only when told.
public final class FakeSessionClock: SessionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int

    public init(_ nowMs: Int = 1_795_230_000_000) { current = nowMs }

    public func nowMs() -> Int { lock.withLock { current } }
    public func advance(ms: Int) { lock.withLock { current += ms } }
    public func set(_ nowMs: Int) { lock.withLock { current = nowMs } }
}

/// Session ids `ses_test…0001`, `ses_test…0002` … and install ids `install-0001` … in order.
public final class SequenceSessionIDs: SessionIDGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions = 0
    private var installs = 0

    public init() {}

    public func makeSessionID() -> String {
        lock.withLock {
            sessions += 1
            return "ses_test" + String(format: "%016d", sessions)
        }
    }

    public func makeInstallID() -> String {
        lock.withLock {
            installs += 1
            return String(format: "install-%04d", installs)
        }
    }
}

/// Keeps the state in memory. Share one between two recorders to act out a relaunch.
public final class InMemorySessionStateStore: SessionStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: SessionStoredState?
    private var hang = false
    public private(set) var saves = 0

    public init(_ state: SessionStoredState? = nil) { self.state = state }

    public var stored: SessionStoredState? { lock.withLock { state } }
    public func load() -> SessionStoredState? { lock.withLock { state } }
    public func save(_ state: SessionStoredState) {
        lock.withLock {
            self.state = state
            saves += 1
        }
    }
    public func setHangMarker(_ on: Bool) { lock.withLock { hang = on } }
    public func hangMarker() -> Bool { lock.withLock { hang } }
}

/// Keeps every batch it is given and answers from a queue (with nothing queued, `accepted`).
/// `failing` makes it throw like a device without a network.
public actor RecordingSessionSink: SessionSink {
    public struct Offline: Error {}

    public private(set) var batches: [SessionBatch] = []
    private var replies: [SessionSinkReply] = []
    public var failing = false

    public init() {}

    public func enqueue(_ reply: SessionSinkReply) { replies.append(reply) }
    public func setFailing(_ value: Bool) { failing = value }

    public func send(_ batch: SessionBatch) async throws -> SessionSinkReply {
        if failing { throw Offline() }
        batches.append(batch)
        return replies.isEmpty ? .accepted() : replies.removeFirst()
    }

    /// Every event sent, in order, with the session it belongs to.
    public var events: [(session: String, event: SessionEvent)] {
        batches.flatMap { batch in batch.events.map { (batch.session.sessionID, $0) } }
    }
}

extension SessionDeviceInfo {
    /// An iPhone with a 393 × 852 pt screen.
    public static func test(installID: String? = nil, uid: String? = nil, platform: SessionPlatform = .ios) -> SessionDeviceInfo {
        SessionDeviceInfo(installID: installID, uid: uid, platform: platform, appVersion: "1.8.0", build: "42",
                          channel: "debug", lang: "ja", region: "JP", timeZone: "Asia/Tokyo", osVersion: "26.1",
                          deviceModel: "iPhone17,1", screen: .init(w: 393, h: 852, scale: 3))
    }
}
