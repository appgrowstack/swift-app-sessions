import Testing
@testable import SessionsCore

/// A screen of a fake hierarchy: what UIKit's view controllers look like to the capture.
struct FakeScreen: SessionScreenNode {
    var hasNoCaptureMark = false
    var isAlert = false
    var shownChildren: [FakeScreen] = []
    var presentedScreens: [FakeScreen] = []
    var presented: FakeScreen? { presentedScreens.first }

    static let plain = FakeScreen()
    static let marked = FakeScreen(hasNoCaptureMark: true)
    static func stack(_ screens: FakeScreen...) -> FakeScreen { FakeScreen(shownChildren: screens) }
}

struct CaptureSceneTests {
    func reason(_ roots: [FakeScreen], appActive: Bool = true, screen: String? = nil, noCaptureScreens: Set<String> = []) -> SessionBlankReason? {
        SessionRules.blankReason(SessionRules.captureScene(roots: roots, appActive: appActive, screen: screen), noCaptureScreens: noCaptureScreens)
    }

    @Test func aPlainScreenIsTaken() {
        #expect(reason([.stack(.plain)]) == nil)
    }

    @Test func aMarkedScreenIsBlank() {
        #expect(reason([.stack(.marked)]) == .noCapture)
    }

    // N18: the mark used to end on the marked screen's onDisappear, which SwiftUI calls when a
    // screen is pushed on it, so the pushed screen (a thread of the support) was captured.
    @Test func aScreenPushedOnAMarkedScreenIsBlank() {
        #expect(reason([.stack(.marked, .plain)]) == .noCapture)
        #expect(reason([.stack(.marked, .plain, .plain)]) == .noCapture)
    }

    @Test func aSheetPresentedFromAMarkedScreenIsBlank() {
        var marked = FakeScreen.marked
        marked.presentedScreens = [.plain]
        #expect(reason([.stack(marked)]) == .noCapture)
    }

    @Test func afterPoppingTheMarkedScreenFramesAreTakenAgain() {
        #expect(reason([.stack(.plain)]) == nil)
    }

    @Test func aMarkedTabThatIsNotSelectedDoesNotBlank() {
        // A tab bar walks only its selected tab; the marked tab is not in shownChildren.
        let tabs = FakeScreen(shownChildren: [.stack(.plain)])
        #expect(reason([tabs]) == nil)
    }

    // N20: a text field inside an alert cannot carry `.sessionMask()`.
    @Test func anAlertIsBlank() {
        let screen = FakeScreen(presentedScreens: [FakeScreen(isAlert: true)])
        #expect(reason([.stack(screen)]) == .noCapture)
    }

    @Test func theSystemOverTheAppIsUnsupported() {
        #expect(reason([.stack(.plain)], appActive: false) == .unsupported)
    }

    @Test func aScreenOfTheManifestIsBlank() {
        #expect(reason([.stack(.plain)], screen: "page_capture", noCaptureScreens: ["page_capture"]) == .noCapture)
        #expect(reason([.stack(.plain)], screen: "bookshelf", noCaptureScreens: ["page_capture"]) == nil)
    }

    @Test func blankReasonsAreTheSchemaValues() {
        #expect(SessionBlankReason.noCapture.rawValue == "no_capture")
        #expect(SessionBlankReason.maskingFailed.rawValue == "masking_failed")
    }

    // The manifest's `mask` has one value: only marked views (and password fields) are hidden.
    @Test func maskModeIsMarkedOnly() throws {
        #expect(SessionMaskMode.marked.rawValue == "marked")
        #expect(SessionMaskMode(rawValue: "inputs") == nil)
        #expect(SessionMaskMode(rawValue: "text_and_images") == nil)
    }
}
