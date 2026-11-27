import CoreGraphics
import Foundation
import IOSurface

/// Draws a band of a row into a bitmap on any thread (PLAN 4.3): an
/// `IOSurface` of the band's pixel size, written through a bitmap context,
/// top-down, the row's painter clipped to the band. Core Text and Core
/// Graphics are safe off the main thread with one context per task; the
/// main thread only assigns the result to the band's layer.
nonisolated enum BandRasterizer {
    /// 'BGRA': premultiplied BGRA, Core Animation's native layout.
    private static let pixelFormat: UInt32 = 0x4247_5241

    static func bitmap(_ raster: BandRaster) -> BandBitmap? {
        let width = Int((raster.rect.width * raster.scale).rounded(.up))
        let height = Int((raster.rect.height * raster.scale).rounded(.up))
        guard width > 0, height > 0,
            let surface = IOSurface(properties: [
                .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: pixelFormat,
                .bytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4),
            ])
        else { return nil }
        // Tagged, so a color space other than the display's is matched by
        // the GPU when composited, never on the main thread.
        if let space = raster.colorSpace.copyPropertyList() {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, space)
        }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard
            let context = CGContext(
                data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: surface.bytesPerRow, space: raster.colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Fresh `IOSurface` allocations are VM zero-filled by XNU; skipping
        // `CGContextClearRect` avoids faulting and zeroing untouched pages
        // (measured: 39% of worker raster CPU on iPhone 14).
        context.scaleBy(x: raster.scale, y: raster.scale)
        // Top-down, as the layout's coordinates are, from the bitmap's top
        // (its pixel height is rounded up).
        context.translateBy(x: 0, y: CGFloat(height) / raster.scale)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.translateBy(x: -raster.rect.minX, y: -raster.rect.minY)
        RowPainter.draw(
            raster.content, clip: raster.rect, palette: raster.palette, drawsWideBody: raster.drawsWideBody,
            in: context)
        context.flush()
        return BandBitmap(surface: surface)
    }
}
