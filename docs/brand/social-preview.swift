// Renders the GitHub social preview card (1280 x 640).
//
//   swift docs/brand/social-preview.swift docs/brand/social-preview.png [dark|light]
//
// Pure AppKit and Core Text, so it needs nothing installed. Run it from the
// repository root — the mascot is loaded by a relative path.

import AppKit

let outPath = CommandLine.arguments[1]
let theme = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "dark"
let isLight = theme == "light"

let W = 1280.0, H = 640.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) -> NSColor {
    NSColor(srgbRed: Double(r)/255, green: Double(g)/255, blue: Double(b)/255, alpha: a)
}

// Palette. The dark card is a slate blue rather than near-black: the mascot
// is warm and needs a ground with some light in it to sit on.
let groundTop = isLight ? rgb(247, 249, 251) : rgb(38, 52, 68)
let groundBot = isLight ? rgb(232, 237, 243) : rgb(28, 39, 52)
let cyan      = isLight ? rgb(0, 150, 156)   : rgb(46, 226, 226)
let fg        = isLight ? rgb(20, 32, 51)    : rgb(238, 243, 249)
let dim       = isLight ? rgb(94, 108, 128)  : rgb(166, 180, 197)
let gridInk   = isLight ? rgb(20, 32, 51, 0.05) : rgb(255, 255, 255, 0.05)

NSGradient(colors: [groundTop, groundBot])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// A faint terminal grid — the scales motif, at the threshold of visible.
cg.saveGState()
cg.setStrokeColor(gridInk.cgColor)
cg.setLineWidth(1)
var x = 0.0
while x <= W { cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: H)); x += 16 }
var y = 0.0
while y <= H { cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: W, y: y)); y += 32 }
cg.strokePath()
cg.restoreGState()

// A cyan glow behind the mascot.
cg.saveGState()
let glowStrength = isLight ? 0.10 : 0.18
NSGradient(colors: [cyan.withAlphaComponent(glowStrength), cyan.withAlphaComponent(0)])!
    .draw(in: NSRect(x: 40, y: 60, width: 520, height: 520), relativeCenterPosition: .zero)
cg.restoreGState()

let mascot = NSImage(contentsOfFile: "docs/brand/corta-pangolin-mascot.png")!
let side = 430.0
mascot.draw(in: NSRect(x: 96, y: (H - side) / 2, width: side, height: side),
            from: .zero, operation: .sourceOver, fraction: 1.0)

func draw(_ s: String, _ font: NSFont, _ color: NSColor, x: Double, y: Double, tracking: Double = 0) {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: tracking])
        .draw(at: NSPoint(x: x, y: y))
}

let left = 592.0
let title = NSFont.systemFont(ofSize: 108, weight: .bold)
draw("Corta", title, fg, x: left, y: 356, tracking: -3)

// The cursor block, sitting on the baseline after the wordmark.
let titleWidth = NSAttributedString(string: "Corta", attributes: [.font: title, .kern: -3]).size().width
cyan.setFill()
NSBezierPath(rect: NSRect(x: left + titleWidth + 16, y: 372, width: 30, height: 68)).fill()

draw("A native macOS terminal emulator,", .systemFont(ofSize: 30, weight: .medium), fg, x: left, y: 296)
draw("built from scratch in pure Swift.", .systemFont(ofSize: 30, weight: .medium), fg, x: left, y: 254)

let mono = NSFont.monospacedSystemFont(ofSize: 19, weight: .medium)
draw("Metal  ·  Core Text  ·  hand-written VT engine", mono, dim, x: left, y: 188, tracking: 0.5)
draw("zero dependencies", mono, cyan, x: left, y: 155, tracking: 0.5)

// A hairline rule under the type block, cyan fading out.
NSGradient(colors: [cyan.withAlphaComponent(0.9), cyan.withAlphaComponent(0)])!
    .draw(in: NSRect(x: left, y: 218, width: 470, height: 2), angle: 0)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(theme))")
