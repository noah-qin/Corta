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

/// Kitty graphics placements, off `Cell`: a cell has no spare bits (D05), and
/// one picture would repeat its reference across thousands of cells. Rows
/// are relative to `baseScrollbackTotal`, like a selection.
///
/// A column change drops every placement (`Grid.resize`) rather than
/// re-wrapping image geometry — a misplaced image is worse than a missing
/// one, and clients re-place on resize anyway. The bytes survive, so a bare
/// `a=p` re-places without re-uploading — until the display is next erased,
/// which frees every image no placement shows, as kitty does.
public struct ImagePlacementTable: Sendable {
    private var images: [KittyGraphics.ImageID: KittyGraphics.ImageData] = [:]
    private var placements: [KittyGraphics.PlacementID: KittyGraphics.Placement] = [:]
    /// Oldest first: equal z-indices draw in transmission order.
    private var placementOrder: [KittyGraphics.PlacementID] = []
    /// Per instance: the table is copied into the renderer's frame cache.
    private var storedImageBytes = 0
    /// A `var` so tests need not send hundreds of megabytes.
    var maximumStoredBytes = KittyGraphics.maximumPaneImageBytes

    /// Bumped per `store`, so the texture cache tells "reused id, new bytes"
    /// from "same image" without hashing.
    private var storeGenerations: [KittyGraphics.ImageID: UInt64] = [:]
    private var storeGenerationCounter: UInt64 = 0

    /// Images sent with no `i=`, oldest first; ids may already be gone.
    private var anonymousOrder: [KittyGraphics.ImageID] = []
    /// Counts down from the top of the id space, where clients — which
    /// number from 1 — do not reach.
    private var nextAnonymousID = UInt32.max

    /// An image delete changes no cell, so line damage alone would miss it.
    public private(set) var revision: UInt64 = 0

    public init() {}

    public var placementCount: Int { placements.count }
    public var imageCount: Int { images.count }

    public func storeGeneration(for id: KittyGraphics.ImageID) -> UInt64? {
        storeGenerations[id]
    }

    /// Each case is a distinct protocol error for the client.
    enum StoreRefusal {
        case dimensionsExceedCaps
        case tooManyImages
        case byteBudgetExceeded
    }

    /// Refuses a new id past `maximumTrackedImages` (a known id always
    /// replaces), raw dimensions over the caps (defence in depth; PNG is checked
    /// by the app before decoding), and bytes over `maximumStoredBytes` — by net
    /// change, so a same-size re-transmission always fits. `nil` on success.
    @discardableResult
    mutating func store(_ id: KittyGraphics.ImageID, data: KittyGraphics.ImageData) -> StoreRefusal? {
        if data.format != .png, data.width > 0, data.height > 0 {
            guard data.width <= KittyGraphics.maximumImageDimension,
                data.height <= KittyGraphics.maximumImageDimension,
                data.width <= KittyGraphics.maximumImagePixels / data.height
            else { return .dimensionsExceedCaps }
        }
        guard images[id] != nil || images.count < KittyGraphics.maximumTrackedImages
        else { return .tooManyImages }
        let replacedBytes = images[id]?.bytes.count ?? 0
        let newTotal = storedImageBytes - replacedBytes + data.bytes.count
        guard newTotal <= maximumStoredBytes else { return .byteBudgetExceeded }
        storedImageBytes = newTotal
        images[id] = data
        storeGenerationCounter &+= 1
        storeGenerations[id] = storeGenerationCounter
        revision &+= 1
        return nil
    }

    /// An image sent with no `i=` — `kitten icat`'s every image. kitty keeps
    /// each as its own image that nothing can refer to again; stored under
    /// the one id 0, each replaced the last, and so took the previous
    /// picture off the screen. Past the image cap or the byte budget, the
    /// oldest anonymous images give way — kitty's quota evicts oldest first
    /// too — so a session of `icat` after `icat` is never refused.
    mutating func storeAnonymous(
        _ data: KittyGraphics.ImageData
    ) -> (id: KittyGraphics.ImageID, refusal: StoreRefusal?) {
        anonymousOrder.removeAll { images[$0] == nil }
        while !anonymousOrder.isEmpty,
            images.count >= KittyGraphics.maximumTrackedImages
                || storedImageBytes + data.bytes.count > maximumStoredBytes
        {
            delete(.image(anonymousOrder.removeFirst()))
        }
        var id = KittyGraphics.ImageID(rawValue: nextAnonymousID)
        while images[id] != nil || id.rawValue == 0 {
            id.rawValue &-= 1
        }
        nextAnonymousID = id.rawValue &- 1
        if let refusal = store(id, data: data) { return (id, refusal) }
        anonymousOrder.append(id)
        return (id, nil)
    }

    /// Public: the app decodes it; the core has no ImageIO.
    public func image(_ id: KittyGraphics.ImageID) -> KittyGraphics.ImageData? { images[id] }

    /// Refuses an unknown image, and a new placement id past the cap.
    @discardableResult
    mutating func place(
        _ header: KittyGraphics.DisplayHeader, row: Int, column: Int, baseScrollbackTotal: Int
    ) -> Bool {
        guard images[header.imageID] != nil else { return false }
        guard placements[header.placementID] != nil
            || placements.count < KittyGraphics.maximumTrackedPlacements
        else { return false }
        if placements[header.placementID] == nil {
            placementOrder.append(header.placementID)
        }
        placements[header.placementID] = KittyGraphics.Placement(
            id: header.placementID, imageID: header.imageID, row: row, column: column,
            columns: header.columns, rows: header.rows, baseScrollbackTotal: baseScrollbackTotal,
            zIndex: header.zIndex)
        revision &+= 1
        return true
    }

    mutating func delete(_ target: KittyGraphics.DeleteTarget) {
        switch target {
        case .all:
            images.removeAll()
            anonymousOrder.removeAll()
            storeGenerations.removeAll()
            storedImageBytes = 0
            placements.removeAll()
            placementOrder.removeAll()
        case .image(let imageID):
            if let removed = images.removeValue(forKey: imageID) {
                storedImageBytes -= removed.bytes.count
            }
            storeGenerations[imageID] = nil
            removePlacements(matching: imageID)
        case .placement(let imageID, let placementID):
            if placements[placementID]?.imageID == imageID {
                placements[placementID] = nil
                placementOrder.removeAll { $0 == placementID }
            }
        case .unrecognised:
            break  // See `KittyGraphics.DeleteTarget`'s doc comment.
        }
        revision &+= 1
    }

    private mutating func removePlacements(matching imageID: KittyGraphics.ImageID) {
        let toRemove = Set(placements.values.filter { $0.imageID == imageID }.map(\.id))
        guard !toRemove.isEmpty else { return }
        for id in toRemove { placements[id] = nil }
        placementOrder.removeAll { toRemove.contains($0) }
    }

    public func orderedPlacements() -> [KittyGraphics.Placement] {
        placementOrder.compactMap { placements[$0] }
    }

    /// `ED 2`: deletes every placement that reaches the visible screen —
    /// kitty's `grman_clear` rule, `start_row + rows > 0` — and keeps the
    /// ones wholly in scrollback. Then, as kitty's `filter_refs` does with
    /// `free_images`, frees every image left with no placement, including
    /// one transmitted with `a=t` and never placed. A placement's rows
    /// are `r=`, else its pixel height over `cellPixelHeight`; unknown, one
    /// anchored on screen goes and one anchored in history stays.
    mutating func removePlacementsReachingScreen(scrollbackTotal: Int, cellPixelHeight: Int) {
        let toRemove = placements.values.filter { placement in
            let top = ScrollbackCoordinates.reanchoredRow(
                placement.row, from: placement.baseScrollbackTotal, to: scrollbackTotal)
            if top >= 0 { return true }
            guard let rows = rowCount(of: placement, cellPixelHeight: cellPixelHeight) else {
                return false
            }
            return top + rows > 0
        }.map(\.id)
        remove(Set(toRemove))
        freeUnplacedImages()
    }

    /// `ED 3` and Clear History: deletes the placements wholly in the
    /// scrollback being discarded, and keeps every one that still reaches the
    /// screen — the screen's text stays, so the part of an image drawn among
    /// it stays too (its rows are counted from `totalPushed`, which discarding
    /// history does not reset). Anchored in history with no known height, it
    /// goes: there is no telling it reaches the screen. Images left with no
    /// placement are freed, as for `ED 2`.
    mutating func removePlacementsWhollyInScrollback(scrollbackTotal: Int, cellPixelHeight: Int) {
        let toRemove = placements.values.filter { placement in
            let top = ScrollbackCoordinates.reanchoredRow(
                placement.row, from: placement.baseScrollbackTotal, to: scrollbackTotal)
            guard top < 0 else { return false }
            guard let rows = rowCount(of: placement, cellPixelHeight: cellPixelHeight) else {
                return true
            }
            return top + rows <= 0
        }.map(\.id)
        remove(Set(toRemove))
        freeUnplacedImages()
    }

    /// Frees the bytes of every image no placement shows. Kept, a session that
    /// runs `kitten icat` and `clear` in turn would fill the byte budget with
    /// pictures nothing can see and refuse the next one.
    private mutating func freeUnplacedImages() {
        let placed = Set(placements.values.map(\.imageID))
        let unplaced = images.keys.filter { !placed.contains($0) }
        guard !unplaced.isEmpty else { return }
        for id in unplaced {
            if let removed = images.removeValue(forKey: id) {
                storedImageBytes -= removed.bytes.count
            }
            storeGenerations[id] = nil
        }
        revision &+= 1
    }

    private func rowCount(of placement: KittyGraphics.Placement, cellPixelHeight: Int) -> Int? {
        if let rows = placement.rows { return rows }
        guard cellPixelHeight > 0, let height = images[placement.imageID]?.pixelHeight else {
            return nil
        }
        return max(1, (height + cellPixelHeight - 1) / cellPixelHeight)
    }

    private mutating func remove(_ ids: Set<KittyGraphics.PlacementID>) {
        guard !ids.isEmpty else { return }
        for id in ids { placements[id] = nil }
        placementOrder.removeAll { ids.contains($0) }
        revision &+= 1
    }

    mutating func removeAllPlacements() {
        placements.removeAll()
        placementOrder.removeAll()
        revision &+= 1
    }
}
