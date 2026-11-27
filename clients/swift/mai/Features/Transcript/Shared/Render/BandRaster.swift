import CoreGraphics
import Foundation

/// Everything one band's bitmap is drawn from, as values: what a background
/// task needs and nothing that belongs to a layer.
nonisolated struct BandRaster: Sendable {
    let content: RowContentLayout
    let palette: TextPalette
    /// A wide block's body draws in its scroller, not in its row.
    let drawsWideBody: Bool
    /// The band in row coordinates.
    let rect: CGRect
    let scale: CGFloat
    /// The display's color space: a bitmap in any other is color-matched by
    /// Core Animation on the main thread, redrawn whole at commit.
    let colorSpace: CGColorSpace
}
