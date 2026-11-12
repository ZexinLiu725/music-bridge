import AppKit
import SwiftUI

/// Bounded pointer coordinates; surface layout no longer follows individual mouse events.
struct SurfacePointer: Equatable {
    var x: Double = 0
    var y: Double = 0

    static func normalized(location: CGPoint, size: CGSize) -> SurfacePointer {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite,
              location.x.isFinite, location.y.isFinite else { return SurfacePointer() }
        return SurfacePointer(x: min(1, max(-1, Double(location.x / size.width * 2 - 1))),
                              y: min(1, max(-1, Double(location.y / size.height * 2 - 1))))
    }

    func offset(hovered: Bool, reducedMotion: Bool, active: Bool, editing: Bool) -> CGSize {
        guard hovered, !reducedMotion, active, !editing else { return .zero }
        return CGSize(width: x * 1.4, height: -2.2 + y * 0.7)
    }
}

/// Light, opaque, shared colors in the shape of the calm desktop apps:
/// a pale gray canvas, white cards, white inputs. Nothing translucent
/// ever sits under text.
enum SurfacePalette {
    static let windowNSColor = NSColor(srgbRed: 242/255, green: 242/255, blue: 244/255, alpha: 1)
    static let window = Color(nsColor: windowNSColor)
    static let card = Color(red: 255/255, green: 255/255, blue: 255/255)
    static let input = Color(red: 255/255, green: 255/255, blue: 255/255)
}

struct WindowBackdrop: View {
    var body: some View { SurfacePalette.window.allowsHitTesting(false) }
}

private final class SurfaceState: ObservableObject {
    @Published var hovered = false
}

/// Only hover entry/exit changes the border. No per-mouse-event layout, tilt,
/// compositor blur layers, or continuously restarted spring animations.
private struct FloatingSurface: ViewModifier {
    var editing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorSchemeContrast) private var contrast
    @StateObject private var state = SurfaceState()

    private var highlighted: Bool { state.hovered && activeState != .inactive && !editing }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        content
            .background(SurfacePalette.card, in: shape)
            .overlay {
                shape.strokeBorder(Color.black.opacity(contrast == .increased ? 0.4 : highlighted ? 0.14 : 0.07), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: highlighted)
            .onHover { hovered in
                if state.hovered != hovered { state.hovered = hovered }
            }
            .onChange(of: activeState) { _, value in
                if value == .inactive { state.hovered = false }
            }
            .onDisappear { state.hovered = false }
    }
}

extension View {
    func floatingSurface(editing: Bool = false) -> some View { modifier(FloatingSurface(editing: editing)) }
}
