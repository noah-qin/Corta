/// The side table for Kitty graphics image placements (M10) — kept off
/// `Cell` for the same reason `HyperlinkTable` is a side table rather than a
/// cell field: a 16-byte cell has no spare bits left (`CLAUDE.md`: "anything
/// else that wants per-cell identity needs a side table keyed by position,
/// not a new field"), and an image placement spans many cells anyway, so a
/// per-cell reference would mean storing the same image reference thousands
/// of times over for one picture.
///
/// Placements are addressed by document row exactly like `TerminalSelection`
/// (`TerminalRenderer.swift`, `Selection.swift`): `row` is relative to
/// `baseScrollbackTotal`, shifted by the growth in `Scrollback.totalPushed`
/// since — computed at read time by whoever is walking placements against a
/// live grid (the renderer), the same way a selection's viewport row is.
///
/// **Reflow.** A column-count change drops every live placement rather than
/// attempting to re-wrap image geometry across it — `Grid.resize` calls
/// `removeAllPlacements()` when `columns` actually changes. A placement's
/// position is exact cell coordinates; an image surviving a reflow at the
/// wrong position is a worse outcome than the image disappearing and
/// needing re-placement, which every real client already re-does on a
/// resize since the pixel budget available to it just changed anyway. The
/// transmitted image *bytes* survive (`images` is untouched) — only where
/// to draw them is forgotten, so a client that re-sends just the placement
/// (`a=p`, no re-transmission) after a resize works without re-uploading.
public struct ImagePlacementTable: Sendable {
    private var images: [KittyGraphics.ImageID: KittyGraphics.ImageData] = [:]
    private var placements: [KittyGraphics.PlacementID: KittyGraphics.Placement] = [:]
    /// Placement order, oldest first — two placements at the same z-index
    /// draw in transmission order, the same tie-break every layered
    /// drawing model uses.
    private var placementOrder: [KittyGraphics.PlacementID] = []

    public init() {}

    public var placementCount: Int { placements.count }
    public var imageCount: Int { images.count }

    /// Records `data` under `id`, refusing a *new* id once
    /// `maximumTrackedImages` is already tracked (`SECURITY.md` §3) — a
    /// re-transmission of an id already known replaces it regardless, since
    /// that never grows the table.
    @discardableResult
    mutating func store(_ id: KittyGraphics.ImageID, data: KittyGraphics.ImageData) -> Bool {
        guard images[id] != nil || images.count < KittyGraphics.maximumTrackedImages else { return false }
        images[id] = data
        return true
    }

    /// Not `private`/internal: the app-layer renderer decodes and uploads
    /// this to a texture (`Corta/Renderer/KittyImageRenderer.swift`) — the
    /// core stores transmitted bytes, it does not decode PNG itself (no
    /// ImageIO dependency, `KittyGraphics.swift`'s doc comment).
    public func image(_ id: KittyGraphics.ImageID) -> KittyGraphics.ImageData? { images[id] }

    /// Records a placement of an already-`store`d image. Refuses an unknown
    /// image outright (nothing to place) and a *new* placement id once
    /// `maximumTrackedPlacements` is already live; replacing an existing
    /// placement id is always allowed, since that never grows the table.
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
        return true
    }

    mutating func delete(_ target: KittyGraphics.DeleteTarget) {
        switch target {
        case .all:
            images.removeAll()
            placements.removeAll()
            placementOrder.removeAll()
        case .image(let imageID):
            images[imageID] = nil
            removePlacements(matching: imageID)
        case .placement(let imageID, let placementID):
            if placements[placementID]?.imageID == imageID {
                placements[placementID] = nil
                placementOrder.removeAll { $0 == placementID }
            }
        case .unrecognised:
            break  // See `KittyGraphics.DeleteTarget`'s doc comment.
        }
    }

    private mutating func removePlacements(matching imageID: KittyGraphics.ImageID) {
        let toRemove = Set(placements.values.filter { $0.imageID == imageID }.map(\.id))
        guard !toRemove.isEmpty else { return }
        for id in toRemove { placements[id] = nil }
        placementOrder.removeAll { toRemove.contains($0) }
    }

    /// Every live placement, oldest first — what `TerminalRenderer` walks
    /// each frame to decide which viewport rows carry an image.
    public func orderedPlacements() -> [KittyGraphics.Placement] {
        placementOrder.compactMap { placements[$0] }
    }

    /// See the type's doc comment on reflow — called from `Grid.resize`
    /// only when `columns` actually changed.
    mutating func removeAllPlacements() {
        placements.removeAll()
        placementOrder.removeAll()
    }
}
