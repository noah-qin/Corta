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

// Composes the README and social screenshots from shadowless window captures
// (`screencapture -o -l <window id>`), so every image gets the same shadow,
// margin and type. Pure AppKit; compile it (the interpreter has crashed on
// long runs) and run it from anywhere:
//
//   swiftc -O docs/brand/compose-screenshot.swift -o /tmp/compose
//   /tmp/compose plain   window.png out.png
//   /tmp/compose poster  window.png out.png "Title" "Subtitle"
//   /tmp/compose overlay window.png floating.png dx dy out.png
//
// `plain` is the window on white with a soft shadow (the README images).
// `poster` is a 1620 × 2160 card: title, subtitle, the window, and the
// project's address at the foot. `overlay` lays a separate window — the
// command palette, a popover — onto a capture at an offset in pixels from
// the window's top-left corner.

import AppKit

/// A capture as an image that keeps its alpha. Drawing the
/// `NSBitmapImageRep` itself scaled filled the window's transparent rounded
/// corners with black, which read as square corners.
struct Capture {
    let image: NSImage
    let pixelsWide: Int
    let pixelsHigh: Int

    func draw(in rect: NSRect) {
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

func load(_ path: String) -> Capture {
    guard let data = FileManager.default.contents(atPath: path),
        let rep = NSBitmapImageRep(data: data), let cgImage = rep.cgImage
    else { fatalError("cannot read \(path)") }
    return Capture(
        image: NSImage(cgImage: cgImage, size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)),
        pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh)
}

func save(_ image: NSImage, size: NSSize, to path: String) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// The window, drawn at `rect` with the shadow macOS gives a key window.
func drawWindow(_ window: Capture, in rect: NSRect, scale: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 46 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -18 * scale)
    shadow.set()
    window.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

func plain(_ windowPath: String, _ out: String) {
    let window = load(windowPath)
    let w = CGFloat(window.pixelsWide), h = CGFloat(window.pixelsHigh)
    let margin: CGFloat = 120
    let size = NSSize(width: w + margin * 2, height: h + margin * 2)
    let image = NSImage(size: size, flipped: false) { bounds in
        NSColor.white.setFill()
        bounds.fill()
        drawWindow(window, in: NSRect(x: margin, y: margin + 10, width: w, height: h), scale: 1)
        return true
    }
    save(image, size: size, to: out)
}

func poster(_ windowPath: String, _ out: String, title: String, subtitle: String) {
    let window = load(windowPath)
    let size = NSSize(width: 1620, height: 2160)
    let maxWidth: CGFloat = 1440, maxHeight: CGFloat = 1180
    let scale = min(maxWidth / CGFloat(window.pixelsWide), maxHeight / CGFloat(window.pixelsHigh), 1)
    let windowSize = NSSize(
        width: CGFloat(window.pixelsWide) * scale, height: CGFloat(window.pixelsHigh) * scale)

    let titleFont = NSFont.systemFont(ofSize: 92, weight: .bold)
    let subtitleFont = NSFont.systemFont(ofSize: 42, weight: .medium)
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    let titleText = NSAttributedString(string: title, attributes: [
        .font: titleFont, .foregroundColor: NSColor(white: 0.11, alpha: 1), .paragraphStyle: center,
        .kern: -1.5,
    ])
    let subtitleText = NSAttributedString(string: subtitle, attributes: [
        .font: subtitleFont, .foregroundColor: NSColor(white: 0.36, alpha: 1), .paragraphStyle: center,
    ])
    let footerText = NSAttributedString(string: "Corta · github.com/noah-qin/Corta", attributes: [
        .font: NSFont.systemFont(ofSize: 34, weight: .regular),
        .foregroundColor: NSColor(white: 0.42, alpha: 1), .paragraphStyle: center,
    ])
    let textWidth: CGFloat = 1380
    let titleHeight = ceil(titleText.boundingRect(
        with: NSSize(width: textWidth, height: 1000), options: .usesLineFragmentOrigin).height)
    let subtitleHeight = ceil(subtitleText.boundingRect(
        with: NSSize(width: textWidth, height: 1000), options: .usesLineFragmentOrigin).height)
    let gapTitle: CGFloat = 34, gapWindow: CGFloat = 96
    let block = titleHeight + gapTitle + subtitleHeight + gapWindow + windowSize.height
    // The block sits a little above the middle, as the eye expects.
    let top = (size.height - block) / 2 + 40

    let image = NSImage(size: size, flipped: false) { bounds in
        NSGradient(colors: [
            NSColor(srgbRed: 0.957, green: 0.957, blue: 0.949, alpha: 1),
            NSColor(srgbRed: 0.902, green: 0.925, blue: 0.957, alpha: 1),
        ])!.draw(in: bounds, angle: -90)
        var y = size.height - top - titleHeight
        titleText.draw(
            with: NSRect(x: (size.width - textWidth) / 2, y: y, width: textWidth, height: titleHeight),
            options: .usesLineFragmentOrigin)
        y -= gapTitle + subtitleHeight
        subtitleText.draw(
            with: NSRect(x: (size.width - textWidth) / 2, y: y, width: textWidth, height: subtitleHeight),
            options: .usesLineFragmentOrigin)
        y -= gapWindow + windowSize.height
        drawWindow(
            window,
            in: NSRect(x: (size.width - windowSize.width) / 2, y: y, width: windowSize.width,
                height: windowSize.height),
            scale: 1)
        footerText.draw(
            with: NSRect(x: 0, y: 150, width: size.width, height: 60), options: .usesLineFragmentOrigin)
        return true
    }
    save(image, size: size, to: out)
}

func overlay(_ windowPath: String, _ floatingPath: String, dx: CGFloat, dy: CGFloat, _ out: String) {
    let window = load(windowPath)
    let floating = load(floatingPath)
    let ww = CGFloat(window.pixelsWide), wh = CGFloat(window.pixelsHigh)
    let fw = CGFloat(floating.pixelsWide), fh = CGFloat(floating.pixelsHigh)
    // A popover may hang past the window's edge, as it does on screen: the
    // canvas grows to hold it, transparent where neither is.
    let extra: CGFloat = 40
    let width = max(ww, dx + fw + extra), height = max(wh, dy + fh + extra)
    let size = NSSize(width: width, height: height)
    let image = NSImage(size: size, flipped: false) { _ in
        window.draw(in: NSRect(x: 0, y: height - wh, width: ww, height: wh))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 36
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.set()
        floating.draw(in: NSRect(x: dx, y: height - dy - fh, width: fw, height: fh))
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
    save(image, size: size, to: out)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "plain" where args.count == 4: plain(args[2], args[3])
case "poster" where args.count == 6: poster(args[2], args[3], title: args[4], subtitle: args[5])
case "overlay" where args.count == 7:
    overlay(args[2], args[3], dx: CGFloat(Double(args[4])!), dy: CGFloat(Double(args[5])!), args[6])
default:
    FileHandle.standardError.write(Data("usage: see the comment at the top of this file\n".utf8))
    exit(2)
}
