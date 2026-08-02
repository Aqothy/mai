import SwiftUI

/// Liquid Glass on OS versions that support it, falling back to a material
/// fill with a hairline stroke (and an optional shadow) on earlier systems.
struct GlassSurfaceStyle<SurfaceShape: Shape>: ViewModifier {
    let shape: SurfaceShape
    var isShadowed = false

    /// `isShadowed` is intentionally ignored on the glassEffect branch: glass
    /// supplies its own depth.
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.stroke(.quaternary, lineWidth: 1)
                }
                .shadow(
                    color: .black.opacity(isShadowed ? 0.12 : 0),
                    radius: isShadowed ? 24 : 0,
                    y: isShadowed ? 12 : 0
                )
        }
    }
}

extension View {
    func glassSurface(in shape: some Shape, isShadowed: Bool = false) -> some View {
        modifier(GlassSurfaceStyle(shape: shape, isShadowed: isShadowed))
    }
}
