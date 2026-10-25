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
import Security
import ImageIO

/// Decodes one Kitty graphics PNG (`f=100`) for the app, in a process of its
/// own that has dropped every privilege it could before it reads a byte of
/// the image.
///
/// The PNG is terminal output — any program, or any file `cat` prints — and
/// ImageIO's decoder is a large C parser. Decoded inside Corta, a memory
/// corruption in it ran with Corta's TCC grants, which every child inherits
/// (`SECURITY.md` §4.2). A signed helper app runs under its own App Sandbox,
/// with no file-access, network or inheritance entitlements. It can read
/// system resources and use its own container, but cannot access the host's
/// user files or network. The host passes only pipes and anonymous pixels.
///
/// Protocol: three little-endian UInt32s (width, height, row stride), then
/// the PNG on stdin. FD 3 is the anonymous shared pixel mapping. On success,
/// stdout contains only width and height as little-endian UInt32s, exit 0. Anything else — not a PNG, over the
/// caps, a decode failure, a sandbox that could not be entered — is a
/// nonzero exit with nothing written. The app checks the sizes again; it
/// trusts this process no more than the stream.
///
/// `--check-sandbox <path>`, for the app's tests: exit 0
/// only if a file read is then denied. Not checked on every decode — each
/// decode is a process of its own, and a deliberate denial a decode left a
/// sandbox violation in the system log for every image shown.
let maximumInputBytes = 64 * 1024 * 1024
let maximumDimension = 8192
let maximumPixels = 16 * 1024 * 1024
let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

/// App Sandbox is applied by macOS before main, from the helper app's own
/// signature. Refuse unsigned SwiftPM products and inherited/expanded rights.
func hasRestrictedSandboxSignature() -> Bool {
    var dynamic: SecCode?
    var code: SecStaticCode?
    var information: CFDictionary?
    guard SecCodeCopySelf([], &dynamic) == errSecSuccess, let dynamic,
        SecCodeCopyStaticCode(dynamic, [], &code) == errSecSuccess, let code,
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
        let dictionary = information as? [String: Any],
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
        entitlements["com.apple.security.app-sandbox"] as? Bool == true
    else { return false }
    // No inherited host permissions, network, file exceptions or debugging.
    return Set(entitlements.keys) == ["com.apple.security.app-sandbox"]
}

guard hasRestrictedSandboxSignature() else { exit(3) }

/// The decode the app did in process (`KittyImageRenderer.decodePNG`):
/// the PNG/GIF signature, its matching ImageIO type, and the dimensions
/// under the caps before the first frame is decoded. No other type is admitted.
func decode(_ bytes: [UInt8], mapping: UnsafeMutableRawPointer? = nil,
    expectedWidth: Int? = nil, expectedHeight: Int? = nil, stride: Int? = nil
) -> (width: Int, height: Int)? {
    let type: String
    if bytes.starts(with: pngSignature) { type = "public.png" }
    else if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { type = "com.compuserve.gif" }
    else { return nil }
    let options = [kCGImageSourceTypeIdentifierHint: type] as CFDictionary
    guard let source = CGImageSourceCreateWithData(Data(bytes) as CFData, options),
        CGImageSourceGetType(source) as String? == type,
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

/// A small startup decode verifies ImageIO works inside the signed sandbox
/// before accepting an untrusted payload or running the explicit probes.
let warmUp: [UInt8] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
    0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]
guard decode(warmUp) != nil else { exit(2) }

if CommandLine.arguments.dropFirst().first == "--check-sandbox" {
    guard CommandLine.arguments.count == 3 else { exit(1) }
    // The host supplies an existing private file outside this helper's
    // container. System files are readable under the standard App Sandbox.
    let forbidden = open(CommandLine.arguments[2], O_RDONLY)
    guard forbidden < 0, errno == EPERM || errno == EACCES else { exit(5) }
    let writable = open(CommandLine.arguments[2], O_WRONLY)
    guard writable < 0, errno == EPERM || errno == EACCES else { exit(5) }
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "--check-network" {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    if descriptor < 0 { exit(errno == EPERM || errno == EACCES ? 0 : 6) }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(9).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    // ECONNREFUSED is not proof of isolation: the sandbox must reject it.
    exit(result < 0 && (errno == EPERM || errno == EACCES) ? 0 : 6)
}

// Map only the inherited, already unlinked object inside the sandbox.
var sharedStat = stat()
guard fstat(3, &sharedStat) == 0, sharedStat.st_size > 0,
    sharedStat.st_size <= maximumPixels * 4 + maximumDimension * 4096
else { exit(4) }
let mappedLength = Int(sharedStat.st_size)
guard let mapping = mmap(nil, mappedLength, PROT_READ | PROT_WRITE, MAP_SHARED, 3, 0),
    mapping != MAP_FAILED
else { exit(4) }
close(3)

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
