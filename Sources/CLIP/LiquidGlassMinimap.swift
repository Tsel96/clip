import SwiftUI

/// "Liquid Glass" minimap dome, after the landing-page lens artwork.
///
/// Composition (see CanvasView for the mounts):
///
///   • `LiquidGlassMinimap` — a massive glass circle anchored bottom-right
///     whose center is pushed past the window corner, so only its top-left
///     quadrant sweeps across the screen (viewport bleed). Inside the
///     clipped disc: the live `MinimapView` (dot grid + node cards +
///     viewport box), positioned in the visible quadrant. On top: the
///     volumetric dome — rim highlight, grounding inner shadow, and
///     chromatic edge fringing. On macOS 26+ the base material is the
///     system's clear Liquid Glass (true refraction); earlier systems get
///     `.ultraThinMaterial` with a white lift.
///
///   • `MinimapControlPill` — the dark frosted zoom pill, centered against
///     the SCREEN (not the off-center dome), floating over the glass edge.
struct LiquidGlassMinimap: View {
    @EnvironmentObject var state: CanvasState
    /// Observed for the pointer triangle — its angle derives from the camera.
    @EnvironmentObject var cameraStore: CameraStore

    /// Dome diameter. Deliberately large — part of it bleeds off-screen.
    private let diameter: CGFloat = 520
    /// How far the dome's frame is pushed past the bottom-right corner.
    private var bleed: CGFloat { diameter * 0.30 }

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
    /// Geometry keeps the whole content rect inside both the circle and
    /// the on-screen region: with a bleed of 0.30·D the visible square is
    /// 0.70·D, and the rect below stays within the circle's radius.
    private var minimapContent: some View {
        MinimapView(inset: 22)
            .frame(width: diameter * 0.46, height: diameter * 0.38)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, diameter * 0.14)
            .padding(.top, diameter * 0.18)
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
        // Chromatic aberration — prismatic fringing hugging the extreme
        // outer edge. Three offset stroked circles, clipped so the fringe
        // stays in the outer few percent of the radius; with the dome
        // shifted bottom-right these read along the sweeping top-left arc.
        .overlay {
            ZStack {
                Circle()
                    .stroke(Color.cyan, lineWidth: 10)
                    .offset(x: -4, y: -4)
                    .opacity(0.4)
                    .blur(radius: 4)
                    .blendMode(.screen)
                Circle()
                    .stroke(Color(red: 1.0, green: 0.2, blue: 0.45), lineWidth: 10)
                    .offset(x: 4, y: 4)
                    .opacity(0.3)
                    .blur(radius: 5)
                    .blendMode(.screen)
                Circle()
                    .stroke(Color.yellow, lineWidth: 8)
                    .offset(y: -3)
                    .opacity(0.2)
                    .blur(radius: 3)
            }
            // Keep the fringe in the outer ~7% of the radius (a stroked-
            // border ring as the mask — macOS 13-safe, unlike shape
            // boolean ops).
            .mask {
                Circle().strokeBorder(Color.white, lineWidth: diameter * 0.07)
            }
            .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.25), radius: 40, x: -8, y: -8)
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
                let length = 6 + f1 * 12
                let r0 = baseRadius + f2 * 7
                var path = Path()
                path.move(to: polar(center, angle: angle, radius: r0))
                path.addLine(to: polar(center, angle: angle, radius: r0 + length))
                ctx.stroke(
                    path,
                    with: .color(.gray.opacity(0.35 + f3 * 0.4)),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .butt)
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

    /// World-space vector from the board's content to the viewport. Drives
    /// the compass triangle on the rim: when the user pans far from their
    /// cards it points the way out; panned home, it fades away.
    private var viewportOffsetFromContent: CGSize? {
        guard !state.nodes.isEmpty else { return nil }
        var minX = CGFloat.greatestFiniteMagnitude, minY = minX
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = maxX
        for n in state.nodes {
            minX = min(minX, n.position.x)
            minY = min(minY, n.position.y)
            maxX = max(maxX, n.position.x + n.width)
            maxY = max(maxY, n.position.y + (n.height ?? 200))
        }
        let content = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let vp = state.visibleWorldRect
        return CGSize(width: vp.midX - content.x, height: vp.midY - content.y)
    }

    @ViewBuilder
    private var pointerTriangle: some View {
        if let off = viewportOffsetFromContent {
            let distance = hypot(off.width, off.height)
            let vp = state.visibleWorldRect
            // Live as soon as the viewport centre drifts meaningfully from
            // the content — a direction cue, not a lost-at-sea alarm.
            let visible = distance > max(vp.width, vp.height) * 0.08
            let angle = atan2(off.height, off.width)
            let r = diameter / 2 + 30

            PointerTriangle()
                .fill(Color.gray.opacity(0.85))
                .frame(width: 16, height: 14)
                .rotationEffect(.radians(angle + .pi / 2))
                .offset(x: cos(angle) * r, y: sin(angle) * r)
                .opacity(visible ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: visible)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Layer 3: the floating control pill

/// Dark frosted zoom pill — centered against the screen near its bottom
/// edge, floating over the dome's glass arc. Mounted separately from the
/// dome (see CanvasView) precisely so it centers on the window, not on
/// the off-center circle.
struct MinimapControlPill: View {
    @EnvironmentObject var state: CanvasState

    var body: some View {
        HStack(spacing: 0) {
            pillButton(systemName: "minus.magnifyingglass", help: "Zoom out") {
                state.zoomOut()
            }
            divider
            Button {
                state.zoomToFit()
            } label: {
                FitCornersGlyph()
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 16, height: 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            .help("Zoom to fit")
            divider
            pillButton(systemName: "plus.magnifyingglass", help: "Zoom in") {
                state.zoomIn()
            }
        }
        .frame(width: 160, height: 48)
        .background(Color.black.opacity(0.3))
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .clipShape(Capsule(style: .continuous))
        // Fine edge lighting along the capsule rim.
        .overlay(
            Capsule(style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.4), .clear, .white.opacity(0.1)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
        )
        .shadow(color: .black.opacity(0.25), radius: 15, x: 0, y: 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 24)
    }

    private func pillButton(
        systemName: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .help(help)
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

/// "Re-center / fit" glyph: two opposing corner brackets implying a frame,
/// matching the reference pill's centre icon.
private struct FitCornersGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = rect.width * 0.45
        var p = Path()
        // Top-right corner bracket.
        p.move(to: CGPoint(x: rect.maxX - arm, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + arm))
        // Bottom-left corner bracket.
        p.move(to: CGPoint(x: rect.minX + arm, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - arm))
        return p
    }
}
