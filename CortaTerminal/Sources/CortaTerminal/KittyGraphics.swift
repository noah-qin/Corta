/// The Kitty graphics protocol (M10, deferred since M6.4 — `DESIGN.md` §6,
/// `ROADMAP.md`): inline images, transmitted as APC sequences
/// (`ESC _ G ... ESC \`) the way <https://sw.kovidgoyal.net/kitty/graphics-protocol/>
/// specifies. Ghostty, WezTerm, iTerm2 and foot all implement some or all of
/// the same wire format, which is why this exists — some remote toolchains
/// (`icat`, plot libraries, image previewers in TUI file managers) assume it.
///
/// **What is implemented.** Direct transmission (`t=d`: the payload *is* the
/// image, base64-encoded, chunked with `m=1`/`m=0`) in RGB, RGBA or PNG
/// format; placement (actions `t`, `T`, `p`); deletion (action `d`, the
/// placement- and image-scoped variants); the `a=q` support-detection query
/// and the `OK`/error APC response every non-quiet command gets
/// (`Performer+KittyGraphics.swift`'s `respond`). This covers every tool
/// this project's own research turned up as an actual reason to want the
/// protocol (`icat`-alikes, plot viewers, file-manager previews), which all
/// transmit this way — and a real-client verification pass against
/// `kitten icat` (M10's own done-when) is what found the response was
/// missing: `icat` sends `a=q` before ever transmitting a real image and
/// refuses outright when nothing answers it.
///
/// **What is deliberately not implemented**, and why each is a scope
/// decision rather than an oversight:
/// - File, temporary-file and shared-memory transmission (`t=f`/`t=t`/
///   `t=s`) — these ask the terminal to open a path the remote stream
///   names. `SECURITY.md` §1 assumes every byte from the PTY is hostile;
///   a stream that can make Corta read an arbitrary local file by naming
///   it is exactly the class of thing this document's threat model rejects,
///   and it is also the one part of the real protocol every reference
///   implementation has had security advisories about.
/// - Animation frames and Unicode placeholder ("virtual") placement — real
///   features, genuinely out of scope for a first implementation, not
///   attempted rather than attempted badly. The full query/response
///   *introspection* surface beyond `a=q` (cursor-position reporting for a
///   placement, and the like) stays out for the same reason.
///
/// **Where each piece lives.** This file: wire format types and the
/// transmission-in-progress accumulator. `Performer+KittyGraphics.swift`:
/// the APC dispatch that drives it. `Grid.imagePlacements`: the
/// document-position side table `TerminalRenderer` reads — see
/// `ImagePlacementTable`'s doc comment for why it is not a `Cell` field.
public enum KittyGraphics {
    /// `i=` — identifies a transmitted image across possibly many chunks and
    /// possibly many placements. The spec calls `0` invalid for an id a
    /// client intends to *reuse*, but `KittyGraphicsParser.transmitHeader`
    /// accepts it (as the default when `i=` is absent) for a one-shot
    /// `a=T` that will never be referenced again — real `kitten icat`
    /// omits `i=` this way for a plain display, and a table keyed by
    /// `ImageID` has no other reason to refuse the value 0 as a key.
    public struct ImageID: Hashable, Sendable {
        public var rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
    }

    /// `p=` — identifies one placement of an image; `0`/absent means "the
    /// implementation may assign one", which here is the image id itself
    /// (matching every reference implementation's fallback).
    public struct PlacementID: Hashable, Sendable {
        public var rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
    }

    /// `f=` — pixel format of a *direct* transmission. PNG is decoded by the
    /// app layer (`CoreTerminal` has no ImageIO dependency, by design —
    /// `DESIGN.md` §2: the core is pure Swift with no platform-framework
    /// pulled in beyond what parsing itself needs); RGB/RGBA are decoded
    /// nowhere, just memcpy'd into a texture, since they already are pixels.
    public enum PixelFormat: Sendable, Equatable {
        case rgb
        case rgba
        case png

        init?(code: Int) {
            switch code {
            case 24: self = .rgb
            case 32: self = .rgba
            case 100: self = .png
            default: return nil
            }
        }
    }

    /// One fully-received image transmission: the format tag plus the raw
    /// bytes — decoded from base64, never from whatever the pixel format
    /// claims. A `.rgb`/`.rgba` payload's byte count is checked against
    /// `width * height * bytesPerPixel` before it is trusted for anything
    /// (`SECURITY.md` §3: every parser input has an explicit cap) — a
    /// mismatch means the image is dropped, not clamped or padded.
    public struct ImageData: Sendable {
        public var format: PixelFormat
        /// The transmitted `s=`/`v=`, meaningful for `.rgb`/`.rgba` (where
        /// they are the only source of the image's dimensions) and a
        /// placeholder `0` for `.png` (real clients omit `s=`/`v=` for PNG,
        /// since the file itself carries its dimensions) — the app layer's
        /// PNG decoder reads the real size off the decoded image, not
        /// these.
        public var width: Int
        public var height: Int
        public var bytes: [UInt8]
    }

    /// One placement of a transmitted image at a document position. `row`
    /// follows the same convention `TerminalSelection`/`GridPosition` use
    /// elsewhere in the renderer: it is relative to `baseScrollbackTotal`,
    /// shifted by however much `Scrollback.totalPushed` has grown since —
    /// see `ImagePlacementTable.shifted(byScrollbackGrowth:)`.
    public struct Placement: Sendable {
        public var id: PlacementID
        public var imageID: ImageID
        public var row: Int
        public var column: Int
        /// Requested size in cells (`c=`/`r=`), if the sender gave one —
        /// `nil` means "compute from the image's pixel size and the
        /// renderer's own cell metrics", which only the app layer knows.
        public var columns: Int?
        public var rows: Int?
        public var baseScrollbackTotal: Int
        public var zIndex: Int
    }

    /// A parsed APC command, before it is applied to any state — see
    /// `Performer+KittyGraphics.swift` for what each case does.
    enum Command {
        /// `a=t` or `a=T` (transmit, optionally-with-display) — `display`
        /// carries the placement request `a=T` bundles with the transmit
        /// when present.
        case transmit(TransmitHeader, payloadBase64: ArraySlice<UInt8>, moreChunks: Bool, display: DisplayHeader?)
        /// `a=p` — place an already-transmitted image.
        case display(DisplayHeader)
        /// `a=d` — delete, per `DeleteTarget`.
        case delete(DeleteTarget)
        /// `a=q` — "could you display something shaped like this", answered
        /// from the header alone, never storing or displaying anything. This
        /// is the support-detection probe real clients send before ever
        /// transmitting a real image — `kitten icat` refuses outright
        /// without a response to it, which is what a real-client
        /// verification pass (M10's own done-when) found this
        /// implementation was silent on.
        case query(TransmitHeader)
    }

    /// `format`/`width`/`height` are `nil` on a continuation chunk, which
    /// carries only `i=` — see `KittyGraphicsParser.transmitHeader` and
    /// `Performer.receiveChunk`, which is the only place they are defaulted
    /// (`.rgba`, `0`), and only for a transmission's first chunk.
    struct TransmitHeader {
        var imageID: ImageID
        var format: PixelFormat?
        var width: Int?
        var height: Int?
        /// `q=` — 0 responds to both success and error (the default), 1
        /// suppresses the `OK` response (errors still respond), 2 suppresses
        /// every response. Parsed once, off the first chunk, and carried
        /// through to whichever chunk finishes the transmission — the same
        /// "resolved only when starting" treatment `format`/`width`/`height`
        /// already get.
        var quiet: Int = 0
    }

    struct DisplayHeader {
        var imageID: ImageID
        var placementID: PlacementID
        var columns: Int?
        var rows: Int?
        var zIndex: Int
        /// `q=` on a bare `a=p` — see `TransmitHeader.quiet`.
        var quiet: Int = 0
    }

    /// `d=` values this implements — a small, safe subset (by id, and all).
    /// Every other `d=` letter the real protocol defines (by column, by row,
    /// by z-index range, by point) is accepted and ignored rather than
    /// misinterpreted: a delete request Corta does not understand must
    /// never silently delete the wrong thing.
    enum DeleteTarget {
        case all
        case image(ImageID)
        case placement(ImageID, PlacementID)
        case unrecognised
    }

    /// The maximum single-image byte budget, decoded — about a 4K RGBA
    /// frame. `SECURITY.md` §3: every unbounded input needs an explicit
    /// cap, and an image is exactly the kind of payload a hostile or just
    /// buggy remote stream could otherwise grow without limit across many
    /// chunks.
    static let maximumImageBytes = 64 * 1024 * 1024

    /// How many images this session tracks at once, transmitted-but-unused
    /// included. Beyond this, a new transmission is refused rather than
    /// evicting an old one silently out from under a still-visible
    /// placement.
    static let maximumTrackedImages = 64

    /// How many live placements this session tracks at once.
    static let maximumTrackedPlacements = 256
}
