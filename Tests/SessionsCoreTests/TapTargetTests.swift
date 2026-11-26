import Testing
@testable import SessionsCore

/// The tap's name from the marks under the screen (`SessionRules.tapTarget`), back to front.
struct TapTargetTests {
    typealias Mark = SessionRules.TapMark

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> SessionRect { SessionRect(x: x, y: y, w: w, h: h) }

    /// A home of rows 400 × 100, and over it in a ZStack a dialog layer covering the screen with an
    /// `agree` button in the middle: what a terms dialog looks like.
    static let home: [Mark] = (0..<8).map { Mark(kind: .target("habit_row"), frame: rect(0, Double($0) * 100, 400, 100)) }
    static let dialog: [Mark] = [
        Mark(kind: .layer, frame: rect(0, 0, 400, 800), layers: ["dialog"]),
        Mark(kind: .target("agree"), frame: rect(160, 370, 80, 50), layers: ["dialog"])
    ]

    @Test func theSmallestTargetUnderTheFingerNamesTheTap() {
        let marks = [Mark(kind: .target("habit_row"), frame: Self.rect(0, 0, 400, 100)),
                     Mark(kind: .target("habit_check"), frame: Self.rect(340, 20, 40, 40))]
        #expect(SessionRules.tapTarget(x: 350, y: 30, marks: marks) == "habit_check")
        #expect(SessionRules.tapTarget(x: 100, y: 30, marks: marks) == "habit_row")
        #expect(SessionRules.tapTarget(x: 100, y: 130, marks: marks) == nil)
    }

    @Test func aButtonOnALayerTakesItsOwnName() {
        #expect(SessionRules.tapTarget(x: 200, y: 400, marks: Self.home + Self.dialog) == "agree")
    }

    // A tap on the dialog (or its dimmed backdrop) where it has no target used to take the name of
    // the row under it (`habit_row` on the terms' "agree", on the offer's "continue for free").
    @Test func aRowUnderALayerDoesNotNameATapOnTheLayer() {
        #expect(SessionRules.tapTarget(x: 200, y: 600, marks: Self.home + Self.dialog) == nil)
        #expect(SessionRules.tapTarget(x: 20, y: 50, marks: Self.home + Self.dialog) == nil)
    }

    @Test func outsideTheLayerTheScreenUnderItCounts() {
        let sheet = [Mark(kind: .layer, frame: Self.rect(0, 500, 400, 300), layers: ["sheet"]),
                     Mark(kind: .target("habit_save"), frame: Self.rect(300, 520, 80, 40), layers: ["sheet"])]
        #expect(SessionRules.tapTarget(x: 340, y: 540, marks: Self.home + sheet) == "habit_save")
        #expect(SessionRules.tapTarget(x: 340, y: 700, marks: Self.home + sheet) == nil)
        #expect(SessionRules.tapTarget(x: 200, y: 150, marks: Self.home + sheet) == "habit_row")
    }

    @Test func aLayerInsideALayerIsInFront() {
        let picker = [Mark(kind: .layer, frame: Self.rect(50, 300, 300, 200), layers: ["dialog", "picker"]),
                      Mark(kind: .target("time_ok"), frame: Self.rect(250, 450, 80, 40), layers: ["dialog", "picker"])]
        // Listed before the dialog's marks, it is still in front: it is deeper.
        let marks = Self.home + picker + Self.dialog
        #expect(SessionRules.tapTarget(x: 280, y: 460, marks: marks) == "time_ok")
        #expect(SessionRules.tapTarget(x: 200, y: 400, marks: marks) == nil)
        #expect(SessionRules.tapTarget(x: 200, y: 700, marks: marks) == nil)
    }

    @Test func ofTwoLayersAsDeepTheLaterIsInFront() {
        let tabs = [Mark(kind: .layer, frame: Self.rect(0, 720, 400, 80), layers: ["tabs"]),
                    Mark(kind: .target("tab_home"), frame: Self.rect(0, 720, 200, 80), layers: ["tabs"])]
        #expect(SessionRules.tapTarget(x: 100, y: 760, marks: Self.home + tabs) == "tab_home")
        #expect(SessionRules.tapTarget(x: 100, y: 760, marks: Self.home + tabs + Self.dialog) == nil)
    }

    @Test func ofTwoTargetsAsSmallTheLaterIsInFront() {
        let marks = [Mark(kind: .target("back"), frame: Self.rect(0, 0, 100, 100)),
                     Mark(kind: .target("front"), frame: Self.rect(0, 0, 100, 100))]
        #expect(SessionRules.tapTarget(x: 50, y: 50, marks: marks) == "front")
    }
}
