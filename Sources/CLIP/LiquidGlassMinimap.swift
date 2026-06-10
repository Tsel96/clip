import SwiftUI

/// "Liquid Glass" minimap dome, after the landing-page lens artwork:
/// a large glass circle anchored bottom-right whose center is pushed past
/// the window corner, so only its top-left quadrant sweeps across the
/// screen (viewport bleed). Inside the clipped disc: the live
/// `MinimapView` (dot grid + node cards + viewport box), positioned in
/// the visible quadrant. On top: the volumetric dome — rim highlight,
/// grounding inner shadow, and a subtle chromatic smear on the top arc.
/// Around it: the tick dial and the static rim compass triangle. On
/// macOS 26+ the base material is the system's clear Liquid Glass (true
/// refraction); earlier systems get `.ultraThinMaterial` with a white
/// lift. Mounted in `CanvasView`.
struct LiquidGlassMinimap: View {
    @EnvironmentObject var state: CanvasState
    /// Observed for the pointer triangle — its angle derives from the camera.
    @EnvironmentObject var cameraStore: CameraStore

    /// Dome diameter. Part of it bleeds off-screen.
    private let diameter: CGFloat = 360
    /// How far the dome's frame is pushed past the bottom-right corner.
    private var bleed: CGFloat { diameter * 0.28 }

    var body: some View {
        ZStack {
            dome
            // Ticks + pointer AFTER the dome so the dome's wide soft
            // shadow can't wash them out.
            tickRing
            pointerTriangle
        }
        .frame(width: diameter, height: diameter)
        // Push the center toward (and past) the bottom-right corner so
        // only the top-left quadrant of the circle stays on screen.
        .offset(x: bleed, y: bleed)
    }

    // MARK: - Layer 1: clipped canvas content

    /// The live minimap, placed in the dome's visible (top-left) quadrant.
    /// Content-only projection (no viewport box) so the cards read large —
    /// real thumbnails scattered over the lens, like the reference.
    /// Geometry keeps the block inside both the circle and the on-screen
    /// region (worst corner ≈ 0.474·D from center, radius 0.5·D).
    private var minimapContent: some View {
        MinimapView(inset: 8, showsViewport: false)
            .frame(width: diameter * 0.52, height: diameter * 0.44)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, diameter * 0.15)
            .padding(.top, diameter * 0.18)
    }

    /// One uniform screen-space dot grid across the whole disc — the
    /// reference shows the canvas grid sweeping the full lens, not a
    /// fenced map block.
    private var lensDotGrid: some View {
        Canvas { ctx, size in
            let step: CGFloat = 22
            var x = step / 2
            while x < size.width {
                var y = step / 2
                while y < size.height {
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)),
                        with: .color(.gray.opacity(0.28))
                    )
                    y += step
                }
                x += step
            }
        }
        .allowsHitTesting(false)
    }

    /// Base material under the canvas content. Real clear Liquid Glass on
    /// macOS 26+ (refracts the canvas behind the dome); frosted fallback
    /// with a slight white lift elsewhere.
    @ViewBuilder
    private var baseMaterial: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.clear, in: .circle)
        } else {
            Circle()
                .fill(.ultraThinMaterial)
                .background(Circle().fill(Color.white.opacity(0.05)))
        }
    }

    private var dome: some View {
        ZStack {
            baseMaterial
                .allowsHitTesting(false)
            lensDotGrid
            minimapContent
        }
        .clipShape(Circle())
        // ----- Layer 2: the volumetric glass dome -----
        // Bright rim highlight — thick liquid-light reflection along the
        // top-left edge of the visible curve.
        .overlay {
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.9), .white.opacity(0.1), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 6
                )
                .blur(radius: 1)
                .allowsHitTesting(false)
        }
        // Grounding inner shadow — gives the dome spherical volume.
        .overlay {
            Circle()
                .fill(Color.clear)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.15), lineWidth: 8)
                        .blur(radius: 10)
                        .offset(x: -5, y: 5)
                )
                .clipShape(Circle())
                .allowsHitTesting(false)
        }
        // Chromatic fringe — a barely-there prismatic smear confined to a
        // short stretch of the top arc, like the reference. (Offset glow
        // rings read as a pink halo — wrong.)
        .overlay {
            Circle()
                .strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: .clear,               location: 0.00),
                            .init(color: .clear,               location: 0.60),
                            .init(color: .cyan.opacity(0.45),  location: 0.66),
                            .init(color: .yellow.opacity(0.45), location: 0.71),
                            .init(color: .pink.opacity(0.45),  location: 0.76),
                            .init(color: .clear,               location: 0.82),
                            .init(color: .clear,               location: 1.00)
                        ],
                        center: .center,
                        angle: .degrees(0)
                    ),
                    lineWidth: 3
                )
                .blur(radius: 2)
                .opacity(0.55)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.18), radius: 32, x: -6, y: -6)
    }

    // MARK: - Dial ticks

    /// Irregular tick marks ringing the dome — varying lengths, radial
    /// jitter, and gaps, all from a deterministic hash so the ring is
    /// static frame-to-frame. Only the arc near the visible quadrant
    /// matters; the rest is clipped with the bleed.
    private var tickRing: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let baseRadius = diameter / 2 + 14
            let count = 80
            for i in 0..<count {
                // Reference ring has gaps — drop ~30% of positions.
                guard hash(i, salt: 4) > 0.3 else { continue }
                let angle = Double(i) / Double(count) * 2 * .pi - .pi / 2
                let f1 = hash(i, salt: 1)        // length
                let f2 = hash(i, salt: 2)        // radial jitter
                let f3 = hash(i, salt: 3)        // opacity
                let length = 6 + f1 * 11
                let r0 = baseRadius + f2 * 7
                var path = Path()
                path.move(to: polar(center, angle: angle, radius: r0))
                path.addLine(to: polar(center, angle: angle, radius: r0 + length))
                ctx.stroke(
                    path,
                    with: .color(.gray.opacity(0.30 + f3 * 0.35)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .butt)
                )
            }
        }
        .frame(width: diameter + 80, height: diameter + 80)
        .allowsHitTesting(false)
    }

    private func hash(_ i: Int, salt: Int) -> Double {
        let x = sin(Double(i * 127 + salt * 311) * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }

    private func polar(_ c: CGPoint, angle: Double, radius: CGFloat) -> CGPoint {
        CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
    }

    // MARK: - Pointer triangle

    /// Static compass triangle just outside the rim's up-left arc, apex
    /// pointing up-left exactly as in the reference artwork.
    private var pointerTriangle: some View {
        let angle = -3 * Double.pi / 4
        let r = diameter / 2 + 24
        return PointerTriangle()
            .fill(Color.gray.opacity(0.8))
            .frame(width: 19, height: 16)
            .rotationEffect(.radians(angle + .pi / 2))
            .offset(x: cos(angle) * r, y: sin(angle) * r)
            .allowsHitTesting(false)
    }
}

/// Upward-pointing triangle for the rim compass.
private struct PointerTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

