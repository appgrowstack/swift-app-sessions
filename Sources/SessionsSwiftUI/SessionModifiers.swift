import SessionsCore
import SwiftUI
#if canImport(UIKit)
import SessionsCapture
import UIKit
#endif

extension View {
    /// Names this element in the taps on it (`tap.target`). `name` is lowercase letters, digits and `_`.
    public func sessionTarget(_ name: String) -> some View {
        modifier(SessionMarkerModifier(kind: .target(name)))
    }

    /// Hides this element from the session recording. The light record keeps no pixels; the mark is
    /// placed now so the recording finds it.
    public func sessionMask() -> some View {
        modifier(SessionMarkerModifier(kind: .mask))
    }

    /// While this view is on screen, the recording takes no frames (a blank frame `no_capture` instead).
    public func sessionNoCapture() -> some View {
        modifier(SessionNoCaptureModifier())
    }

    /// Records how far this scroll view was scrolled as the list `name` (iOS 18 and later; earlier
    /// versions record only the rows marked with ``sessionRow(_:in:)``).
    public func sessionScroll(_ name: String) -> some View {
        modifier(SessionScrollModifier(name: name))
    }

    /// Marks a row of the list `name`: the largest row shown is the list's `max_row`.
    public func sessionRow(_ index: Int, in list: String) -> some View {
        onAppear { AppSessions.current?.scrollRow(index, list: list) }
    }
}

struct SessionMarkerModifier: ViewModifier {
    enum Kind: Equatable {
        case target(String)
        case mask
    }

    let kind: Kind

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content.background(SessionMarkerRepresentable(kind: kind).allowsHitTesting(false))
        #else
        content
        #endif
    }
}

#if canImport(UIKit)
struct SessionMarkerRepresentable: UIViewRepresentable {
    let kind: SessionMarkerModifier.Kind

    private var markerKind: SessionMarkerView.Kind {
        switch kind {
        case .target(let name): .target(name)
        case .mask: .mask
        }
    }

    func makeUIView(context: Context) -> SessionMarkerView { SessionMarkerView(kind: markerKind) }

    func updateUIView(_ view: SessionMarkerView, context: Context) { view.kind = markerKind }
}
#endif

struct SessionNoCaptureModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { AppSessions.current?.beginNoCapture() }
            .onDisappear { AppSessions.current?.endNoCapture() }
    }
}

struct SessionScrollModifier: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollGeometryChange(for: SessionRules.ScrollSample.self) { geometry in
                SessionRules.ScrollSample(offsetY: geometry.contentOffset.y + geometry.contentInsets.top,
                                          height: geometry.containerSize.height,
                                          contentHeight: geometry.contentSize.height)
            } action: { _, sample in
                AppSessions.current?.scroll(sample, list: name)
            }
        } else {
            content
        }
    }
}
