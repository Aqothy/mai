import Dispatch

/// The visible bands a frame cannot show without (`REDESIGN.md §7 R3`),
/// gathered while rows are placed and then drawn together on all cores
/// before the frame, as Chrome's raster workers draw the tiles a frame
/// activates with. One after another on the main thread they cost a
/// scrolled or resized frame the sum of their times.
@MainActor
final class FrameBandDraws {
    private var bands: [(band: RowBandLayer, generation: Int)] = []
    private var rasters: [BandRaster] = []

    func add(_ band: RowBandLayer, _ raster: BandRaster) {
        bands.append((band, band.generation))
        rasters.append(raster)
    }

    func draw() {
        guard !rasters.isEmpty else { return }
        var bitmaps = [BandBitmap?](repeating: nil, count: rasters.count)
        if rasters.count == 1 {
            bitmaps[0] = BandRasterizer.bitmap(rasters[0])
        } else {
            let rasters = rasters
            bitmaps.withUnsafeMutableBufferPointer { buffer in
                nonisolated(unsafe) let out = buffer
                DispatchQueue.concurrentPerform(iterations: rasters.count) { out[$0] = BandRasterizer.bitmap(rasters[$0]) }
            }
        }
        for (index, entry) in bands.enumerated() where entry.band.generation == entry.generation {
            entry.band.show(bitmaps[index], generation: entry.generation)
        }
        bands.removeAll(keepingCapacity: true)
        rasters.removeAll(keepingCapacity: true)
    }
}
