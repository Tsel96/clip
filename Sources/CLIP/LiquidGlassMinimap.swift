import SwiftUI

/// Circular Liquid Glass minimap pinned to the canvas's bottom-right
/// corner, after the landing-page lens artwork:
///
///   • a clear glass disc that refracts the canvas behind it, with the
///     system's bright rim and specular highlights
///   • a dial of irregular tick marks ringing the lens
///   • a small triangle just outside the rim that points from the board's
///     content toward the viewport when the user has panned away
///   • a glass zoom pill (zoom out · fit · zoom in) resting near the
///     lens's bottom edge
///
/// On macOS 26+ the disc and pill use the real `glassEffect` material
/// (shared `GlassEffectContainer` so the overlapping glasses sample
/// correctly). Earlier systems get a hand-built material approximation.
/// The lens content is the existing `MinimapView` (dot grid + node rects +
/// viewport box), so click-to-jump / drag-to-pan keep working inside the
/// circle.
struct LiquidGlassMinimap: View {
    @EnvironmentObject var state: CanvasState
    /// Observed for the pointer triangle — its angle derives from the camera.
    @EnvironmentObject var cameraStore: CameraStore

    /// Lens diameter. The dial ticks and pointer live in the extra apron
    /// around it (see `apron`).
    private let diameter: CGFloat = 230
    /// Extra room around the lens for the tick ring + pointer triangle.
    private let apron: CGFloat = 32

    private var clusterSide: CGFloat { diameter + apron * 2 }

    var body: some View {
        if #available(macOS 26.0, *) {
            // Shared sampling region — glass can't sample other glass, so
            // the pill overlapping the lens needs a common container.
            GlassEffectContainer {
                cluster
            }
        } else {
            cluster
        }
    }

    private var cluster: some View {
        ZStack {
            tickRing
            lens
            pointerTriangle
        }
        .frame(width: clusterSide, height: clusterSide)
        // The pill rests just inside the lens's bottom rim, like the
        // reference.
        .overlay(alignment: .bottom) {
            zoomPill.offset(y: -(apron + 14))
        }
    }

    // MARK: - Lens

    /// Minimap content sized + clipped to the disc.
    private var lensContent: some View {
        MinimapView(inset: 30)
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
    }

    @ViewBuilder
    private var lens: some View {
        if #available(macOS 26.0, *) {
            // The real thing: clear Liquid Glass refracts the canvas
            // behind the disc; the system draws rim, specular and shadow.
            lensContent
                .glassEffect(.clear, in: .circle)
        } else {
            lensContent
                .background { fallbackGlass }
                .overlay { fallbackRim }
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.13), radius: 26, y: 12)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        }
    }

    /// Pre-Tahoe approximation: frosted base with a slight white lift so
    /// the disc reads as glass on dark canvases too.
    private var fallbackGlass: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(Color.white.opacity(0.07))
            // Top-left specular sheen — the "light hits the glass" wash.
            Circle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.30), location: 0.0),
                            .init(color: .white.opacity(0.07), location: 0.35),
                            .init(color: .clear,               location: 0.6)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        }
        .allowsHitTesting(false)
    }

    /// Pre-Tahoe rim: thick refracting edge band + chromatic smear +
    /// bright rim line.
    private var fallbackRim: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.45), lineWidth: 16)
                .blur(radius: 10)
            Circle()
                .strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: .clear,               location: 0.00),
                            .init(color: .clear,               location: 0.55),
                            .init(color: .cyan.opacity(0.5),   location: 0.62),
                            .init(color: .yellow.opacity(0.5), location: 0.68),
                            .init(color: .pink.opacity(0.5),   location: 0.74),
                            .init(color: .clear,               location: 0.82),
                            .init(color: .clear,               location: 1.00)
                        ],
                        center: .center,
                        angle: .degrees(0)
                    ),
                    lineWidth: 3
                )
                .blur(radius: 2.5)
                .opacity(0.6)
            Circle()
                .strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: .white.opacity(0.9),  location: 0.00),
                            .init(color: .white.opacity(0.2),  location: 0.25),
                            .init(color: .white.opacity(0.7),  location: 0.50),
                            .init(color: .white.opacity(0.2),  location: 0.75),
                            .init(color: .white.opacity(0.9),  location: 1.00)
                        ],
                        center: .center,
                        angle: .degrees(-60)
                    ),
                    lineWidth: 1.5
                )
        }
        .allowsHitTesting(false)
    }

    // MARK: - Dial ticks

    /// Irregular tick marks ringing the lens, like the reference dial:
    /// varying lengths, radial jitter, and gaps. All randomness comes from
    /// a deterministic hash of the tick index, so the ring is static
    /// frame-to-frame.
    private var tickRing: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let baseRadius = diameter / 2 + 12
            let count = 64
            for i in 0..<count {
                // Reference ring has gaps — drop ~30% of positions.
                guard hash(i, salt: 4) > 0.3 else { continue }
                let angle = Double(i) / Double(count) * 2 * .pi - .pi / 2
                let f1 = hash(i, salt: 1)        // length
                let f2 = hash(i, salt: 2)        // radial jitter
                let f3 = hash(i, salt: 3)        // opacity
                let length = 4 + f1 * 9
                let r0 = baseRadius + f2 * 5
                var path = Path()
                path.move(to: polar(center, angle: angle, radius: r0))
                path.addLine(to: polar(center, angle: angle, radius: r0 + length))
                ctx.stroke(
                    path,
                    with: .color(.primary.opacity(0.12 + f3 * 0.35)),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .butt)
                )
            }
        }
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
    /// the compass triangle: when the user pans far from their cards, the
    /// triangle appears on the rim pointing the way out — panned home,
    /// it fades away.
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
            // Visible once the viewport centre has wandered more than half
            // a screen away from the content.
            let visible = distance > max(vp.width, vp.height) * 0.5
            let angle = atan2(off.height, off.width)
            let r = diameter / 2 + 24

            PointerTriangle()
                .fill(Color.gray.opacity(0.85))
                .frame(width: 15, height: 13)
                .rotationEffect(.radians(angle + .pi / 2))
                .offset(x: cos(angle) * r, y: sin(angle) * r)
                .opacity(visible ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: visible)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Zoom pill

    private var pillButtons: some View {
        HStack(spacing: 0) {
            pillButton(systemName: "minus.magnifyingglass", help: "Zoom out") {
                state.zoomOut()
            }
            pillDivider
            Button {
                state.zoomToFit()
            } label: {
                FitCornersGlyph()
                    .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(.secondary)
                    .frame(width: 13, height: 13)
                    .frame(width: 50, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            .help("Zoom to fit")
            pillDivider
            pillButton(systemName: "plus.magnifyingglass", help: "Zoom in") {
                state.zoomIn()
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var zoomPill: some View {
        if #available(macOS 26.0, *) {
            pillButtons
                .glassEffect(.regular, in: .capsule)
        } else {
            pillButtons
                .background {
                    ZStack {
                        Capsule(style: .continuous).fill(.regularMaterial)
                        Capsule(style: .continuous).fill(Color.primary.opacity(0.05))
                    }
                }
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.45), .white.opacity(0.08)],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                )
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        }
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 16)
    }

    private func pillButton(
        systemName: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 50, height: 38)
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

/// "Zoom to fit" glyph: two opposing corner brackets implying a frame,
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
