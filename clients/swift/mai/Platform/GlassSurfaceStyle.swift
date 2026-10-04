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

/// Circular icon buttons: the system glass style where available. Earlier
/// systems get the same footprint on the material surface, since a bare
/// material circle would hug the icon.
struct GlassCircleButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .buttonBorderShape(.circle)
                .buttonStyle(.glass)
        } else {
            content.buttonStyle(MaterialCircleButtonStyle())
        }
    }
}

private struct MaterialCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Matches the glass style's 7-point inset around a 24-point icon.
            .padding(7)
            .glassSurface(in: .circle, isShadowed: true)
            .contentShape(.circle)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension View {
    func glassCircleButton() -> some View {
        modifier(GlassCircleButtonStyle())
    }
}
