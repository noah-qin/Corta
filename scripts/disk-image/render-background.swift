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

// Renders the disk image's Finder background (D26): a warm gradient and a
// dotted arrow from Corta.app to Applications, without text — Finder
// cannot localise a background picture and the app speaks nine languages.
//
//   swift scripts/disk-image/render-background.swift OUTPUT.tiff
//
// One TIFF holds the 660 × 400 pt window at 1x (72 dpi) and 2x (144 dpi),
// Deflate-compressed. The arrow runs between the icon centres the
// committed DS_Store places, (170, 180) and (490, 180); move one, move
// both. docs/RELEASING.md has the recipe for regenerating DS_Store.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width = 660, height = 400

func srgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(scale: Int) -> CGImage {
    let context = CGContext(data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Points, top-left origin, as Finder reports icon positions.
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)

    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [srgb(0xF9_F4_EB), srgb(0xEF_E7_D9)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])

    let teal = srgb(0x6F_BD_CB)
    context.setStrokeColor(teal)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    context.setLineWidth(5)
    context.setLineDash(phase: 0, lengths: [0.1, 13])
    context.strokeLineSegments(between: [CGPoint(x: 268, y: 180), CGPoint(x: 378, y: 180)])

    context.setLineWidth(6)
    context.setLineDash(phase: 0, lengths: [])
    context.addLines(between: [CGPoint(x: 382, y: 166), CGPoint(x: 396, y: 180), CGPoint(x: 382, y: 194)])
    context.strokePath()
    return context.makeImage()!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-background.swift OUTPUT.tiff\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
for scale in [1, 2] {
    let dpi = 72 * scale
    let properties: [CFString: Any] = [
        kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 8],  // Adobe Deflate
    ]
    CGImageDestinationAddImage(destination, render(scale: scale), properties as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write \(output.path)\n".utf8))
    exit(1)
}
