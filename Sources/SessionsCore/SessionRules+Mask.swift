import Foundation

// SessionRules: The rectangles painted over a frame before it leaves the device (sessions.md 3.3).
extension SessionRules {
    /// A rectangle in whole pixels of the picture.
    public struct PixelRect: Sendable, Equatable {
        public var x: Int
        public var y: Int
        public var w: Int
        public var h: Int

        public init(x: Int, y: Int, w: Int, h: Int) {
            self.x = x
            self.y = y
            self.w = w
            self.h = h
        }
    }

    public struct MaskRects: Sendable, Equatable {
        /// The frame must not be taken: a part to hide could not be placed.
        public var drop: Bool
        /// `masking_failed` when dropped.
        public var reason: SessionBlankReason?
        public var rects: [PixelRect]
    }

    /// The parts to hide, in points of the window, to whole pixels of the picture: the top left is
    /// rounded down and the bottom right up (an edge never shows), each is cut to the picture, and
    /// one that lies wholly outside is left out. A part whose place is unknown (nil) drops the
    /// frame (`masking_failed`). Overlapping parts are kept as they are, in their order.
    public static func maskRects(scale: Double, imageW: Int, imageH: Int, rects: [SessionRect?]) -> MaskRects {
        var out: [PixelRect] = []
        for rect in rects {
            guard let rect, rect.x.isFinite, rect.y.isFinite, rect.w.isFinite, rect.h.isFinite, scale.isFinite, scale > 0 else {
                return MaskRects(drop: true, reason: .maskingFailed, rects: [])
            }
            let left = max(0, Int(floor(rect.x * scale + 1e-9)))
            let top = max(0, Int(floor(rect.y * scale + 1e-9)))
            let right = min(imageW, Int(ceil((rect.x + rect.w) * scale - 1e-9)))
            let bottom = min(imageH, Int(ceil((rect.y + rect.h) * scale - 1e-9)))
            guard right > left, bottom > top else { continue }
            out.append(PixelRect(x: left, y: top, w: right - left, h: bottom - top))
        }
        return MaskRects(drop: false, reason: nil, rects: out)
    }
}

/// A view as the search for the parts to hide walks it (sessions.md 3.3). UIKit's views in
/// `SessionsCapture`; fakes in the tests.
@MainActor
public protocol SessionMaskNode {
    /// Drawn: not hidden and not fully transparent. A node that is not shown is skipped with
    /// everything inside it.
    var isShown: Bool { get }
    /// Painted over whole, with everything inside it: a `.sessionMask()`, or a password field
    /// (secure text entry, `SecureField`), which is always hidden.
    var hidesWhole: Bool { get }
    /// Its place in the window's points, as drawn. Nil when it cannot be told: the frame is then
    /// dropped (`masking_failed`).
    var frameInWindow: SessionRect? { get }
    var children: [Self] { get }
}

extension SessionRules {
    /// Finding the parts to hide takes longer than this (one frame at 60 Hz): the frame is dropped.
    public static let maskBudgetMs: Double = 16

    /// The parts of a window to paint over, in its points (`bounds`): every shown node that
    /// ``SessionMaskNode/hidesWhole``, cut to the window. One wholly outside is left out. A nil
    /// stands for a part whose place could not be told, and so does a hierarchy of more than
    /// `limit` nodes (a cycle in a broken one): the frame is then dropped.
    @MainActor
    public static func partsToHide<Node: SessionMaskNode>(root: Node, bounds: SessionRect, limit: Int = 10_000) -> [SessionRect?] {
        var parts: [SessionRect?] = []
        var visited = 0
        var tooMany = false
        func visit(_ node: Node) {
            visited += 1
            guard visited <= limit else { tooMany = true; return }
            guard node.isShown else { return }
            guard node.hidesWhole else {
                node.children.forEach(visit)
                return
            }
            guard let frame = node.frameInWindow, frame.x.isFinite, frame.y.isFinite, frame.w.isFinite, frame.h.isFinite else {
                parts.append(nil)
                return
            }
            let left = max(frame.x, bounds.x)
            let top = max(frame.y, bounds.y)
            let right = min(frame.x + frame.w, bounds.x + bounds.w)
            let bottom = min(frame.y + frame.h, bounds.y + bounds.h)
            guard right > left, bottom > top else { return }
            parts.append(SessionRect(x: left, y: top, w: right - left, h: bottom - top))
        }
        visit(root)
        if tooMany { parts.append(nil) }
        return parts
    }

    /// ``maskRects(scale:imageW:imageH:rects:)`` of what `find` returns, fail closed (SC8): `find`
    /// throwing, or finding and placing the parts taking longer than `budgetMs` by `nowMs`, drops the
    /// frame (`masking_failed`), so a frame is never kept with a part left unpainted.
    public static func maskRects(scale: Double, imageW: Int, imageH: Int, budgetMs: Double = SessionRules.maskBudgetMs,
                                 nowMs: () -> Double, find: () throws -> [SessionRect?]) -> MaskRects {
        let dropped = MaskRects(drop: true, reason: .maskingFailed, rects: [])
        let started = nowMs()
        guard let parts = try? find() else { return dropped }
        let planned = maskRects(scale: scale, imageW: imageW, imageH: imageH, rects: parts)
        guard nowMs() - started <= budgetMs else { return dropped }
        return planned
    }
}
