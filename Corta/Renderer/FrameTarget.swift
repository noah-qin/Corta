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

/// Where one frame lands: the texture, the grid's rectangle inside it, the
/// drawable's size the rectangle is measured against, and the colour the
/// pass clears to.
public nonisolated struct FrameTarget {
    public var texture: MTLTexture
    public var rect: CGRect
    public var drawableSize: CGSize
    public var clearColor: MTLClearColor

    public init(texture: MTLTexture, rect: CGRect, drawableSize: CGSize, clearColor: MTLClearColor) {
        self.texture = texture
        self.rect = rect
        self.drawableSize = drawableSize
        self.clearColor = clearColor
    }
}
