// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

/// The Kitty graphics protocol (`DESIGN.md` §6): inline images as APC
/// sequences, as <https://sw.kovidgoyal.net/kitty/graphics-protocol/>
/// specifies — the format `icat`, plot libraries and TUI file previewers
/// assume.
///
/// Implemented: direct transmission (`t=d`, base64, chunked) in RGB, RGBA or
/// PNG; placement (`t`, `T`, `p`); deletion by id; and the `OK`/error
/// response, including to `a=q` — `kitten icat` refuses outright without one.
///
/// Not implemented, on purpose: file, temp-file and shared-memory
/// transmission (`t=f`/`t=t`/`t=s`), which would let the stream make Corta
/// read a local path it names (`SECURITY.md` §1); animation; Unicode
/// placeholder placement; introspection beyond `a=q`.
///
/// `Performer+KittyGraphics.swift` dispatches; `Grid.imagePlacements` is the
/// side table the renderer reads (`ImagePlacementTable`).
public enum KittyGraphics {
    /// `i=`. `0` is accepted as the default for a one-shot `a=T` that is
    /// never referenced again — `kitten icat` omits `i=` that way.
    public struct ImageID: Hashable, Sendable {
        public var rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
    }

    /// `p=`; `0`/absent falls back to the image id, as every reference
    /// implementation does.
    public struct PlacementID: Hashable, Sendable {
        public var rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
    }

    /// `f=`. PNG is decoded by the app layer — the core has no ImageIO
    /// dependency (`DESIGN.md` §4); RGB/RGBA are already pixels.
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

    /// A fully received image. A raw payload whose byte count is not
    /// `width * height * bytesPerPixel` is dropped, never clamped or padded.
    public struct ImageData: Sendable {
        public var format: PixelFormat
        /// `s=`/`v=`; `0` for PNG, whose decoder reads the real size.
        public var width: Int
        public var height: Int
        public var bytes: [UInt8]

        /// Height in pixels without decoding: `v=`, or for a PNG the `IHDR`
        /// chunk every PNG starts with (big-endian, bytes 20–23). Nil when a
        /// PNG is too short or not one — the app's decoder rejects it anyway.
        var pixelHeight: Int? {
            if height > 0 { return height }
            return pngHeaderValue(at: 20)
        }

        /// Width in pixels without decoding: `s=`, or the `IHDR` width
        /// (bytes 16–19), as for `pixelHeight`.
        var pixelWidth: Int? {
            if width > 0 { return width }
            return pngHeaderValue(at: 16)
        }

        private func pngHeaderValue(at offset: Int) -> Int? {
            guard format == .png, bytes.count >= 24,
                bytes[12] == 0x49, bytes[13] == 0x48, bytes[14] == 0x44, bytes[15] == 0x52
            else { return nil }
            let value =
                Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            return value > 0 ? value : nil
        }
    }

    /// One placement at a document position: `row` is relative to
    /// `baseScrollbackTotal` (`ImagePlacementTable.shifted(byScrollbackGrowth:)`).
    public struct Placement: Sendable {
        public var id: PlacementID
        public var imageID: ImageID
        public var row: Int
        public var column: Int
        /// `c=`/`r=`; `nil` means "from the pixel size and the cell metrics".
        /// The renderer uses its own; the core, when it must know (erasing the
        /// display), uses the pty's winsize (`Grid.cellPixelHeight`).
        public var columns: Int?
        public var rows: Int?
        public var baseScrollbackTotal: Int
        public var zIndex: Int
    }

    enum Command {
        /// `a=t` / `a=T`; `display` is the placement `a=T` bundles.
        case transmit(TransmitHeader, payloadBase64: ArraySlice<UInt8>, moreChunks: Bool, display: DisplayHeader?)
        case display(DisplayHeader)
        case delete(DeleteTarget)
        /// `a=q`: answered from the header alone, nothing stored.
        case query(TransmitHeader)
    }

    /// `format`/`width`/`height` are `nil` on a continuation chunk; only
    /// `Performer.receiveChunk` defaults them, on a first chunk.
    struct TransmitHeader {
        var imageID: ImageID
        var format: PixelFormat?
        var width: Int?
        var height: Int?
        /// `q=`: 0 answers everything, 1 errors only, 2 nothing. Read off the
        /// first chunk and carried to the one that finishes.
        var quiet: Int = 0
    }

    struct DisplayHeader {
        var imageID: ImageID
        var placementID: PlacementID
        var columns: Int?
        var rows: Int?
        var zIndex: Int
        var quiet: Int = 0
        /// `C=1` leaves the cursor where it is; `kitten icat --place` sends
        /// it and positions the cursor itself.
        var movesCursor = true
    }

    /// The `d=` subset implemented. Any other letter is ignored rather than
    /// guessed at — an unknown delete must never delete the wrong thing.
    enum DeleteTarget {
        case all
        case image(ImageID)
        case placement(ImageID, PlacementID)
        case unrecognised
    }

    // Caps (`SECURITY.md` §3): a hostile or buggy stream could otherwise
    // grow any of these without limit.

    /// Decoded bytes per image — about two 4K RGBA frames.
    static let maximumImageBytes = 64 * 1024 * 1024

    /// Per axis; every Metal feature set on macOS supports 8192² textures.
    public static let maximumImageDimension = 8192

    /// 16M pixels: at 4 bytes each, the decode buffer is exactly
    /// `maximumImageBytes`. Checked before decoding — for PNG, off the
    /// header, in the app's `KittyImageRenderer`.
    public static let maximumImagePixels = 16 * 1024 * 1024

    /// Stored (encoded) bytes per pane — kitty's own quota. Past it a new
    /// transmission gets `ENOSPC`; a visible image is never evicted for it.
    public static let maximumPaneImageBytes = 320 * 1024 * 1024

    /// Decoded texture bytes per pane, below the encoded quota because bgra
    /// is up to 4× a PNG; the excess is evicted LRU, not crashed on.
    public static let maximumPaneTextureBytes = 256 * 1024 * 1024

    /// Texture bytes across every pane: VRAM is shared system-wide.
    public static let maximumGlobalTextureBytes = 1024 * 1024 * 1024

    /// Images and placements per session; past either, a new one is refused
    /// rather than evicting one still on screen.
    static let maximumTrackedImages = 64
    static let maximumTrackedPlacements = 256
}
