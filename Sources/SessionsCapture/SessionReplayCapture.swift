#if canImport(UIKit)
import Foundation
import ImageIO
import Network
import QuartzCore
import SessionsCore
import UIKit

/// Takes the recording's frames (sessions.md 3.2 and 3.3) and hands them to a
/// ``SessionReplayRecorder`` (and to a ``SessionLiveStream`` while someone watches).
///
/// - At most one frame a second (two while watched live); sooner 0.3 seconds after a screen is
///   entered, 0.5 seconds after a tap and 0.2 seconds after a scroll stops
/// - One frame every 2 seconds while taking one holds the main thread over 16ms (p95); the session's
///   recording stops over 33ms (`degraded`, ``SessionReplayFrameCost``). Not on the simulator, whose
///   times say nothing of a device's
/// - Not while a finger is down or a scroll view is moving; not in Low Power Mode, when the device
///   is hot (`serious` or worse) or under 20% of battery and not charging
/// - The key window is drawn at 1pt to 1px (`drawHierarchy(afterScreenUpdates: false)`), painted
///   black where it must be hidden before it leaves the main thread, and written as JPEG
///   (quality 0.35) on a background thread
/// - Hidden: what the app marks with `.sessionMask()`, and password fields (secure text entry,
///   `SecureField`, a `.password` or `.newPassword` content type), which cannot be unhidden
///   (``SessionMaskMode/marked``). Everything else, ordinary text fields, labels, images and web
///   views included, is recorded as shown
/// - Blank frames (no picture) while ``SessionCapture/blankReason(noCaptureScreens:)`` has a reason,
///   or when a part to hide could not be placed or took over 16ms to find (`masking_failed`)
@MainActor
public final class SessionReplayCapture {
    public struct Configuration: Sendable {
        public var mask: SessionMaskMode
        /// The manifest's `no_capture_screens`.
        public var noCaptureScreens: Set<String>
        public var jpegQuality: Double
        /// The longest side of a frame in pixels (an iPad's window is scaled down to it).
        public var maxLongSide: Double
        /// When frames are spaced out or stopped for holding the main thread too long.
        public var cost: SessionReplayFrameCost

        public init(mask: SessionMaskMode = .marked, noCaptureScreens: Set<String> = [],
                    jpegQuality: Double = 0.35, maxLongSide: Double = 1194,
                    cost: SessionReplayFrameCost = Configuration.defaultCost) {
            self.mask = mask
            self.noCaptureScreens = noCaptureScreens
            self.jpegQuality = jpegQuality
            self.maxLongSide = maxLongSide
            self.cost = cost
        }

        /// 16ms spaces frames out and 33ms stops the session's recording, on a device. The simulator
        /// draws on the CPU, so there it only spaces them out.
        public static var defaultCost: SessionReplayFrameCost {
            #if targetEnvironment(simulator)
            return SessionReplayFrameCost(stopP95Ms: nil)
            #else
            return SessionReplayFrameCost()
            #endif
        }
    }

    public let recorder: SessionReplayRecorder
    public let live: SessionLiveStream?
    public var configuration: Configuration
    private weak var capture: SessionCapture?

    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var lastCaptureAt = 0
    private var dueAt = 0
    private var lastScreen: String?
    private var wasScrolling = false
    private var touches = 0
    private var encoding = false
    private var ticks = 0
    private var cost: SessionReplayFrameCost
    /// The session ``cost`` counts (it starts over with each session).
    private var costSession: String?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(capture: SessionCapture, recorder: SessionReplayRecorder, live: SessionLiveStream?, configuration: Configuration) {
        self.capture = capture
        self.recorder = recorder
        self.live = live
        self.configuration = configuration
        self.cost = configuration.cost
    }

    func start() {
        guard timer == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let recorder = recorder
        pathMonitor.pathUpdateHandler = { path in
            let network: SessionReplayRecorder.Network =
                path.status != .satisfied ? .offline : (path.isExpensive || path.isConstrained ? .metered : .unmetered)
            Task { @MainActor in recorder.network = network }
        }
        pathMonitor.start(queue: DispatchQueue(label: "sessions.replay.network", qos: .utility))
        live?.windowSize = { SessionCapture.keyWindow().map { SessionSize(w: $0.bounds.width, h: $0.bounds.height) } ?? SessionSize(w: 390, h: 844) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.everyTenthOfASecond() }
        }
        Task { await recorder.flush() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pathMonitor.cancel()
        recorder.closeSegment()
        live?.close()
    }

    // MARK: - What SessionCapture reports

    func touch(down: Bool) {
        touches = max(0, touches + (down ? 1 : -1))
    }

    func tapped() {
        touches = 0
        dueSoon(500)
    }

    func enterBackground() {
        live?.close()
        let application = UIApplication.shared
        if backgroundTask == .invalid {
            backgroundTask = application.beginBackgroundTask(withName: "sessions.replay") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTask() }
            }
        }
        Task {
            await recorder.flush(closing: true)
            endBackgroundTask()
        }
    }

    func enterForeground() {
        // A touch that ended while in the back (the recognizer was not told) must not hold frames back.
        touches = 0
        wasScrolling = false
        dueSoon(300)
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - When to take a frame

    private func dueSoon(_ ms: Int) {
        let at = Self.nowMs() + ms
        if dueAt == 0 || at < dueAt { dueAt = at }
    }

    private func everyTenthOfASecond() {
        ticks += 1
        if ticks % 50 == 0 { checkPower() }
        if ticks % 20 == 0 { recorder.tick() }
        guard UIApplication.shared.applicationState != .background else { return }
        if costSession != recorder.sessions.currentSessionID {
            costSession = recorder.sessions.currentSessionID
            cost.reset()
            if recorder.paused == .degraded { recorder.paused = nil }
        }
        let screen = recorder.sessions.currentScreen
        if screen != lastScreen {
            lastScreen = screen
            dueSoon(300)
        }
        let watched = live?.isConnected == true
        // Nothing to take: do not walk the views ten times a second for nothing.
        guard recorder.wantsFrames || watched else {
            wasScrolling = false
            return
        }
        let scrolling = Self.keyWindow().flatMap { SessionCapture.mainScrollView(in: $0) }.map { $0.isTracking || $0.isDecelerating } ?? false
        if wasScrolling, !scrolling { dueSoon(200) }
        wasScrolling = scrolling
        guard !encoding, touches == 0, !scrolling else { return }
        let now = Self.nowMs()
        let interval = cost.intervalMs(live: watched)
        guard now - lastCaptureAt >= interval else { return }
        if dueAt == 0 { dueAt = lastCaptureAt + interval }
        guard now >= dueAt else { return }
        dueAt = 0
        lastCaptureAt = now
        takeFrame(at: now)
    }

    private func checkPower() {
        if recorder.paused == .degraded { return }
        let info = ProcessInfo.processInfo
        let device = UIDevice.current
        let reason: SessionReplayRecorder.StopReason?
        if info.isLowPowerModeEnabled {
            reason = .lowPower
        } else if info.thermalState == .serious || info.thermalState == .critical {
            reason = .thermal
        } else if device.batteryState == .unplugged, device.batteryLevel >= 0, device.batteryLevel < 0.2 {
            reason = .battery
        } else {
            reason = nil
        }
        if recorder.paused != reason { recorder.paused = reason }
    }

    // MARK: - Taking a frame

    private func takeFrame(at now: Int) {
        guard let capture, let window = Self.keyWindow(), window.bounds.width > 0, window.bounds.height > 0 else { return }
        let size = window.bounds.size
        let scale = min(1, configuration.maxLongSide / Double(max(size.width, size.height)))
        let w = max(1, Int((Double(size.width) * scale).rounded()))
        let h = max(1, Int((Double(size.height) * scale).rounded()))
        if let reason = capture.blankReason(noCaptureScreens: configuration.noCaptureScreens) {
            recorder.add(.blank(reason, w: w, h: h), atMs: now)
            return
        }
        let started = CACurrentMediaTime()
        let mode = configuration.mask
        // Fail closed (SC8): parts that cannot be placed, or take over 16ms to find, drop the frame.
        let rects = SessionRules.maskRects(scale: scale, imageW: w, imageH: h, nowMs: { CACurrentMediaTime() * 1000 }) {
            Self.partsToHide(in: window, mode: mode)
        }
        if rects.drop {
            recorder.add(.blank(.maskingFailed, w: w, h: h), atMs: now)
            return
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
        var drew = false
        let image = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            drew = window.drawHierarchy(in: CGRect(x: 0, y: 0, width: w, height: h), afterScreenUpdates: false)
            UIColor.black.setFill()
            for rect in rects.rects { context.fill(CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)) }
        }
        noteDuration((CACurrentMediaTime() - started) * 1000)
        guard drew, let cgImage = image.cgImage else {
            recorder.add(.blank(.unsupported, w: w, h: h), atMs: now)
            return
        }
        let masked = !rects.rects.isEmpty
        let box = ImageBox(image: cgImage)
        let quality = configuration.jpegQuality
        encoding = true
        Task.detached(priority: .utility) { [weak self] in
            let jpeg = Self.jpeg(box.image, quality: quality)
            let fingerprint = Self.fingerprint(box.image)
            guard let self else { return }
            await self.encoded(jpeg, fingerprint: fingerprint, w: w, h: h, masked: masked, atMs: now)
        }
    }

    private func encoded(_ jpeg: Data?, fingerprint: String?, w: Int, h: Int, masked: Bool, atMs now: Int) {
        encoding = false
        guard let jpeg, let fingerprint else { return }
        if recorder.wantsFrames {
            recorder.add(.image(jpeg, mime: "image/jpeg", w: w, h: h, masked: masked, fingerprint: fingerprint), atMs: now)
        }
        live?.sendFrame(jpeg, mime: "image/jpeg", w: w, h: h, masked: masked, atMs: now)
    }

    /// Spaces frames out over 16ms (p95) and stops the session's recording over 33ms (`degraded`).
    private func noteDuration(_ ms: Double) {
        if cost.add(ms) == .degraded, recorder.paused != .degraded {
            recorder.paused = .degraded
        }
    }

    // MARK: - What to hide

    /// The parts of `window` to paint over, in its points: every `.sessionMask()` and every password
    /// field, whatever the app marks (``SessionMaskView``). Nil stands for a part whose place could
    /// not be found (the frame is then dropped).
    static func partsToHide(in window: UIWindow, mode: SessionMaskMode) -> [SessionRect?] {
        let bounds = window.bounds
        switch mode {
        case .marked:
            return SessionRules.partsToHide(root: SessionMaskView(view: window, window: window),
                                            bounds: SessionRect(x: bounds.minX, y: bounds.minY, w: bounds.width, h: bounds.height))
        }
    }

    /// A password field: always hidden, and not something the app can unmark. Secure text entry
    /// (`SecureField` is a `UITextField` with `isSecureTextEntry`), and a field whose content type is
    /// a password's, which stays hidden while a "show password" button turns secure entry off.
    static func isPasswordField(_ view: UIView) -> Bool {
        if let field = view as? UITextField { return field.isSecureTextEntry || isPasswordContent(field.textContentType) }
        if let text = view as? UITextView { return text.isSecureTextEntry || isPasswordContent(text.textContentType) }
        return false
    }

    static func isPasswordContent(_ type: UITextContentType?) -> Bool {
        type == .password || type == .newPassword
    }

    // MARK: - Off the main thread

    nonisolated static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The brightness of a 16×32 copy, 4 bits a cell, as hex: equal for pictures that look the same.
    nonisolated static func fingerprint(_ image: CGImage) -> String? {
        let width = 16
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let digits = Array("0123456789abcdef")
        return String(pixels.map { digits[Int($0 >> 4)] })
    }

    nonisolated static func nowMs() -> Int { Int((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

    static func keyWindow() -> UIWindow? { SessionCapture.keyWindow() }
}

/// A view as ``SessionRules/partsToHide(root:bounds:limit:)`` walks it.
@MainActor
struct SessionMaskView: SessionMaskNode {
    let view: UIView
    let window: UIWindow

    var isShown: Bool { !view.isHidden && view.alpha >= 0.01 }

    var hidesWhole: Bool {
        if let marker = view as? SessionMarkerView { return marker.kind == .mask }
        return SessionReplayCapture.isPasswordField(view)
    }

    /// Where the view is and where it is drawn, together. `drawHierarchy(afterScreenUpdates: false)`
    /// draws what is on the screen, which under an animation is the presentation layer's place and
    /// not the frame's: both are painted over, so a field that moves is covered on either side.
    var frameInWindow: SessionRect? {
        var frame = view.convert(view.bounds, to: window)
        if let shown = view.layer.presentation(), let windowShown = window.layer.presentation() {
            frame = frame.union(shown.convert(shown.bounds, to: windowShown))
        }
        guard !frame.isNull, !frame.isInfinite else { return nil }
        return SessionRect(x: frame.minX, y: frame.minY, w: frame.width, h: frame.height)
    }

    var children: [SessionMaskView] { view.subviews.map { SessionMaskView(view: $0, window: window) } }
}

/// A picture handed to the encoding thread. `CGImage` is immutable.
private struct ImageBox: @unchecked Sendable {
    let image: CGImage
}
#endif
