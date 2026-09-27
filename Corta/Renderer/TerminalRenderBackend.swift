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
import Metal

/// The GPU-encoding seam `TerminalRenderer` draws through. Everything
/// upstream (building `QuadInstance`s from a `Grid`) is backend-agnostic.
/// `QuadRenderer` conforms; `Metal4Backend` is a capability-gated second
/// conformance, selected in `TerminalRenderer.init`.
nonisolated protocol TerminalRenderBackend: AnyObject {
    var device: MTLDevice { get }

    /// Draws solid `instances` into `rect`, in target pixels.
    func drawSolidQuads(
        _ instances: [QuadInstance],
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    )

    func drawGlyphQuads(
        _ instances: [QuadInstance],
        atlas: MTLTexture,
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    )

    func drawColorQuads(
        _ instances: [QuadInstance],
        atlas: MTLTexture,
        rect: CGRect,
        drawableSize: CGSize,
        renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    )
}

nonisolated extension QuadRenderer: TerminalRenderBackend {}

/// Full-frame submission for Metal 4, which has no caller-owned
/// `MTLCommandBuffer` to hand down: the backend begins its own buffer from
/// an allocator and presents via `signalDrawable`. `beginFrame` opens the
/// buffer and pass (owning the clear), draws encode in MTL3's order, and
/// `endFrame` commits and presents. Driven by
/// `TerminalRenderer.draw(through:...)`, chosen by
/// `ViewController.render(into:...)` when the backend conforms.
nonisolated protocol Metal4FrameBackend: TerminalRenderBackend {
    /// Opens a frame, clearing on load like MTL3's first pass, so an empty
    /// frame still clears. `label` names the capture.
    func beginFrame(target: MTLTexture, clearColor: MTLClearColor, label: String)

    /// The `draw*Quads` trio without the Metal 3 parameters.
    func drawSolidQuads(_ instances: [QuadInstance], rect: CGRect, drawableSize: CGSize)
    func drawGlyphQuads(
        _ instances: [QuadInstance], atlas: MTLTexture, rect: CGRect, drawableSize: CGSize)
    func drawColorQuads(
        _ instances: [QuadInstance], atlas: MTLTexture, rect: CGRect, drawableSize: CGSize)

    /// Commits and presents `drawable` (nil offscreen). `onCompleted` runs
    /// after the GPU finishes, with the commit's error, so a fault surfaces.
    func endFrame(
        presenting drawable: (any MTLDrawable)?,
        onCompleted: (@Sendable ((any Error)?) -> Void)?)
}
