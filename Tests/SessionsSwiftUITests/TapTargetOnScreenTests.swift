#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit
@testable import SessionsCapture
import SessionsSwiftUI

/// The tap's name on real SwiftUI views laid in a window. Runs on the iOS simulator only
/// (`xcodebuild test -scheme swift-app-sessions-Package -destination 'platform=iOS Simulator,…'`);
/// `swift test` on the Mac builds nothing here.
@MainActor
struct TapTargetOnScreenTests {
    /// A home of rows, and over it in a ZStack a terms dialog with a dimmed backdrop.
    struct Home: View {
        var layered: Bool

        var body: some View {
            TabView {
                ZStack {
                    VStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { index in
                            Button("row \(index)") {}.frame(maxWidth: .infinity, minHeight: 100).sessionTarget("habit_row")
                        }
                    }
                    dialog
                }
                .tabItem { Label("Home", systemImage: "house") }
            }
        }

        @ViewBuilder var dialog: some View {
            let content = ZStack {
                Color.black.opacity(0.3).ignoresSafeArea()
                VStack {
                    Text("Terms")
                    Button("Agree") {}.padding().sessionTarget("agree")
                }
                .padding(40)
                .background(Color.white)
            }
            if layered { content.sessionLayer() } else { content }
        }
    }

    func window(_ view: some View) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        for _ in 0..<10 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
        }
        return window
    }

    func frame(of name: String, in window: UIWindow) -> CGRect? {
        func find(_ view: UIView) -> CGRect? {
            if let marker = view as? SessionMarkerView, marker.kind == .target(name) { return marker.convert(marker.bounds, to: window) }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return find(window)
    }

    @Test func aTapOnALayerIsNamedByTheLayerNotTheRowUnderIt() throws {
        let window = window(Home(layered: true))
        let agree = try #require(frame(of: "agree", in: window))
        #expect(SessionCapture.targetName(at: CGPoint(x: agree.midX, y: agree.midY), in: window) == "agree")
        // The dialog's text and its backdrop, over the rows.
        #expect(SessionCapture.targetName(at: CGPoint(x: agree.midX, y: agree.minY - 20), in: window) == nil)
        #expect(SessionCapture.targetName(at: CGPoint(x: 20, y: 150), in: window) == nil)
    }

    // What the tap was named before `.sessionLayer()`: the row under the dialog.
    @Test func withoutTheLayerTheRowUnderTheDialogNamesTheTap() throws {
        let window = window(Home(layered: false))
        let agree = try #require(frame(of: "agree", in: window))
        #expect(SessionCapture.targetName(at: CGPoint(x: agree.midX, y: agree.midY), in: window) == "agree")
        #expect(SessionCapture.targetName(at: CGPoint(x: agree.midX, y: agree.minY - 20), in: window) == "habit_row")
    }

    // The tab bar is UIKit's, laid over the SwiftUI view of the tab: the row under it does not count.
    @Test func aTapOnTheTabBarIsNotNamedByTheRowUnderIt() throws {
        let window = window(Home(layered: false))
        let tabBar = try #require(Self.first(UITabBar.self, in: window))
        let button = try #require(tabBar.subviews.flatMap(\.subviews).first { $0.isUserInteractionEnabled && $0.bounds.width > 0 })
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
        #expect(window.hitTest(point, with: nil)?.isDescendant(of: tabBar) == true)
        #expect(SessionMarkerView.target(at: point, in: window) == nil)
    }

    // A List's row is drawn in a SwiftUI view of its own inside the list's cell.
    @Test func aRowOfAListKeepsItsName() throws {
        let window = window(List(0..<5, id: \.self) { index in
            Text("row \(index)").frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .onTapGesture {}.sessionTarget("habit_row")
        })
        let row = try #require(frame(of: "habit_row", in: window))
        #expect(SessionCapture.targetName(at: CGPoint(x: row.midX, y: row.midY), in: window) == "habit_row")
        let plain = self.window(List(0..<5, id: \.self) { index in Text("row \(index)").sessionTarget("habit_row") })
        let plainRow = try #require(frame(of: "habit_row", in: plain))
        #expect(SessionCapture.targetName(at: CGPoint(x: plainRow.midX, y: plainRow.midY), in: plain) == "habit_row")
    }

    @Test func theSystemsOwnIdentifiersAreNotNames() {
        let view = UIView()
        #expect(SessionCapture.isSystemIdentifier("pencil", on: view))
        #expect(SessionCapture.isSystemIdentifier("book", on: view))
        #expect(SessionCapture.isSystemIdentifier("chevron.backward", on: view))
        #expect(SessionCapture.isSystemIdentifier("PopoverDismissRegion", on: view))
        #expect(!SessionCapture.isSystemIdentifier("save_habit", on: view))
        #expect(SessionCapture.isPrivateSystemClass("_UIButtonBarButton"))
        #expect(SessionCapture.isPrivateSystemClass("SwiftUI._UIInheritedView"))
        #expect(SessionCapture.isPrivateSystemClass("_TtGC7SwiftUI14_UIHostingViewV4Home_"))
        #expect(!SessionCapture.isPrivateSystemClass("_TtC5MyAppP33_0123456789ABCDEF10HabitButton"))
        #expect(!SessionCapture.isPrivateSystemClass("MyApp.HabitButton"))
        #expect(!SessionCapture.isPrivateSystemClass("UIButton"))
    }

    static func first<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let found = first(type, in: child) { return found } }
        return nil
    }
}
#endif
