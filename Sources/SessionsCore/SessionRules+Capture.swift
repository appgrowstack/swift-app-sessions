import Foundation

/// Why a frame of the recording is not taken (`ReplayBlankReason` of `sessions/segment.schema.json`).
public enum SessionBlankReason: String, Sendable, Codable, Equatable {
    /// A screen marked not to be captured is shown or lies under what is shown, an alert is up, or
    /// the screen's name is in the manifest's `no_capture_screens`.
    case noCapture = "no_capture"
    /// A secure window (Android's `FLAG_SECURE`).
    case secure
    /// The parts to hide could not be found.
    case maskingFailed = "masking_failed"
    /// Something the app cannot draw is over it (the system's alert, another process's screen).
    case unsupported
}

/// One screen on the way from a window's root to what it shows, as the capture sees it. UIKit's
/// view controllers in `SessionsCapture`; fakes in the tests.
public protocol SessionScreenNode {
    /// This screen's own views carry a `.sessionNoCapture()` mark.
    var hasNoCaptureMark: Bool { get }
    /// An alert or an action sheet (`UIAlertController`): its text field cannot carry a mark.
    var isAlert: Bool { get }
    /// The screens inside it that are shown or kept under what is shown: every screen of a
    /// navigation stack (bottom to top), only the selected tab, the children on screen.
    var shownChildren: [Self] { get }
    /// The screen presented over it (a sheet, a full screen cover, an alert).
    var presented: Self? { get }
}

extension SessionRules {
    /// What decides whether a frame is taken.
    public struct CaptureScene: Sendable, Equatable {
        /// A screen marked `.sessionNoCapture()` is shown, or lies under the shown one in a
        /// navigation stack, or a sheet is presented over it.
        public var noCaptureMarked: Bool
        /// An alert or an action sheet is shown.
        public var alertShown: Bool
        /// The app is active. While the system's alert, the notification centre or the app switcher
        /// is over the app, it is not.
        public var appActive: Bool
        /// The last `screen_viewed` value.
        public var screen: String?

        public init(noCaptureMarked: Bool = false, alertShown: Bool = false, appActive: Bool = true, screen: String? = nil) {
            self.noCaptureMarked = noCaptureMarked
            self.alertShown = alertShown
            self.appActive = appActive
            self.screen = screen
        }
    }

    /// Walks from the windows' roots to what they show. A mark on any screen on the way counts, so
    /// a screen pushed on a marked one, or presented from it, is not captured either (the mark is
    /// not lost when the marked screen goes under another). Tabs that are not selected are not
    /// walked.
    public static func captureScene<Node: SessionScreenNode>(roots: [Node], appActive: Bool = true, screen: String? = nil) -> CaptureScene {
        var scene = CaptureScene(appActive: appActive, screen: screen)
        var visited = 0
        func visit(_ node: Node) {
            // A cycle in a broken hierarchy must not hang the capture.
            visited += 1
            guard visited < 10_000 else { scene.noCaptureMarked = true; return }
            if node.hasNoCaptureMark { scene.noCaptureMarked = true }
            if node.isAlert { scene.alertShown = true }
            node.shownChildren.forEach(visit)
            if let presented = node.presented { visit(presented) }
        }
        roots.forEach(visit)
        return scene
    }

    /// Why the frame is not taken, or nil to take it. `noCaptureScreens` is the manifest's
    /// `no_capture_screens`.
    public static func blankReason(_ scene: CaptureScene, noCaptureScreens: Set<String> = []) -> SessionBlankReason? {
        if !scene.appActive { return .unsupported }
        if scene.noCaptureMarked || scene.alertShown { return .noCapture }
        if let screen = scene.screen, noCaptureScreens.contains(screen) { return .noCapture }
        return nil
    }
}
