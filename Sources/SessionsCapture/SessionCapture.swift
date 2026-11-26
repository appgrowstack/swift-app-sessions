#if canImport(UIKit)
import Foundation
import MetricKit
import SessionsCore
import UIKit

/// Feeds an ``AppSessions`` from UIKit: the app going to the back and the front, taps on every
/// window, the keyboard, the main scroll view's depth, hangs of the main thread and MetricKit's
/// crash reports. Nothing here stops or delays a touch.
///
/// The session starts when the app is in the front (`UIApplication.State.active`, or about to enter
/// the front), not at launch: a launch in the back (a `BGTaskScheduler` task, a background fetch, a
/// prewarm) ends the previous session and records nothing. When the person opens the app later, that
/// starts a session of its own.
///
/// ```swift
/// let sessions = AppSessions(sink: FileSessionSink(), channel: "appstore")
/// let capture = SessionCapture(sessions: sessions)
/// capture.start()          // the session starts once the app is in the front
/// ```
@MainActor
public final class SessionCapture {
    public let sessions: AppSessions
    private let store: any SessionStateStore
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var hangMonitor: HangMonitor?
    private let metrics = MetricKitCrashes()
    private var tickCount = 0
    /// The recording, once ``startReplay(_:live:configuration:)`` started it.
    public private(set) var replay: SessionReplayCapture?

    /// `store` must be the store the recorder uses (the hang monitor marks a hang in it).
    public init(sessions: AppSessions, store: any SessionStateStore = FileSessionStateStore.standard()) {
        self.sessions = sessions
        self.store = store
    }

    /// Ends the previous session and starts the observers. Call once, early in the launch. The session
    /// starts when the app is in the front.
    public func start(watchHangs: Bool = true) {
        guard observers.isEmpty else { return }
        sessions.closePrevious()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessions.enterBackground()
                self?.replay?.enterBackground()
            }
        })
        // Coming back from the back, and the first time in the front (also after a launch in the back).
        // A return from Control Center or a system alert is active again without the back: nothing changes.
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enterForeground() }
            })
        }
        observers.append(center.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessions.keyboard(shown: true) }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessions.keyboard(shown: false) }
        })
        observers.append(center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                for window in Self.windows() { self?.attach(to: window) }
            }
        })
        for window in Self.windows() { attach(to: window) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.everyHalfSecond() }
        }
        if watchHangs {
            let monitor = HangMonitor(sessions: sessions, store: store)
            monitor.start()
            hangMonitor = monitor
        }
        metrics.onCrash = { [weak self] periodEnd in
            // A report whose period ended before the previous session started is about an older run.
            guard let self, let previous = self.sessions.previousSessionStartedAt, periodEnd >= previous else { return }
            self.sessions.previousSessionCrashReported()
        }
        MXMetricManager.shared.add(metrics)
        // Started after the app was already in the front.
        if UIApplication.shared.applicationState == .active { enterForeground() }
    }

    private func enterForeground() {
        sessions.enterForeground()
        replay?.enterForeground()
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        timer?.invalidate()
        timer = nil
        hangMonitor?.stop()
        hangMonitor = nil
        MXMetricManager.shared.remove(metrics)
        replay?.stop()
        replay = nil
    }

    /// Starts the recording (sessions.md 3.2): frames go to `recorder`, and to `live` while someone
    /// watches. Make the recorder (and the live stream) before ``start(watchHangs:)``, so they see
    /// the session start; call this right after it.
    ///
    /// ```swift
    /// let recorder = SessionReplayRecorder(sessions: sessions, sink: replaySink)
    /// let live = SessionLiveStream(sessions: sessions, connector: liveConnector)
    /// capture.start()
    /// capture.startReplay(recorder, live: live)
    /// ```
    public func startReplay(_ recorder: SessionReplayRecorder, live: SessionLiveStream? = nil,
                            configuration: SessionReplayCapture.Configuration = .init()) {
        guard replay == nil else { return }
        let replay = SessionReplayCapture(capture: self, recorder: recorder, live: live, configuration: configuration)
        self.replay = replay
        replay.start()
    }

    private func attach(to window: UIWindow) {
        guard !Self.isSystemWindow(window),
              !(window.gestureRecognizers ?? []).contains(where: { $0 is SessionTapRecognizer }) else { return }
        let recognizer = SessionTapRecognizer(report: { [weak self, weak window] point in
            guard let self, let window else { return }
            self.tapped(at: point, in: window)
        }, touch: { [weak self] down in
            self?.replay?.touch(down: down)
        })
        window.addGestureRecognizer(recognizer)
    }

    private func tapped(at point: CGPoint, in window: UIWindow) {
        let space = window.screen.coordinateSpace
        let frame = window.convert(window.bounds, to: space)
        let onScreen = window.convert(point, to: space)
        sessions.tap(x: onScreen.x, y: onScreen.y,
                     window: SessionRect(x: frame.minX, y: frame.minY, w: frame.width, h: frame.height),
                     target: SessionMarkerView.target(at: point, in: window) ?? Self.accessibleName(at: point, in: window))
        replay?.tapped()
    }

    /// The accessibility identifier of the control under `point`, for a tap on something not marked
    /// `.sessionTarget`. Only the identifier the developer set, never the label: a label can carry
    /// what the person wrote (a button showing a habit's name). Made into a target name (lowercase
    /// letters, digits and `_`).
    static func accessibleName(at point: CGPoint, in window: UIWindow) -> String? {
        var view = window.hitTest(point, with: nil)
        var depth = 0
        while let current = view, depth < 8 {
            if !(current is UITextField), !(current is UITextView),
               let identifier = current.accessibilityIdentifier, let name = targetName(identifier) {
                return name
            }
            view = current.superview
            depth += 1
        }
        return nil
    }

    /// `Save Habit` → `save_habit`. Nil when nothing of it is a letter or a digit of ASCII.
    static func targetName(_ text: String) -> String? {
        var out = ""
        var gap = false
        for scalar in text.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if gap, !out.isEmpty { out.append("_") }
                out.unicodeScalars.append(scalar)
                gap = false
            } else {
                gap = true
            }
            if out.count >= 48 { break }
        }
        // The schema's `^[a-z][a-z0-9_]{0,47}$`: a name must start with a letter.
        guard let first = out.unicodeScalars.first, ("a"..."z").contains(first) else { return nil }
        return String(out.prefix(48))
    }

    private func everyHalfSecond() {
        if let window = Self.keyWindow() {
            let frame = window.convert(window.bounds, to: window.screen.coordinateSpace)
            sessions.updateWindow(SessionRect(x: frame.minX, y: frame.minY, w: frame.width, h: frame.height))
            if let scrollView = Self.mainScrollView(in: window) {
                sessions.scroll(.init(offsetY: scrollView.contentOffset.y + scrollView.adjustedContentInset.top,
                                      height: scrollView.bounds.height - scrollView.adjustedContentInset.top,
                                      contentHeight: scrollView.contentSize.height))
            }
        }
        tickCount += 1
        if tickCount % 10 == 0 { sessions.tick() }
    }

    // MARK: - Windows and views

    static func windows() -> [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }

    static func keyWindow() -> UIWindow? {
        windows().first { $0.isKeyWindow }
    }

    /// The keyboard's and the system's own windows.
    static func isSystemWindow(_ window: UIWindow) -> Bool {
        let name = NSStringFromClass(type(of: window))
        return name.contains("Keyboard") || name.contains("TextEffects")
    }

    // MARK: - Frames not to take

    /// Why a frame taken now would be blank, or nil to take it. A screen marked `.sessionNoCapture()`
    /// keeps the frames blank while it is shown and while it lies under the shown screen (pushed on
    /// it in a navigation stack, or presented from it). An alert or an action sheet keeps them blank
    /// while it is up (its text field cannot carry `.sessionMask()`), and so does the system over
    /// the app (the app is not active). `noCaptureScreens` is the manifest's `no_capture_screens`.
    public func blankReason(noCaptureScreens: Set<String> = []) -> SessionBlankReason? {
        SessionRules.blankReason(Self.captureScene(screen: sessions.currentScreen), noCaptureScreens: noCaptureScreens)
    }

    static func captureScene(screen: String?) -> SessionRules.CaptureScene {
        let roots = windows().filter { !$0.isHidden && $0.alpha > 0.01 && !isSystemWindow($0) }
            .compactMap(\.rootViewController).map { SessionScreenController($0) }
        var scene = SessionRules.captureScene(roots: roots, appActive: UIApplication.shared.applicationState == .active, screen: screen)
        // An alert shown in a window of its own (older system alerts, an app's own alert window).
        if windows().contains(where: { !$0.isHidden && NSStringFromClass(type(of: $0)).contains("Alert") }) { scene.alertShown = true }
        return scene
    }

    /// The largest visible scroll view that scrolls up and down, outside lists marked `.sessionScroll`.
    static func mainScrollView(in window: UIWindow) -> UIScrollView? {
        var best: (UIScrollView, CGFloat)?
        func visit(_ view: UIView) {
            if view.isHidden || view.alpha < 0.01 { return }
            if let scroll = view as? UIScrollView, !(view is UITextView),
               scroll.contentSize.height > 0, scroll.bounds.width > window.bounds.width * 0.5 {
                let area = scroll.bounds.width * scroll.bounds.height
                if area > (best?.1 ?? 0) { best = (scroll, area) }
            }
            view.subviews.forEach(visit)
        }
        visit(window)
        return best?.0
    }
}

/// A view controller as the capture walks it (``SessionScreenNode``), read on the main thread.
struct SessionScreenController: SessionScreenNode {
    let hasNoCaptureMark: Bool
    let isAlert: Bool
    let shownChildren: [SessionScreenController]
    private let presentedScreens: [SessionScreenController]

    var presented: SessionScreenController? { presentedScreens.first }

    @MainActor
    init(_ controller: UIViewController) {
        hasNoCaptureMark = controller.viewIfLoaded.map { SessionMarkerView.containsNoCapture($0) } ?? false
        isAlert = controller is UIAlertController
        let children: [UIViewController]
        switch controller {
        case let navigation as UINavigationController:
            // The screens under the top one keep their marks: SwiftUI's NavigationStack is one of these.
            children = navigation.viewControllers
        case let tabs as UITabBarController:
            children = tabs.selectedViewController.map { [$0] } ?? []
        case let split as UISplitViewController:
            children = split.viewControllers
        default:
            children = controller.children.filter { $0.viewIfLoaded?.window != nil }
        }
        shownChildren = children.map { SessionScreenController($0) }
        if let presented = controller.presentedViewController, presented.presentingViewController === controller {
            presentedScreens = [SessionScreenController(presented)]
        } else {
            presentedScreens = []
        }
    }
}

/// Reports where a finger left the window and never recognizes anything, so every touch goes on
/// to the app as if it were not there.
final class SessionTapRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let report: @MainActor (CGPoint) -> Void
    private let touch: @MainActor (Bool) -> Void
    private var startedAt: CGPoint?

    init(report: @escaping @MainActor (CGPoint) -> Void, touch: @escaping @MainActor (Bool) -> Void) {
        self.report = report
        self.touch = touch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if startedAt == nil, let first = touches.first {
            startedAt = first.location(in: view)
            touch(true)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let start = startedAt {
            let end = touch.location(in: view)
            // A drag is a scroll, not a tap.
            if hypot(end.x - start.x, end.y - start.y) < 10 { report(end) }
        }
        if startedAt != nil { touch(false) }
        startedAt = nil
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if startedAt != nil { touch(false) }
        startedAt = nil
        state = .failed
    }

    override func reset() {
        if startedAt != nil { touch(false) }
        startedAt = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// A view that marks a part of the screen: a named tap target (`.sessionTarget`), something to
/// hide from the recording (`.sessionMask`), or a screen not to record (`.sessionNoCapture`). It
/// draws nothing and takes no touches.
public final class SessionMarkerView: UIView {
    public enum Kind: Equatable, Sendable {
        case target(String)
        case mask
        case noCapture
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The name of the smallest target under `point` (window coordinates), on the screen in front: with
    /// a sheet, a full screen cover or a popover up, only the targets on it count. A target of the screen
    /// under it is still in the window and would take the tap's name otherwise.
    static func target(at point: CGPoint, in window: UIWindow) -> String? {
        let root = frontView(in: window) ?? window
        var best: (String, CGFloat)?
        func visit(_ view: UIView) {
            if view.isHidden { return }
            if let marker = view as? SessionMarkerView, case .target(let name) = marker.kind {
                let frame = marker.convert(marker.bounds, to: window)
                if frame.contains(point) {
                    let area = frame.width * frame.height
                    if area < (best?.1 ?? .greatestFiniteMagnitude) { best = (name, area) }
                }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return best?.0
    }

    /// The view of the screen presented last over the window's root (a sheet, a full screen cover, a
    /// popover, an alert), or nil when nothing is presented. A screen on its way out does not count.
    static func frontView(in window: UIWindow) -> UIView? {
        var controller = window.rootViewController
        var front: UIViewController?
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed {
            front = presented
            controller = presented
        }
        guard let view = front?.viewIfLoaded, view.window === window else { return nil }
        return view
    }

    /// `view` or a view inside it carries `.sessionNoCapture()`. Hidden views count too: a mark
    /// must not be lost because SwiftUI hid the branch for a moment.
    static func containsNoCapture(_ view: UIView) -> Bool {
        if let marker = view as? SessionMarkerView, marker.kind == .noCapture { return true }
        return view.subviews.contains { containsNoCapture($0) }
    }
}

/// MetricKit's crash reports. They arrive on a background queue some time after the launch.
final class MetricKitCrashes: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    /// When the crash report's period ended (milliseconds since 1970).
    @MainActor var onCrash: ((Int) -> Void)?

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let crashes = payloads.filter { !($0.crashDiagnostics ?? []).isEmpty }
        guard let latest = crashes.max(by: { $0.timeStampEnd < $1.timeStampEnd }) else { return }
        let end = Int(latest.timeStampEnd.timeIntervalSince1970 * 1000)
        Task { @MainActor in self.onCrash?(end) }
    }
}

extension SessionDeviceInfo {
    /// The device and the app as UIKit and the main bundle see them.
    /// `channel` is `appstore`, `testflight` or `debug`.
    @MainActor
    public static func current(channel: String, uid: String? = nil, installID: String? = nil) -> SessionDeviceInfo {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let screen = SessionCapture.keyWindow()?.screen ?? UIScreen.main
        let locale = Locale.current
        var lang = locale.language.languageCode?.identifier ?? "en"
        if let script = locale.language.script?.identifier, lang == "zh" { lang += "-\(script)" }
        let region = locale.region?.identifier.uppercased() ?? "ZZ"
        return SessionDeviceInfo(
            installID: installID, uid: uid, platform: .ios,
            appVersion: version.range(of: #"^\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil ? version : "0.0",
            build: String(build.prefix(32)), channel: channel, lang: lang,
            region: region.range(of: "^[A-Z0-9]{2,3}$", options: .regularExpression) != nil ? region : "ZZ",
            timeZone: TimeZone.current.identifier, osVersion: UIDevice.current.systemVersion,
            deviceModel: modelIdentifier(),
            screen: .init(w: screen.bounds.width, h: screen.bounds.height, scale: screen.scale))
    }

    /// `iPhone17,1`. On the simulator, the simulated model.
    static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? "unknown" : String(identifier.prefix(64))
    }
}

extension AppSessions {
    /// A recorder fed with UIKit's values for the device (``SessionDeviceInfo/current(channel:uid:installID:)``).
    public convenience init(sink: any SessionSink, channel: String,
                            store: any SessionStateStore = FileSessionStateStore.standard(),
                            configuration: Configuration = .init(),
                            uid: @escaping @MainActor () -> String? = { nil }) {
        self.init(sink: sink, deviceInfo: { SessionDeviceInfo.current(channel: channel, uid: uid()) },
                  store: store, configuration: configuration)
    }
}
#endif
