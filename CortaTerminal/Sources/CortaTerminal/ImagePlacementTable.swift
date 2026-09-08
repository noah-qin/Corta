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
    /// Total encoded bytes of every image in `images`, kept against
    /// `maximumStoredBytes` (S02). Instance state, not a global: the table
    /// is a value type copied into the renderer's frame cache, so anything
    /// shared across copies would break that snapshot's isolation.
    private var storedImageBytes = 0
    /// A `var` defaulting to the protocol-sized constant so tests can
    /// exercise the budget without transmitting hundreds of megabytes.
    var maximumStoredBytes = KittyGraphics.maximumPaneImageBytes

    /// Per-image counter, bumped on every successful `store` of the id and
    /// dropped on delete. The renderer's texture cache compares it
    /// (`KittyImageRenderer`, P05) to tell "same id, new transmission" from
    /// "same image" without hashing payloads: a reused id must invalidate
    /// the texture decoded from the old bytes.
    private var storeGenerations: [KittyGraphics.ImageID: UInt64] = [:]
    private var storeGenerationCounter: UInt64 = 0

    /// Bumped on any mutation of images or placements. An image delete
    /// changes no cell, so the renderer's line-granular damage tracking
    /// alone would never notice one — this is the cheap "the image layer
    /// changed" signal `TerminalRenderer.updateInstances` compares (P05).
    public private(set) var revision: UInt64 = 0

    public init() {}

    public var placementCount: Int { placements.count }
    public var imageCount: Int { images.count }

    /// The generation of the bytes currently stored under `id`
    /// (`storeGenerations`), or nil if the id is unknown.
    public func storeGeneration(for id: KittyGraphics.ImageID) -> UInt64? {
        storeGenerations[id]
    }

    /// Why a transmission was refused. Surfaced to the child as the Kitty
    /// protocol's error string, so each case maps to one distinct message —
    /// "no space" and "malformed" are different diagnoses to a client.
    enum StoreRefusal {
        /// Raw dimensions past `maximumImageDimension`/`maximumImagePixels`.
        case dimensionsExceedCaps
        /// A new id while `maximumTrackedImages` are already tracked.
        case tooManyImages
        /// The pane's stored encoded bytes would cross `maximumStoredBytes`.
        case byteBudgetExceeded
    }

    /// Records `data` under `id`, refusing a *new* id once
    /// `maximumTrackedImages` is already tracked (`SECURITY.md` §3) — a
    /// re-transmission of an id already known replaces it regardless, since
    /// that never grows the table. Also refuses (S02):
    /// - a raw-format image whose declared dimensions exceed
    ///   `maximumImageDimension`/`maximumImagePixels` — defence in depth,
    ///   since the parser already clamps `s=`/`v=` and the performer
    ///   already requires the byte count to match the declared size
    ///   exactly. PNG dimensions live inside the payload and are checked
    ///   by the app layer before it decodes (no ImageIO here).
    /// - any transmission that would push the pane's stored encoded bytes
    ///   past `maximumStoredBytes`. A replacement is judged by the *net*
    ///   change, so re-transmitting an id at the same size always fits.
    ///
    /// Returns nil on success, or the refusal reason.
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
        revision &+= 1
        return true
    }

    mutating func delete(_ target: KittyGraphics.DeleteTarget) {
        switch target {
        case .all:
            images.removeAll()
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
        revision &+= 1
    }
}
