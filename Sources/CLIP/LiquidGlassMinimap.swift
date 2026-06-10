import SwiftUI

/// Circular "liquid glass" minimap pinned to the canvas's bottom-right
/// corner. Visual spec (from the landing-page lens artwork):
///
///   • a frosted glass disc with a bright refractive rim, a soft top-left
///     specular sheen, and a faint chromatic smear near the top edge
///   • a dial of irregular tick marks ringing the lens
///   • a small triangle just outside the rim that points from the board's
///     content toward the viewport when the user has panned away
///   • a translucent zoom pill (zoom out · fit · zoom in) straddling the
///     lens's bottom edge
///
/// The lens content is the existing `MinimapView` (dot grid + node rects +
/// viewport box), so click-to-jump / drag-to-pan keep working inside the
/// circle. Built from materials + gradients so it renders on macOS 13+;
/// the rim layers approximate the system Liquid Glass look.
struct LiquidGlassMinimap: View {
    @EnvironmentObject var state: CanvasState
    /// Observed for the pointer triangle — its angle derives from the camera.
    @EnvironmentObject var cameraStore: CameraStore

    /// Lens diameter. The dial ticks and pointer live in the extra apron
    /// around it (see `apron`).
    private let diameter: CGFloat = 196
    /// Extra room around the lens for the tick ring + pointer triangle.
    private let apron: CGFloat = 30

    private var clusterSide: CGFloat { diameter + apron * 2 }

    var body: some View {
        ZStack {
            tickRing
            lens
            pointerTriangle
        }
        .frame(width: clusterSide, height: clusterSide)
        // The pill straddles the lens's bottom rim, like the reference.
        .overlay(alignment: .bottom) {
            zoomPill.offset(y: -apron + 16)
        }
        // TEMPORARY diagnostic while verifying on a real machine — shows
        // up in `swift run`'s terminal output. Remove once confirmed.
        .onAppear { print("🗺️ LiquidGlassMinimap mounted") }
    }

    // MARK: - Lens

    private var lens: some View {
        ZStack {
            // Frosted base.
            Circle().fill(.ultraThinMaterial)

            MinimapView(inset: 30)
                .clipShape(Circle())

            // Top-left specular sheen — the "light hits the glass" wash.
            Circle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.28), location: 0.0),
                            .init(color: .white.opacity(0.06), location: 0.35),
                            .init(color: .clear,               location: 0.6)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .allowsHitTesting(false)

            // Thick soft inner band — the refracting glass edge.
            Circle()
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 10)
                .blur(radius: 7)
                .allowsHitTesting(false)

            // Faint chromatic smear near the top edge (the rainbow the
            // reference lens shows where light splits at the rim).
            Circle()
                .strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: .clear,                location: 0.00),
                            .init(color: .clear,                location: 0.55),
                            .init(color: .cyan.opacity(0.5),    location: 0.62),
                            .init(color: .yellow.opacity(0.5),  location: 0.68),
                            .init(color: .pink.opacity(0.5),    location: 0.74),
                            .init(color: .clear,                location: 0.82),
                            .init(color: .clear,                location: 1.00)
                        ],
                        center: .center,
                        angle: .degrees(0)
                    ),
                    lineWidth: 3
                )
                .blur(radius: 2.5)
                .opacity(0.6)
                .allowsHitTesting(false)

            // Bright rim highlight, strongest top-left / bottom-right.
            Circle()
                .strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: .white.opacity(0.9),  location: 0.00),
                            .init(color: .white.opacity(0.15), location: 0.25),
                            .init(color: .white.opacity(0.7),  location: 0.50),
                            .init(color: .white.opacity(0.15), location: 0.75),
                            .init(color: .white.opacity(0.9),  location: 1.00)
                        ],
                        center: .center,
                        angle: .degrees(-60)
                    ),
                    lineWidth: 1.5
                )
                .allowsHitTesting(false)

            // Hairline definition against busy canvases.
            Circle()
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .clipShape(Circle())
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.13), radius: 26, y: 12)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    // MARK: - Dial ticks

    /// Irregular tick marks ringing the lens, like the reference dial.
    /// Lengths / radial jitter / opacity come from a deterministic hash of
    /// the tick index, so the ring is static frame-to-frame.
    private var tickRing: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let baseRadius = diameter / 2 + 9
            let count = 72
            for i in 0..<count {
                let angle = Double(i) / Double(count) * 2 * .pi - .pi / 2
                let f1 = hash(i, salt: 1)        // length
                let f2 = hash(i, salt: 2)        // radial jitter
                let f3 = hash(i, salt: 3)        // opacity
                let length = 3 + f1 * 7
                let r0 = baseRadius + f2 * 5
                var path = Path()
                path.move(to: polar(center, angle: angle, radius: r0))
                path.addLine(to: polar(center, angle: angle, radius: r0 + length))
                ctx.stroke(
                    path,
                    with: .color(.primary.opacity(0.10 + f3 * 0.32)),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .butt)
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
    /// triangle appears on the rim pointing the way back out — panned home,
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
            let r = diameter / 2 + 21

            PointerTriangle()
                .fill(Color.gray.opacity(0.85))
                .frame(width: 14, height: 12)
                .rotationEffect(.radians(angle + .pi / 2))
                .offset(x: cos(angle) * r, y: sin(angle) * r)
                .opacity(visible ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: visible)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Zoom pill

    private var zoomPill: some View {
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
                    .frame(width: 42, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hover)
            .help("Zoom to fit")
            pillDivider
            pillButton(systemName: "plus.magnifyingglass", help: "Zoom in") {
                state.zoomIn()
            }
        }
        .padding(.horizontal, 6)
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
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 36)
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
