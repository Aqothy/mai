import QuartzCore

/// One horizontal slice of a row, at most `RowLayer.bandHeight` tall: a tall
/// row never draws its whole height at once, and its bitmap is only as big
/// as the slice (PLAN 4.3). Its bitmap is drawn off the main thread
/// (`RasterQueue`) and assigned here; changing what the slice should show
/// keeps the old bitmap on screen until the new one lands.
nonisolated final class RowBandLayer: CALayer {
    /// Bumped by every change to what the slice should show; bitmaps carry
    /// the generation they were drawn for (`wants`).
    private(set) var generation = 0
    /// The generation of the bitmap shown, nil when none is.
    private(set) var shownGeneration: Int?
    /// The generation a queued or running job draws.
    var pendingGeneration: Int?
    /// Bitmaps made before this generation belong to content the band no
    /// longer shows (released or reused).
    private var oldestWanted = 0

    /// Whether the bitmap shown is the current one.
    var isCurrent: Bool { shownGeneration == generation }
    var isPending: Bool { pendingGeneration == generation }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = false
        isOpaque = false
        // An older bitmap (another width, or a layout landing with a new
        // height) stays unscaled at the slice's visual top left until the
        // new one lands, clipped to the slice so it never spills over the row
        // below. Gravity is in the layer's own coordinates: rows sit in a
        // flipped container on the Mac, where "bottom" is the visual top.
        #if os(macOS)
            contentsGravity = .bottomLeft
        #else
            contentsGravity = .topLeft
        #endif
        masksToBounds = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func action(forKey event: String) -> (any CAAction)? { nil }

    /// What the slice shows changed; its current bitmap stays until the new
    /// one is shown.
    func invalidate() {
        generation &+= 1
    }

    /// Whether a bitmap of `generation` moves the band forward: newer than
    /// what it shows, even if no longer current. While a live resize changes
    /// a band every frame its jobs finish already outdated; showing each one
    /// keeps the text reflowing instead of waiting for the resize to end.
    func wants(_ generation: Int) -> Bool {
        generation >= oldestWanted && shownGeneration.map { generation > $0 } ?? true
    }

    @MainActor
    func show(_ bitmap: BandBitmap?, generation: Int) {
        contents = bitmap?.surface
        shownGeneration = generation
        if pendingGeneration == generation { pendingGeneration = nil }
    }

    /// Drops the bitmap (memory: far from the viewport, or reused).
    @MainActor
    func release() {
        contents = nil
        shownGeneration = nil
        pendingGeneration = nil
        generation &+= 1
        oldestWanted = generation
    }
}
