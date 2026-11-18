import Foundation
import IOSurface

/// A band's finished bitmap: an `IOSurface`, the memory Core Animation's
/// render server reads directly, so assigning it as a layer's contents
/// copies nothing at commit (a `CGImage` is copied there, ~1 ms per band;
/// `CALayer.contents` takes "typically a CGImageRef or an IOSurfaceRef").
/// Immutable once drawn: safe to hand across threads.
nonisolated struct BandBitmap: @unchecked Sendable {
    let surface: IOSurface
}
