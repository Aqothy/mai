import CoreGraphics
import CoreText
import Foundation
import IOSurface
import Testing

@testable import mai

/// PLAN 3.5: a band drawn off the main thread (`BandRasterizer`, glyph runs
/// with `CTFontDrawGlyphs`) must look like Core Text drawing the line itself
/// (`CTLineDraw`), color emoji included; otherwise raster tasks would have to
/// re-run the layout.
struct TextRendererParityTests {
    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func pixels(_ context: CGContext) -> [UInt8] {
        guard let data = context.data else { return [] }
        let count = context.bytesPerRow * context.height
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count))
    }

    @Test(arguments: ["Plain prose, café, and «quotes» — 123", "Emoji 👩🏽‍💻 🎉 and flags 🇨🇦 in a line"])
    func glyphRunsDrawLikeTheirLine(text: String) throws {
        let font = CTFontCreateUIFontForLanguage(.system, 15, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 15, nil)
        var styled = StyledText()
        styled.paragraphs = [StyledParagraph(start: 0, firstLineIndent: 0, headIndent: 0, spacingBefore: 0, quoteBars: [])]
        styled.append(text, font: TranscriptFont(font: font), style: TextRunStyle())
        let layout = TextLayoutEngine.layout(styled, width: 2_000, options: .init(lineSpacing: 0))
        let line = try #require(layout.lines.first)
        let scale = 2
        let (width, height) = (Int(ceil(layout.size.width) + 8) * scale, Int(ceil(line.height) + 8) * scale)
        let palette = TextPalette.resolveForTests

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmap = try #require(
            BandRasterizer.bitmap(
                BandRaster(
                    content: .text(layout, origin: CGPoint(x: 4, y: 4)), palette: palette, drawsWideBody: true,
                    rect: CGRect(x: 0, y: 0, width: CGFloat(width / scale), height: CGFloat(height / scale)),
                    scale: CGFloat(scale), colorSpace: sRGB)))
        let surface = bitmap.surface
        surface.lock(options: .readOnly, seed: nil)
        let band = try #require(
            CGContext(
                data: surface.baseAddress, width: surface.width, height: surface.height, bitsPerComponent: 8,
                bytesPerRow: surface.bytesPerRow, space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )?.makeImage())
        surface.unlock(options: .readOnly, seed: nil)
        let ours = try #require(Self.context(width: width, height: height))
        ours.draw(band, in: CGRect(x: 0, y: 0, width: width, height: height))

        let reference = try #require(Self.context(width: width, height: height))
        reference.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        reference.setFillColor(palette.primary)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        // Same baseline, bottom-up: Core Text's own coordinate system.
        reference.textPosition = CGPoint(x: 4, y: CGFloat(height / scale) - 4 - line.baseline)
        CTLineDraw(ctLine, reference)

        let a = Self.pixels(ours)
        let b = Self.pixels(reference)
        #expect(a.count == b.count)
        let differing = zip(a, b).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 24 ? 1 : 0) }
        #expect(Double(differing) / Double(max(1, a.count)) < 0.002, "\(differing) of \(a.count) bytes differ")
        #expect(a.contains { $0 != 0 })
    }
}

extension TextPalette {
    /// Fixed colors, so tests don't depend on the system appearance.
    static var resolveForTests: TextPalette {
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        return TextPalette(
            primary: black, secondary: black, tertiary: black, separator: black, inlineCodeBackground: black,
            codeBackground: black, codeBorder: black, bubble: black, warning: black, error: black, selection: black,
            inactiveSelection: black, isDark: false)
    }
}
