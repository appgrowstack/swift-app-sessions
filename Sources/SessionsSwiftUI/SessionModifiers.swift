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

    /// Marks this view as a layer drawn over the screen in the same view (a dialog, an onboarding
    /// page, an offer, a picker or a tab bar laid on top with a `ZStack` or `.overlay`). While a
    /// layer is under the finger, only the `.sessionTarget`s inside it name the tap; a tap on the
    /// layer where none of its targets is has no name. Without it, a row under the dialog names a
    /// tap on the dialog. Put it on the layer's root, sized as the part of the screen it covers
    /// (its dimmed backdrop too). A layer inside a layer is in front of it.
    public func sessionLayer() -> some View {
        modifier(SessionLayerModifier())
    }

    /// Hides this element from the session recording. The light record keeps no pixels; the mark is
    /// placed now so the recording finds it.
    public func sessionMask() -> some View {
        modifier(SessionMarkerModifier(kind: .mask))
    }

    /// While this screen is shown, and while it lies under the shown screen (a screen pushed on it in
    /// a NavigationStack, a sheet presented from it), the recording takes no frames (blank frames
    /// `no_capture` instead). Put it on the screen's root view.
    public func sessionNoCapture() -> some View {
        modifier(SessionMarkerModifier(kind: .noCapture))
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
        case layer
        case mask
        case noCapture
    }

    let kind: Kind
    @Environment(\.sessionLayers) private var layers

    func body(content: Content) -> some View {
        #if canImport(UIKit)
        content.background(SessionMarkerRepresentable(kind: kind, layers: layers).allowsHitTesting(false))
        #else
        content
        #endif
    }
}

/// `.sessionLayer()`: the layer's own mark, and the path of layers for the marks inside it.
struct SessionLayerModifier: ViewModifier {
    @State private var id = UUID().uuidString
    @Environment(\.sessionLayers) private var outer

    func body(content: Content) -> some View {
        let layers = outer + [id]
        #if canImport(UIKit)
        content
            .environment(\.sessionLayers, layers)
            .background(SessionMarkerRepresentable(kind: .layer, layers: layers).allowsHitTesting(false))
        #else
        content.environment(\.sessionLayers, layers)
        #endif
    }
}

extension EnvironmentValues {
    /// The layers (`.sessionLayer()`) a view is in, outermost first.
    @Entry var sessionLayers: [String] = []
}

#if canImport(UIKit)
struct SessionMarkerRepresentable: UIViewRepresentable {
    let kind: SessionMarkerModifier.Kind
    let layers: [String]

    private var markerKind: SessionMarkerView.Kind {
        switch kind {
        case .target(let name): .target(name)
        case .layer: .layer
        case .mask: .mask
        case .noCapture: .noCapture
        }
    }

    func makeUIView(context: Context) -> SessionMarkerView { SessionMarkerView(kind: markerKind, layers: layers) }

    func updateUIView(_ view: SessionMarkerView, context: Context) {
        view.kind = markerKind
        view.layers = layers
    }
}
#endif

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
