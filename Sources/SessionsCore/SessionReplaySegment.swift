import Foundation

/// What a frame of the recording holds (`ReplayFrameKind` of `sessions/segment.schema.json`).
public enum SessionReplayFrameKind: String, Sendable, Codable, Equatable {
    /// An image follows in the segment's body.
    case image
    /// The same picture as the frame before; no image.
    case same
    /// Not taken (`reason` says why); no image.
    case blank
}

/// One frame in a segment's header (`ReplayFrame`). `w` and `h` are the picture's pixels (1pt is 1px).
public struct SessionReplayFrame: Sendable, Equatable, Codable {
    /// Milliseconds since the session started.
    public var t: Int
    public var kind: SessionReplayFrameKind
    /// `image/jpeg` or `image/webp`, for `image` only.
    public var mime: String?
    /// Bytes from the end of the header, for `image` only.
    public var offset: Int?
    public var length: Int?
    public var w: Int
    public var h: Int
    /// Some part of the picture was painted over.
    public var masked: Bool
    public var reason: SessionBlankReason?

    public init(t: Int, kind: SessionReplayFrameKind, mime: String? = nil, offset: Int? = nil, length: Int? = nil,
                w: Int, h: Int, masked: Bool, reason: SessionBlankReason? = nil) {
        self.t = t
        self.kind = kind
        self.mime = mime
        self.offset = offset
        self.length = length
        self.w = w
        self.h = h
        self.masked = masked
        self.reason = reason
    }

    /// The fields that belong to the kind and nothing else (the schema's `oneOf`).
    var isWellFormed: Bool {
        guard w >= 1, h >= 1, w <= 4096, h <= 4096, t >= 0 else { return false }
        switch kind {
        case .image:
            guard let mime, let offset, let length else { return false }
            return ["image/jpeg", "image/webp"].contains(mime) && offset >= 0 && length >= 1 && reason == nil
        case .same:
            return mime == nil && offset == nil && length == nil && reason == nil
        case .blank:
            return mime == nil && offset == nil && length == nil && reason != nil
        }
    }
}

/// A segment's header (`ReplaySegmentHeader`).
public struct SessionReplaySegmentHeader: Sendable, Equatable, Codable {
    public var sessionID: String
    /// The segment's number in the session (from 0), the same as `PUT …/segments/:seq`.
    public var seq: Int
    public var tFrom: Int
    public var tTo: Int
    public var frames: [SessionReplayFrame]

    public init(sessionID: String, seq: Int, tFrom: Int, tTo: Int, frames: [SessionReplayFrame]) {
        self.sessionID = sessionID
        self.seq = seq
        self.tFrom = tFrom
        self.tTo = tTo
        self.frames = frames
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case seq
        case tFrom = "t_from"
        case tTo = "t_to"
        case frames
    }
}

/// A segment of the recording (`.agsr`):
///
/// ```
/// "AGSR" (4 bytes) | version 1 (1 byte) | header length (4 bytes, big endian) | header (JSON, UTF-8) | images
/// ```
///
/// The images follow one another in the order of the `image` frames; each frame's `offset` counts
/// from the end of the header. The server reads one frame with a range read of
/// `9 + header length + offset` for `length` bytes.
public struct SessionReplaySegment: Sendable, Equatable {
    public static let magic = Data("AGSR".utf8)
    public static let version: UInt8 = 1
    /// The most one segment may weigh (the server answers 413 above it).
    public static let maxBytes = 1024 * 1024

    public var header: SessionReplaySegmentHeader
    /// The images of the `image` frames, in their order.
    public var images: [Data]

    public init(header: SessionReplaySegmentHeader, images: [Data]) {
        self.header = header
        self.images = images
    }

    /// Why bytes are not a segment (the `error` of `cases/sessions/segment-*.json`).
    public enum DecodeError: String, Error, Sendable {
        case badMagic = "bad_magic"
        case badVersion = "bad_version"
        case badLength = "bad_length"
        case badHeader = "bad_header"
        case badFrameRange = "bad_frame_range"
    }

    /// The segment's bytes. The `image` frames' `offset` and `length` are written from `images`.
    public func encoded() throws -> Data {
        var header = header
        var offset = 0
        var index = 0
        for i in header.frames.indices where header.frames[i].kind == .image {
            let length = index < images.count ? images[index].count : 0
            header.frames[i].offset = offset
            header.frames[i].length = length
            offset += length
            index += 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = try encoder.encode(header)
        var out = Data()
        out.reserveCapacity(9 + json.count + offset)
        out.append(Self.magic)
        out.append(Self.version)
        let length = UInt32(json.count)
        out.append(contentsOf: [UInt8(length >> 24 & 0xff), UInt8(length >> 16 & 0xff), UInt8(length >> 8 & 0xff), UInt8(length & 0xff)])
        out.append(json)
        for image in images.prefix(index) { out.append(image) }
        return out
    }

    /// Reads a segment. Throws ``DecodeError``.
    public static func decode(_ data: Data) throws(DecodeError) -> SessionReplaySegment {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, Data(bytes[0..<4]) == magic else { throw .badMagic }
        guard bytes.count >= 5, bytes[4] == version else { throw .badVersion }
        guard bytes.count >= 9 else { throw .badLength }
        let length = Int(bytes[5]) << 24 | Int(bytes[6]) << 16 | Int(bytes[7]) << 8 | Int(bytes[8])
        guard 9 + length <= bytes.count else { throw .badLength }
        let header: SessionReplaySegmentHeader
        do {
            header = try JSONDecoder().decode(SessionReplaySegmentHeader.self, from: Data(bytes[9..<(9 + length)]))
        } catch {
            throw .badHeader
        }
        guard !header.frames.isEmpty, header.frames.count <= 600, header.seq >= 0, header.tFrom >= 0, header.tTo >= 0,
              header.frames.allSatisfy(\.isWellFormed) else { throw .badHeader }
        let body = Array(bytes[(9 + length)...])
        var images: [Data] = []
        for frame in header.frames where frame.kind == .image {
            let offset = frame.offset ?? 0
            let size = frame.length ?? 0
            guard offset + size <= body.count else { throw .badFrameRange }
            images.append(Data(body[offset..<(offset + size)]))
        }
        return SessionReplaySegment(header: header, images: images)
    }
}
