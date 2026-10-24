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

import AppKit
import CortaTerminal
import Testing
@testable import Corta

@MainActor
struct AgentTabViewTests {
    @Test func completedIdleAndUnknownHaveDifferentIndicators() throws {
        func image(_ state: ProgramStatus.State) throws -> NSBitmapImageRep {
            let view = AgentTabView(frame: NSRect(x: 0, y: 0, width: 32, height: 28))
            view.status = ProgramStatus(state: state)
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: 32, pixelsHigh: 28, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 128, bitsPerPixel: 32))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.clear.setFill()
            view.bounds.fill(using: .copy)
            view.draw(view.bounds)
            return bitmap
        }
        let done = try #require(image(.done).colorAt(x: 16, y: 14)?.usingColorSpace(.deviceRGB))
        let idle = try #require(image(.idle).colorAt(x: 16, y: 14)?.usingColorSpace(.deviceRGB))
        #expect(done.greenComponent > done.redComponent + 0.2)
        #expect(abs(idle.greenComponent - idle.redComponent) < 0.1)
        #expect(idle.alphaComponent > 0.1)
        let unknown = try image(.unknown)
        #expect(unknown.colorAt(x: 16, y: 14)?.alphaComponent == 0)
        #expect((unknown.colorAt(x: 18, y: 14)?.alphaComponent ?? 0) > 0.1)
    }

    @Test func dotAndProgressStayCenteredWhenNativeTabResizesAccessory() throws {
        for progress in [false, true] {
            let width = 32, height = 28
            let view = AgentTabView(frame: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            view.status = ProgramStatus(state: .idle, color: "#0000ff")
            if progress { view.progress = ProgramProgress(state: .normal, value: 100) }
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4, bitsPerPixel: 32))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.clear.setFill()
            view.bounds.fill(using: .copy)
            view.draw(view.bounds)
            var xs: [Int] = [], ys: [Int] = []
            for y in 0..<height {
                for x in 0..<width {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.blueComponent > 0.8, color.alphaComponent > 0.8 {
                        xs.append(x); ys.append(y)
                    }
                }
            }
            let left = try #require(xs.min()), right = try #require(xs.max())
            let bottom = try #require(ys.min()), top = try #require(ys.max())
            #expect(abs(Double(left + right + 1) / 2 - Double(width) / 2) <= 0.5)
            #expect(abs(Double(bottom + top + 1) / 2 - Double(height) / 2) <= 0.5)
        }
    }
}
