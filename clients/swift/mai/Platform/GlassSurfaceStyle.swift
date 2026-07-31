import SwiftUI

/// Liquid Glass on OS versions that support it, falling back to a material
/// fill with a hairline stroke (and an optional shadow) on earlier systems.
struct GlassSurfaceStyle<SurfaceShape: Shape>: ViewModifier {
    let shape: SurfaceShape
    var isShadowed = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            let surface = content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.stroke(.quaternary, lineWidth: 1)
                }
            if isShadowed {
                surface.shadow(color: .black.opacity(0.12), radius: 24, y: 12)
            } else {
                surface
            }
        }
    }
}

extension View {
    func glassSurface(in shape: some Shape, isShadowed: Bool = false) -> some View {
        modifier(GlassSurfaceStyle(shape: shape, isShadowed: isShadowed))
    }
}
