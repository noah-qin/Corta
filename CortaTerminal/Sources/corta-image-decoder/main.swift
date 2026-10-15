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

import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// Decodes one Kitty graphics PNG (`f=100`) for the app, in a process of its
/// own that has dropped every privilege it could before it reads a byte of
/// the image.
///
/// The PNG is terminal output — any program, or any file `cat` prints — and
/// ImageIO's decoder is a large C parser. Decoded inside Corta, a memory
/// corruption in it ran with Corta's TCC grants, which every child inherits
/// (`SECURITY.md` §4.2). Here it runs under the `pure-computation` sandbox
/// profile: no file system, no network, no IPC beyond the pipes it was
/// handed. An XPC service would contain it the same way; a helper beside
/// `corta-exec` needs no new target type and is spawned the same way.
///
/// Protocol: three little-endian UInt32s (width, height, row stride), then
/// the PNG on stdin. FD 3 is the anonymous shared pixel mapping. On success,
/// stdout contains only width and height as little-endian UInt32s, exit 0. Anything else — not a PNG, over the
/// caps, a decode failure, a sandbox that could not be entered — is a
/// nonzero exit with nothing written. The app checks the sizes again; it
/// trusts this process no more than the stream.
///
/// `--check-sandbox`, for the app's tests: enter the sandbox and exit 0
/// only if a file read is then denied. Not checked on every decode — each
/// decode is a process of its own, and a deliberate denial a decode left a
/// sandbox violation in the system log for every image shown.
let maximumInputBytes = 64 * 1024 * 1024
let maximumDimension = 8192
let maximumPixels = 16 * 1024 * 1024
let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

/// `sandbox_init(3)`: deprecated as a public interface since 10.8, still
/// what the system's own command-line tools use, and not imported into
/// Swift. The named profile needs no profile language.
@_silgen_name("sandbox_init")
func sandboxInit(
    _: UnsafePointer<CChar>, _: UInt64,
    _: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32
let sandboxNamed: UInt64 = 0x0001

/// The decode the app did in process (`KittyImageRenderer.decodePNG`):
/// the signature, `public.png` and nothing ImageIO sniffs instead, and the
/// header's dimensions under the caps before a pixel is decoded.
func decode(_ bytes: [UInt8], mapping: UnsafeMutableRawPointer? = nil,
    expectedWidth: Int? = nil, expectedHeight: Int? = nil, stride: Int? = nil
) -> (width: Int, height: Int)? {
    guard bytes.starts(with: pngSignature) else { return nil }
    let options = [kCGImageSourceTypeIdentifierHint: "public.png"] as CFDictionary
    guard let source = CGImageSourceCreateWithData(Data(bytes) as CFData, options),
        CGImageSourceGetType(source) as String? == "public.png",
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
        width <= maximumPixels / height,
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        image.width == width, image.height == height
    else { return nil }
    guard expectedWidth == nil || expectedWidth == width,
        expectedHeight == nil || expectedHeight == height
    else { return nil }
    guard
        let context = CGContext(
            data: mapping, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: stride ?? width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (width, height)
}

/// A 1×1 PNG decoded before the sandbox closes, so ImageIO and CoreGraphics
/// load what they load lazily (plug-ins, colour profiles) while they still
/// can, and the real decode inside the sandbox needs nothing new.
let warmUp: [UInt8] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
    0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]
guard decode(warmUp) != nil else { exit(2) }

if CommandLine.arguments.dropFirst().first == "--check-sandbox" {
    var error: UnsafeMutablePointer<CChar>?
    guard sandboxInit("pure-computation", sandboxNamed, &error) == 0 else { exit(3) }
    let forbidden = open("/etc/passwd", O_RDONLY)
    guard forbidden < 0 else { exit(5) }
    exit(0)
}

// Acquire only the inherited, already unlinked object before entering the sandbox.
var sharedStat = stat()
guard fstat(3, &sharedStat) == 0, sharedStat.st_size > 0,
    sharedStat.st_size <= maximumPixels * 4 + maximumDimension * 4096
else { exit(4) }
let mappedLength = Int(sharedStat.st_size)
guard let mapping = mmap(nil, mappedLength, PROT_READ | PROT_WRITE, MAP_SHARED, 3, 0),
    mapping != MAP_FAILED
else { exit(4) }
close(3)

var sandboxError: UnsafeMutablePointer<CChar>?
guard sandboxInit("pure-computation", sandboxNamed, &sandboxError) == 0 else { exit(3) }

/// Standard input to end of file, refused past the cap.
func readInput() -> [UInt8]? {
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = chunk.withUnsafeMutableBytes { Darwin.read(0, $0.baseAddress, $0.count) }
        if count == 0 { return bytes }
        if count < 0 {
            if errno == EINTR { continue }
            return nil
        }
        guard bytes.count + count <= maximumInputBytes + 12 else { return nil }
        bytes.append(contentsOf: chunk[0..<count])
    }
}

func writeAll(_ bytes: [UInt8]) -> Bool {
    var written = 0
    while written < bytes.count {
        let count = bytes.withUnsafeBytes { Darwin.write(1, $0.baseAddress! + written, $0.count - written) }
        if count > 0 {
            written += count
        } else if count < 0, errno == EINTR {
            continue
        } else {
            return false
        }
    }
    return true
}

guard let input = readInput(), input.count >= 12 else { exit(1) }
func word(_ at: Int) -> Int {
    Int(
        UInt32(input[at]) | UInt32(input[at + 1]) << 8
            | UInt32(input[at + 2]) << 16 | UInt32(input[at + 3]) << 24)
}
let width = word(0)
let height = word(4)
let stride = word(8)
guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
    width <= maximumPixels / height, stride >= width * 4, stride % 4 == 0,
    stride <= mappedLength / height
else { exit(1) }
guard
    let decoded = decode(
        Array(input.dropFirst(12)), mapping: mapping,
        expectedWidth: width, expectedHeight: height, stride: stride)
else { exit(1) }
var header = [UInt8]()
for word in [decoded.width, decoded.height] {
    let value = UInt32(word)
    header += (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}
guard writeAll(header) else { exit(1) }
munmap(mapping, mappedLength)
exit(0)
