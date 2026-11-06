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

// Renders dedicated silent interaction demos from the isolated app-only recording.
// swiftc -O scripts/brand/render-interaction-demo.swift -o /tmp/render-demo
// /tmp/render-demo source.mp4 window-buttons.png <website|gif-frames|poster> output
// gif-frames writes 150 raw RGBA frames, each 960 × 588; encode with
// node website/scripts/encode-interaction-gif.mjs frames.rgba output.gif

import AVFoundation
import AppKit
import CoreImage

// Input is an isolated, public-content Corta window recording. No desktop access.
// Usage: render-interaction-demo <source.mp4> <window-buttons.png> <website|gif-frames|poster> <output>
let args = CommandLine.arguments
if args.count != 5 { fatalError("Expected source.mp4, window-buttons.png, mode and output") }
let mode = args[3]
let canvasWidth = mode == "gif-frames" ? 960 : 1600
let canvasHeight = mode == "gif-frames" ? 588 : 980
let fps = mode == "gif-frames" ? 15 : 60
let duration = mode == "gif-frames" ? 10.0 : 12.0
let outURL = URL(fileURLWithPath: args[4])
let imageContext = CIContext(options: [.cacheIntermediates: false])
final class Source {
  let reader: AVAssetReader, output: AVAssetReaderTrackOutput
  var next: CMSampleBuffer?, current: CGImage?
  init(_ path: String) throws {
    let a = AVURLAsset(url: URL(fileURLWithPath: path))
    reader = try AVAssetReader(asset: a)
    output = AVAssetReaderTrackOutput(
      track: a.tracks(withMediaType: .video).first!,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    reader.startReading()
    next = output.copyNextSampleBuffer()
  }
  func image(_ time: Double) -> CGImage {
    while let sample = next,
      CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) <= time || current == nil
    {
      if let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
        let i = CIImage(cvPixelBuffer: pixelBuffer)
        current = imageContext.createCGImage(i, from: i.extent)!
      }
      next = output.copyNextSampleBuffer()
    }
    return current!
  }
}
let source = try Source(args[1])
let initial = source.image(1.6667)
let patch = NSImage(contentsOfFile: args[2])!.cgImage(
  forProposedRect: nil, context: nil, hints: nil)!.cropping(
    to: CGRect(x: 0, y: 0, width: 162, height: 76))!
let background = NSColor(calibratedRed: 0.955, green: 0.963, blue: 0.972, alpha: 1)
func rect(_ x: Double, _ top: Double, _ w: Double, _ h: Double) -> CGRect {
  CGRect(x: x, y: Double(canvasHeight) - top - h, width: w, height: h)
}
func drawWindow(_ frame: CGImage, _ canvas: CGContext) {
  let cut = frame.cropping(to: CGRect(x: 180, y: 120, width: 2158, height: 1260))!
  let width = Double(canvasWidth) * 0.91
  let height = width * 1260 / 2158
  let x = (Double(canvasWidth) - width) / 2
  let top = (Double(canvasHeight) - height) / 2
  let r = rect(x, top, width, height).insetBy(dx: 8 * width / 2158, dy: 8 * width / 2158)
  let path = CGPath(
    roundedRect: r, cornerWidth: 54 * width / 2158, cornerHeight: 54 * width / 2158, transform: nil)
  canvas.saveGState()
  canvas.setShadow(
    offset: CGSize(width: 0, height: -Double(canvasWidth) * 0.007),
    blur: Double(canvasWidth) * 0.022,
    color: NSColor.black.withAlphaComponent(0.14).cgColor)
  canvas.setFillColor(NSColor.white.cgColor)
  canvas.addPath(path)
  canvas.fillPath()
  canvas.restoreGState()
  canvas.saveGState()
  canvas.addPath(path)
  canvas.clip()
  canvas.draw(cut, in: rect(x, top, width, height))
  canvas.draw(patch, in: rect(x, top, 162 * width / 2158, 76 * width / 2158))
  canvas.restoreGState()
}
func drawPair(_ frame: CGImage, _ canvas: CGContext) {
  let scale = Double(canvasWidth) / 2560
  let top = (Double(canvasHeight) - 1600 * scale) / 2
  let regions = [
    CGRect(x: 60, y: 80, width: 1718, height: 1032),
    CGRect(x: 740, y: 520, width: 1718, height: 1032),
  ]
  let path = CGMutablePath()
  for r in regions {
    let insetRegion = r.insetBy(dx: 8, dy: 8)
    path.addRoundedRect(
      in: rect(
        insetRegion.minX * scale, top + insetRegion.minY * scale, insetRegion.width * scale,
        insetRegion.height * scale),
      cornerWidth: 54 * scale, cornerHeight: 54 * scale)
  }
  canvas.saveGState()
  canvas.setShadow(
    offset: CGSize(width: 0, height: -8 * scale), blur: 36 * scale,
    color: NSColor.black.withAlphaComponent(0.14).cgColor)
  canvas.setFillColor(NSColor.white.cgColor)
  canvas.addPath(path)
  canvas.fillPath()
  canvas.restoreGState()
  canvas.saveGState()
  canvas.addPath(path)
  canvas.clip()
  canvas.draw(frame, in: rect(0, top, Double(canvasWidth), 1600 * scale))
  for r in regions {
    canvas.draw(patch, in: rect(r.minX * scale, top + r.minY * scale, 162 * scale, 76 * scale))
  }
  canvas.restoreGState()
}
func sourceTime(_ time: Double) -> Double {
  if time < 1.2 { return 1.6667 + time }
  if time < 3 { return 3.9167 + time - 1.2 }
  if time < 4 { return 6.3667 + (time - 3) * 1.61664 }
  if time < 4.5 { return 7.98334 + (time - 4) * 0.6 }
  if time < 5 { return 10.48334 + time - 4.5 }
  if time < 5.5 { return 10.9833 + (time - 5) * 2 }
  if time < 6 { return 11.98334 + time - 5.5 }
  if time < 6.5 { return 12.4833 + (time - 6) * 1.8668 }
  if time < 7 { return 13.4167 + time - 6.5 }
  if time < 8 { return 15.35 + (time - 7) * 1.25 }
  return 16.6 + min(0.7, (time - 8) * 0.7)
}
func draw(_ canvas: CGContext, _ time: Double) {
  canvas.setFillColor(background.cgColor)
  canvas.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
  if mode == "poster" {
    drawWindow(source.image(5.8), canvas)
    return
  }
  if mode == "gif-frames" {
    let frame = source.image(sourceTime(min(time, 8.5)))
    drawWindow(frame, canvas)
    if time >= 8.5 {
      let progress = min(1, (time - 8.5) / 0.8)
      canvas.saveGState()
      canvas.setAlpha(progress)
      canvas.setFillColor(background.cgColor)
      canvas.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
      drawWindow(initial, canvas)
      canvas.restoreGState()
    }
  } else {
    if time < 8.5 {
      drawWindow(source.image(sourceTime(time)), canvas)
    } else {
      drawPair(source.image(25), canvas)
    }
    if time >= 10.5 {
      let progress = min(1, (time - 10.5) / 0.8)
      canvas.saveGState()
      canvas.setAlpha(progress)
      canvas.setFillColor(background.cgColor)
      canvas.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
      drawWindow(initial, canvas)
      canvas.restoreGState()
    }
  }
}
func context(_ pointer: UnsafeMutableRawPointer?, _ stride: Int) -> CGContext {
  CGContext(
    data: pointer, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8,
    bytesPerRow: stride,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
if mode == "poster" {
  let canvas = context(nil, canvasWidth * 4)
  draw(canvas, 0)
  try NSBitmapImageRep(cgImage: canvas.makeImage()!).representation(using: .png, properties: [:])!
    .write(
      to: outURL)
} else if mode == "gif-frames" {
  FileManager.default.createFile(atPath: outURL.path, contents: nil)
  let output = try FileHandle(forWritingTo: outURL)
  defer { try? output.close() }
  for n in 0..<Int(duration * Double(fps)) {
    try autoreleasepool {
      var data = Data(count: canvasWidth * canvasHeight * 4)
      data.withUnsafeMutableBytes { ptr in
        draw(context(ptr.baseAddress, canvasWidth * 4), Double(n) / Double(fps))
      }
      try output.write(contentsOf: data)
    }
  }
} else if mode == "website" {
  try? FileManager.default.removeItem(at: outURL)
  let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: canvasWidth,
      AVVideoHeightKey: canvasHeight,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 4_000_000, AVVideoExpectedSourceFrameRateKey: fps,
        AVVideoMaxKeyFrameIntervalKey: fps * 2,
      ],
    ])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
      kCVPixelBufferWidthKey as String: canvasWidth,
      kCVPixelBufferHeightKey as String: canvasHeight,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ])
  writer.add(input)
  writer.startWriting()
  writer.startSession(atSourceTime: .zero)
  for n in 0..<Int(duration * Double(fps)) {
    autoreleasepool {
      while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.004) }
      var pixelBuffer: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
      CVPixelBufferLockBaseAddress(pixelBuffer!, [])
      let canvas = CGContext(
        data: CVPixelBufferGetBaseAddress(pixelBuffer!), width: canvasWidth, height: canvasHeight,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer!),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
      draw(canvas, Double(n) / Double(fps))
      CVPixelBufferUnlockBaseAddress(pixelBuffer!, [])
      precondition(
        adaptor.append(
          pixelBuffer!, withPresentationTime: CMTime(value: Int64(n), timescale: Int32(fps))),
        "Video encoding failed")
    }
  }
  input.markAsFinished()
  let done = DispatchGroup()
  done.enter()
  writer.finishWriting { done.leave() }
  done.wait()
  guard writer.status == .completed else { throw writer.error! }
} else {
  fatalError("Unknown mode")
}
print("Created", mode, outURL.path)
