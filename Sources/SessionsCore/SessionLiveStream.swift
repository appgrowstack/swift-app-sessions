import Foundation

/// How the recording hides what is on screen (the manifest's `mask`).
public enum SessionMaskMode: String, Sendable, Codable, Equatable {
    /// Only what the app marks with `.sessionMask()`, and secure-entry (password) fields, which
    /// are always hidden. Everything else (text fields, labels, images, web views) is recorded as
    /// it is shown.
    case marked
}

/// An open live connection (a WebSocket). Text messages are `sessions/live.schema.json`; a
/// `frame` message is followed by the image as a binary message.
public protocol SessionLiveConnection: AnyObject, Sendable {
    func send(text: String) async throws
    func send(data: Data) async throws
    /// The next text message, or nil once the connection is closed.
    func receive() async throws -> String?
    func close()
}

/// Opens the live connection an offer points to (the connector adds the project's key and the
/// install id).
public protocol SessionLiveConnecting: Sendable {
    func connect(_ offer: SessionLiveOffer) async throws -> any SessionLiveConnection
}

/// The device side of the live view (sessions.md 6.4): when a batch's answer says someone is
/// waiting, opens the connection, says `hello`, sends every event as it is recorded and frames at
/// up to 2 a second (``SessionReplayCapture`` hands them over), and closes on `stop`, when the app
/// goes to the back, or when the wait ends. While it is open, batches go every 5 seconds.
@MainActor
public final class SessionLiveStream {
    public let sessions: AppSessions
    private let connector: any SessionLiveConnecting
    private let clock: any SessionClock
    private var connection: (any SessionLiveConnection)?
    private var connecting = false
    private var offer: SessionLiveOffer?
    /// An offer whose connection the server stopped is not opened again (a new wait has a new token).
    private var stoppedToken: String?
    private var lastFrameAt = 0
    /// The window the hello names (points).
    public var windowSize: @MainActor () -> SessionSize = { SessionSize(w: 390, h: 844) }

    /// Frames per second the viewer takes (the server's `rate` lowers it).
    public private(set) var maxFps: Double = 2

    public init(sessions: AppSessions, connector: any SessionLiveConnecting, clock: any SessionClock = SystemSessionClock()) {
        self.sessions = sessions
        self.connector = connector
        self.clock = clock
        sessions.onLiveOffer = { [weak self] offer in self?.offered(offer) }
        sessions.onEvent = { [weak self] event in self?.send(event) }
    }

    public var isConnected: Bool { connection != nil }

    /// A frame taken at `atMs` would be sent now.
    public func wantsFrame(atMs: Int) -> Bool {
        connection != nil && Double(atMs - lastFrameAt) >= 1000 / maxFps
    }

    /// Sends a frame already painted over (the same picture as the recording's).
    public func sendFrame(_ data: Data, mime: String, w: Int, h: Int, masked: Bool, atMs: Int) {
        guard let connection, let startedAt = sessions.currentSessionStartedAt, wantsFrame(atMs: atMs) else { return }
        lastFrameAt = atMs
        let t = max(0, atMs - startedAt)
        let text = #"{"type":"frame","t":\#(t),"mime":"\#(mime)","w":\#(w),"h":\#(h),"masked":\#(masked)}"#
        Task {
            do {
                try await connection.send(text: text)
                try await connection.send(data: data)
            } catch {
                self.drop(connection)
            }
        }
    }

    /// Closes the connection (the app went to the back).
    public func close() {
        connection?.close()
        connection = nil
        sessions.liveConnected = false
    }

    // MARK: - Inside

    private func offered(_ offer: SessionLiveOffer) {
        if let until = offer.untilMs, until <= clock.nowMs() { return }
        guard connection == nil, !connecting, offer.token != stoppedToken else { return }
        self.offer = offer
        connecting = true
        Task {
            defer { self.connecting = false }
            guard let opened = try? await connector.connect(offer) else { return }
            self.connection = opened
            self.sessions.liveConnected = true
            self.sendHello(on: opened)
            self.listen(on: opened, token: offer.token)
        }
    }

    private func sendHello(on connection: any SessionLiveConnection) {
        guard let id = sessions.currentSessionID else { return }
        let size = windowSize()
        let screen = sessions.currentScreen ?? "unknown"
        let text = #"{"type":"hello","session_id":"\#(id)","screen":"\#(screen)","w":\#(size.w),"h":\#(size.h)}"#
        Task {
            do { try await connection.send(text: text) } catch { self.drop(connection) }
        }
    }

    private func listen(on connection: any SessionLiveConnection, token: String) {
        Task {
            while true {
                let message: String?
                do { message = try await connection.receive() } catch { message = nil }
                guard let message else {
                    self.drop(connection)
                    return
                }
                guard let data = message.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = object["type"] as? String else { continue }
                if type == "stop" {
                    self.stoppedToken = token
                    connection.close()
                    self.drop(connection)
                    return
                }
                if type == "rate", let fps = object["max_fps"] as? Double, fps > 0 {
                    self.maxFps = min(2, fps)
                }
            }
        }
    }

    private func send(_ event: SessionEvent) {
        guard let connection, let body = try? JSONEncoder().encode(event), let json = String(data: body, encoding: .utf8) else { return }
        let text = #"{"type":"event","event":\#(json)}"#
        Task {
            do { try await connection.send(text: text) } catch { self.drop(connection) }
        }
    }

    private func drop(_ dropped: any SessionLiveConnection) {
        guard connection === dropped else { return }
        connection = nil
        sessions.liveConnected = false
    }
}
