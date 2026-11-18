import QuartzCore

/// One horizontal slice of a row, at most `RowLayer.bandHeight` tall: a tall
/// row never draws its whole height at once, and its bitmap is only as big
/// as the slice (PLAN 4.3). Its bitmap is drawn off the main thread
/// (`RasterQueue`) and assigned here; changing what the slice should show
/// keeps the old bitmap on screen until the new one lands.
nonisolated final class RowBandLayer: CALayer {
    /// Bumped by every change to what the slice should show; a bitmap made
    /// for an older generation is dropped.
    private(set) var generation = 0
    /// The generation of the bitmap shown, nil when none is.
    private(set) var shownGeneration: Int?
    /// The generation a queued or running job draws.
    var pendingGeneration: Int?
    /// Bitmaps made before this generation belong to content the band no
    /// longer shows (released or reused).
    private var oldestWanted = 0
    /// Glyph rects (band coordinates) to fade in once a bitmap of their
    /// generation or later lands.
    private var queuedFades: [(generation: Int, rect: CGRect)] = []
    /// The fades running: when each started and its pieces in the mask.
    private var fades: [(start: CFTimeInterval, pieces: [CALayer])] = []
    /// The mask while fades run: an even-odd shape, opaque but for the
    /// fading rects, and a piece filling each rect whose opacity animates
    /// from 0 to 1 in the render server.
    private var fadeMask: CALayer?
    private let fadeSolid = CAShapeLayer()
    static let fadeDuration: CFTimeInterval = 0.12
    private var isFadeCleanupScheduled = false

    /// Whether the bitmap shown is the current one.
    var isCurrent: Bool { shownGeneration == generation }
    var isPending: Bool { pendingGeneration == generation }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = false
        isOpaque = false
        // A bitmap from before a width change stays unscaled, pinned to the
        // row's top left, until the new one lands.
        contentsGravity = .topLeft
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

    /// A fade mask covers the old bounds only and would hide the rest:
    /// it follows the new ones.
    @MainActor
    func resize(to frame: CGRect) {
        self.frame = frame
        if fadeMask != nil { updateFadeMask() }
    }

    /// Whether a bitmap of `generation` moves the band forward: newer than
    /// what it shows, even if no longer current. While a stream changes a
    /// band every frame its jobs finish already outdated; showing each one
    /// keeps the text moving instead of waiting for a pause.
    func wants(_ generation: Int) -> Bool {
        generation >= oldestWanted && shownGeneration.map { generation > $0 } ?? true
    }

    @MainActor
    func show(_ bitmap: BandBitmap?, generation: Int) {
        contents = bitmap?.surface
        shownGeneration = generation
        if pendingGeneration == generation { pendingGeneration = nil }
        if queuedFades.contains(where: { $0.generation <= generation }) { startFade(upTo: generation) }
    }

    /// Streamed text in `rects` fades in once the bitmap that has it lands
    /// (PLAN 6.6).
    func fadeIn(_ rects: [CGRect]) {
        guard !isCurrent else { return }
        queuedFades += rects.map { (generation, $0) }
    }

    /// Drops the bitmap (memory: far from the viewport, or reused).
    @MainActor
    func release() {
        contents = nil
        shownGeneration = nil
        pendingGeneration = nil
        generation &+= 1
        oldestWanted = generation
        queuedFades.removeAll()
        endFades()
    }

    /// Adds the rects queued up to `shown` to the mask as pieces fading in
    /// from now.
    @MainActor
    private func startFade(upTo shown: Int) {
        let mask = fadeMask ?? makeFadeMask()
        let now = CACurrentMediaTime()
        let black = CGColor(gray: 0, alpha: 1)
        var pieces: [CALayer] = []
        for (fadeGeneration, rect) in queuedFades where fadeGeneration <= shown {
            let piece = CALayer()
            piece.frame = rect
            piece.backgroundColor = black
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0
            animation.toValue = 1
            animation.beginTime = now
            animation.duration = Self.fadeDuration
            animation.fillMode = .backwards
            piece.add(animation, forKey: "reveal")
            mask.addSublayer(piece)
            pieces.append(piece)
        }
        queuedFades.removeAll { $0.generation <= shown }
        fades.append((now, pieces))
        updateFadeMask()
        scheduleFadeCleanup(after: Self.fadeDuration)
    }

    @MainActor
    private func makeFadeMask() -> CALayer {
        // Reused while fades run: its changes must not animate.
        let still: [String: any CAAction] = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        let container = CALayer()
        container.actions = still
        fadeSolid.actions = still
        fadeSolid.fillRule = .evenOdd
        fadeSolid.fillColor = CGColor(gray: 0, alpha: 1)
        container.addSublayer(fadeSolid)
        fadeMask = container
        mask = container
        return container
    }

    /// Drops ended fades' pieces and cuts holes for the running ones.
    @MainActor
    private func updateFadeMask() {
        let now = CACurrentMediaTime()
        while let first = fades.first, now - first.start >= Self.fadeDuration {
            for piece in first.pieces { piece.removeFromSuperlayer() }
            fades.removeFirst()
        }
        guard !fades.isEmpty, let fadeMask else {
            endFades()
            return
        }
        fadeMask.frame = bounds
        fadeSolid.frame = bounds
        let path = CGMutablePath()
        path.addRect(bounds)
        for fade in fades { path.addRects(fade.pieces.map(\.frame)) }
        fadeSolid.path = path
    }

    @MainActor
    private func endFades() {
        fades.removeAll()
        fadeMask = nil
        fadeSolid.removeFromSuperlayer()
        mask = nil
    }

    /// One cleanup at a time, at the end of the oldest running fade.
    @MainActor
    private func scheduleFadeCleanup(after delay: CFTimeInterval) {
        guard !isFadeCleanupScheduled else { return }
        isFadeCleanupScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.02))
            guard let self else { return }
            self.isFadeCleanupScheduled = false
            self.updateFadeMask()
            if let first = self.fades.first {
                self.scheduleFadeCleanup(after: max(0, first.start + Self.fadeDuration - CACurrentMediaTime()))
            }
        }
    }
}
