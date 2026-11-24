import Testing
@testable import SessionsCore

/// A view of a fake hierarchy: what UIKit's views look like to the search for the parts to hide.
struct FakeView: SessionMaskNode {
    var isShown = true
    var hidesWhole = false
    var frameInWindow: SessionRect? = SessionRect(x: 0, y: 0, w: 10, h: 10)
    var children: [FakeView] = []

    static func group(_ children: FakeView...) -> FakeView { FakeView(frameInWindow: window, children: children) }
    static func label(_ frame: SessionRect) -> FakeView { FakeView(frameInWindow: frame) }
    static func password(_ frame: SessionRect?) -> FakeView { FakeView(hidesWhole: true, frameInWindow: frame) }
    static let window = SessionRect(x: 0, y: 0, w: 390, h: 844)
}

@MainActor
struct MaskPartsTests {
    let field = SessionRect(x: 20, y: 300, w: 350, h: 44)

    func parts(_ root: FakeView, limit: Int = 10_000) -> [SessionRect?] {
        SessionRules.partsToHide(root: root, bounds: FakeView.window, limit: limit)
    }

    // SC8: a password field is hidden without any mark from the app.
    @Test func aPasswordFieldIsHidden() {
        let root = FakeView.group(.label(SessionRect(x: 20, y: 100, w: 350, h: 30)), .group(.password(field)))
        #expect(parts(root) == [field])
    }

    @Test func plainViewsAreShown() {
        #expect(parts(.group(.label(field), .group(.label(field)))).isEmpty)
    }

    @Test func aMarkedViewAndAPasswordFieldAreBothHidden() {
        let marked = SessionRect(x: 0, y: 500, w: 390, h: 200)
        #expect(parts(.group(.password(field), .group(.password(marked)))) == [field, marked])
    }

    @Test func whatIsInsideAHiddenViewIsNotWalkedAgain() {
        var outer = FakeView.password(field)
        outer.children = [.password(SessionRect(x: 30, y: 305, w: 10, h: 10))]
        #expect(parts(.group(outer)) == [field])
    }

    @Test func aHiddenBranchIsSkipped() {
        var branch = FakeView.group(.password(field))
        branch.isShown = false
        #expect(parts(.group(branch)).isEmpty)
    }

    @Test func aPartIsCutToTheWindowAndOneOutsideIsLeftOut() {
        let half = SessionRect(x: 300, y: 800, w: 200, h: 100)
        let outside = SessionRect(x: 400, y: 0, w: 50, h: 50)
        #expect(parts(.group(.password(half), .password(outside))) == [SessionRect(x: 300, y: 800, w: 90, h: 44)])
    }

    // A field whose place cannot be told drops the frame rather than leave it unpainted.
    @Test func aPartWithoutAPlaceIsNil() {
        #expect(parts(.group(.password(nil))) == [nil])
        #expect(parts(.group(.password(SessionRect(x: .nan, y: 0, w: 10, h: 10)))) == [nil])
        #expect(parts(.group(.password(SessionRect(x: 0, y: 0, w: .infinity, h: 10)))) == [nil])
        let plan = SessionRules.maskRects(scale: 1, imageW: 390, imageH: 844, rects: parts(.group(.password(nil))))
        #expect(plan.drop && plan.reason == .maskingFailed)
    }

    @Test func tooManyViewsDropTheFrame() {
        let deep = (0..<50).reduce(FakeView.password(field)) { inner, _ in .group(inner) }
        #expect(parts(deep, limit: 20).last == .some(nil))
        #expect(parts(deep) == [field])
    }

    // SC8: the masking throwing, or taking over 16ms, gives a blank frame (`masking_failed`).
    struct Broken: Error {}

    final class Clock {
        var ms = 1000.0
    }

    @Test func findingThatThrowsDropsTheFrame() {
        let plan = SessionRules.maskRects(scale: 1, imageW: 390, imageH: 844, nowMs: { 0 }) { throw Broken() }
        #expect(plan.drop)
        #expect(plan.reason == .maskingFailed)
        #expect(plan.rects.isEmpty)
    }

    @Test func findingOverTheBudgetDropsTheFrame() {
        let clock = Clock()
        let plan = SessionRules.maskRects(scale: 1, imageW: 390, imageH: 844, nowMs: { clock.ms }) {
            clock.ms += 16.5
            return [field]
        }
        #expect(plan.drop)
        #expect(plan.reason == .maskingFailed)
    }

    @Test func findingInTimePaintsTheParts() {
        let clock = Clock()
        let plan = SessionRules.maskRects(scale: 1, imageW: 390, imageH: 844, nowMs: { clock.ms }) {
            clock.ms += 16
            return [field]
        }
        #expect(!plan.drop)
        #expect(plan.rects == [SessionRules.PixelRect(x: 20, y: 300, w: 350, h: 44)])
    }
}
