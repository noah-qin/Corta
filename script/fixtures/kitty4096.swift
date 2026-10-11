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

import Foundation
import CoreGraphics
import ImageIO
let side = 4096
let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [CGColor(red: 0.1, green: 0.2, blue: 0.8, alpha: 1),
             CGColor(red: 0.9, green: 0.6, blue: 0.2, alpha: 1)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0),
    end: CGPoint(x: side, y: side), options: [])
for index in 0..<32 {
    context.setFillColor(CGColor(red: CGFloat(index) / 32, green: 0.65, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: index * 128, y: 1000, width: 80, height: 1800))
}
let url = URL(fileURLWithPath: "/tmp/corta-4096.png")
let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))
