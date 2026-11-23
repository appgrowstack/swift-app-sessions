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
