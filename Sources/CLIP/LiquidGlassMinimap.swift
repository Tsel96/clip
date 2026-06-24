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

    /// Canvas zoom mapped to 0…1 on a log scale across the practical
    /// zoom range. Drives the dial rotation and the map's zoom response.
    private var zoomT: Double {
        let z = Double(max(0.02, min(8, cameraStore.camera.zoom)))
        return (log(z) - log(0.02)) / (log(8) - log(0.02))
    }

    var body: some View {
        ZStack {
            dome
            // The dial: the dashed ring rotates with the canvas zoom
            // (a full revolution across the zoom range), sweeping under
            // the fixed needle like a lens' focus ring. Drawn AFTER the
            // dome so its wide soft shadow can't wash the ticks out.
            tickRing
                .rotationEffect(.radians(zoomT * 2 * .pi))
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
        MinimapView(inset: 6, showsViewport: false)
            .frame(width: diameter * 0.62, height: diameter * 0.54)
            // The map breathes with the canvas: zooming in scales the
            // cards up (bounded, so they stay under the glass — the
            // circle clip catches any overflow). Bigger base so the content
            // reads large in the dome (was 0.52×0.44 @ 0.8).
            .scaleEffect(1.0 + 0.5 * zoomT, anchor: .center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, diameter * 0.12)
            .padding(.top, diameter * 0.15)
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
    /// elsewhere. Lives in `MinimapGlassBase` — a view with NO camera/state
    /// input — so SwiftUI evaluates and lays out the AppKit-backed
    /// `.glassEffect` exactly once and never re-runs it as the camera moves.
    /// That's what keeps it live during pan without tripping the beta layout
    /// engine's depth-16 recursion guard (the old fix swapped it for a flat
    /// fill while `state.isCameraInteracting`).
    private var baseMaterial: some View {
        MinimapGlassBase()
    }

    private var dome: some View {
        ZStack {
            baseMaterial
                .allowsHitTesting(false)
            lensDotGrid
            minimapContent
        }
        // Pin the disc to its exact size — the glass circle must never
        // inflate to a sibling-derived union size.
        .frame(width: diameter, height: diameter)
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

    /// The zoom dial: a regular instrument ring floating OUTSIDE the disc
    /// with a clear offset. Evenly spaced ticks, every 6th one a longer
    /// major mark — no randomness, it's a functioning scale that rotates
    /// with the zoom.
    private var tickRing: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let baseRadius = diameter / 2 + 28
            let count = 72
            for i in 0..<count {
                let angle = Double(i) / Double(count) * 2 * .pi - .pi / 2
                let isMajor = i % 6 == 0
                let length: CGFloat = isMajor ? 16 : 9
                var path = Path()
                path.move(to: polar(center, angle: angle, radius: baseRadius))
                path.addLine(to: polar(center, angle: angle, radius: baseRadius + length))
                ctx.stroke(
                    path,
                    with: .color(.gray.opacity(isMajor ? 0.55 : 0.4)),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .butt)
                )
            }
        }
        .frame(width: diameter + 150, height: diameter + 150)
        .allowsHitTesting(false)
    }

    private func polar(_ c: CGPoint, angle: Double, radius: CGFloat) -> CGPoint {
        CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
    }

    // MARK: - Pointer triangle

    /// The dial's fixed needle: sits OUTSIDE the rotating tick ring at the
    /// up-left arc, apex pointing INWARD at the map — the ring sweeps
    /// beneath it as the zoom changes, like a lens' focus index mark.
    private var pointerTriangle: some View {
        let angle = -3 * Double.pi / 4
        let r = diameter / 2 + 58
        return PointerTriangle()
            .fill(Color.gray.opacity(0.8))
            .frame(width: 18, height: 15)
            // Base triangle points up; `angle - π/2` turns the apex
            // toward the dome's center.
            .rotationEffect(.radians(angle - .pi / 2))
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


/// The minimap's glass base, deliberately given NO camera/state input. Because
/// its value never changes, SwiftUI evaluates its body and lays out the
/// AppKit-backed `.glassEffect` exactly once — so panning/zooming the canvas
/// (which re-renders the surrounding minimap) never re-lays-out the glass, and
/// the depth-16 layout recursion that used to crash on pan can't trigger.
private struct MinimapGlassBase: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.clear, in: .circle)
        } else {
            // Pre-26 has no depth-16 guard — frosted material with a white lift.
            Circle()
                .fill(.ultraThinMaterial)
                .background(Circle().fill(Color.white.opacity(0.05)))
        }
    }
}
