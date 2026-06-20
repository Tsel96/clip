import SwiftUI

/// Renders all committed connectors plus the live drag-to-connect preview.
///
/// Routing matches FigJam: each connector exits/enters on the side of its
/// node closest to the other node, then takes a Z-shaped path with rounded
/// right-angle bends. Drawing is done in **screen** coordinates so the line
/// thickness, corner radius and arrowhead size stay constant at any zoom.
struct ConnectorsLayer: View {
    /// When true (native-connector mode), committed lines are drawn by the native
    /// `ConnectorOverlayController`; this SwiftUI layer then renders ONLY the live
    /// connect-drag preview.
    var committedHidden = false
    @EnvironmentObject var state: CanvasState
    @EnvironmentObject var cameraStore: CameraStore

    var body: some View {
        ZStack {
            if !committedHidden { committedConnectors }
            // The live preview is always non-interactive; we keep its
            // dashed line above everything but it shouldn't catch clicks.
            livePreview
                .allowsHitTesting(false)
        }
    }

    // MARK: - Committed connectors

    private var committedConnectors: some View {
        ForEach(state.connectors) { connector in
            if let route = route(for: connector) {
                ConnectorView(connector: connector, route: route)
            }
        }
    }

    private func route(for connector: Connector) -> ElbowRoute? {
        // O(1) endpoint lookup via the cached index — saves O(n_nodes × 2)
        // per connector per camera tick versus a linear `first(where:)` scan.
        guard let source = state.nodeByID[connector.sourceID],
              let target = state.nodeByID[connector.targetID] else {
            return nil
        }
        return ElbowRoute.build(
            source: screenRect(of: source),
            target: screenRect(of: target),
            cornerRadius: 14
        )
    }

    // MARK: - Live preview (drag-to-connect)

    /// Brand green (#3DA726) — matches the native committed connectors.
    private static let connectorGreen = Color(.sRGB, red: 0.239, green: 0.655, blue: 0.149)

    @ViewBuilder
    private var livePreview: some View {
        if let pending = state.pendingConnector,
           let route = livePreviewRoute(for: pending) {
            Path(route.path)
                .stroke(
                    Self.connectorGreen.opacity(0.9),
                    style: StrokeStyle(
                        lineWidth: 2,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: [5, 4]
                    )
                )
                .overlay(
                    ArrowheadShape(
                        tip: route.arrowTip,
                        from: route.arrowFrom,
                        length: 12,
                        halfWidth: 7
                    )
                    .fill(Self.connectorGreen)
                )
        }
    }

    /// Obsidian-style bezier preview (screen space). Returns a `BezierRoute`
    /// whose `path` is a `CGPath` (wrapped in a SwiftUI `Path` to draw).
    private func livePreviewRoute(for pending: PendingConnector) -> BezierRoute? {
        guard let source = state.nodeByID[pending.sourceID] else { return nil }
        let sourceScreen = screenRect(of: source)

        if let targetID = pending.hoveredTargetID,
           let target = state.nodeByID[targetID] {
            return ConnectorPathMath.route(source: sourceScreen, target: screenRect(of: target))
        }

        // Free cursor — a 0-sized phantom rect at the cursor; bestSide aims at it.
        let cursor = state.worldToScreen(pending.cursorWorld)
        let phantom = CGRect(x: cursor.x, y: cursor.y, width: 0, height: 0)
        return ConnectorPathMath.route(source: sourceScreen, target: phantom)
    }

    // MARK: - World → screen rect

    private func screenRect(of node: CanvasNode) -> CGRect {
        let z = cameraStore.camera.zoom
        return CGRect(
            x: node.position.x * z + cameraStore.camera.x,
            y: node.position.y * z + cameraStore.camera.y,
            width:  node.width * z,
            height: state.renderedHeight(of: node) * z
        )
    }
}

// MARK: - Camera helper

extension CanvasState {
    func worldToScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * camera.zoom + camera.x,
                y: p.y * camera.zoom + camera.y)
    }
}

// MARK: - Elbow routing

/// FigJam-style L/Z connector: choose the dominant axis between source and
/// target, exit/enter their facing edges, route the middle leg perpendicular
/// to the exit, and round the right-angle bends.
struct ElbowRoute {
    var path: Path
    /// Where the arrowhead tip sits.
    var arrowTip: CGPoint
    /// Reference point the arrowhead points away from (i.e. previous segment
    /// endpoint). Together with `arrowTip` this defines the heading.
    var arrowFrom: CGPoint

    static func build(source: CGRect, target: CGRect, cornerRadius: CGFloat) -> ElbowRoute {
        let dx = target.midX - source.midX
        let dy = target.midY - source.midY
        let horizontalDominant = abs(dx) >= abs(dy)

        if horizontalDominant {
            return horizontalZ(source: source, target: target, cornerRadius: cornerRadius)
        } else {
            return verticalZ(source: source, target: target, cornerRadius: cornerRadius)
        }
    }

    // MARK: H → V → H

    private static func horizontalZ(source: CGRect, target: CGRect, cornerRadius: CGFloat) -> ElbowRoute {
        let goingRight = target.midX >= source.midX
        let S = CGPoint(
            x: goingRight ? source.maxX : source.minX,
            y: source.midY
        )
        let E = CGPoint(
            x: goingRight ? target.minX : target.maxX,
            y: target.midY
        )

        // If the target's facing edge is past the source's facing edge in the
        // wrong direction (e.g. target is overlapping or behind), midX would
        // collapse — use the midpoint of the two centres in that case.
        let fallbackMidX = (source.midX + target.midX) / 2
        let midX: CGFloat = {
            if goingRight {
                return E.x > S.x ? (S.x + E.x) / 2 : fallbackMidX
            } else {
                return E.x < S.x ? (S.x + E.x) / 2 : fallbackMidX
            }
        }()

        let dirH: CGFloat = E.x >= S.x ? 1 : -1
        let dirV: CGFloat = E.y >= S.y ? 1 : -1

        // Clamp the corner radius so it never overshoots its segments.
        let r = clampedRadius(
            cornerRadius,
            limits: [
                abs(midX - S.x), abs(E.x - midX),
                abs(E.y - S.y) / 2
            ]
        )

        var path = Path()
        path.move(to: S)
        var arrowFrom = S

        if r > 0.5 && abs(E.y - S.y) > 1 {
            path.addLine(to: CGPoint(x: midX - dirH * r, y: S.y))
            path.addQuadCurve(
                to: CGPoint(x: midX, y: S.y + dirV * r),
                control: CGPoint(x: midX, y: S.y)
            )
            path.addLine(to: CGPoint(x: midX, y: E.y - dirV * r))
            path.addQuadCurve(
                to: CGPoint(x: midX + dirH * r, y: E.y),
                control: CGPoint(x: midX, y: E.y)
            )
            path.addLine(to: E)
            arrowFrom = CGPoint(x: midX + dirH * r, y: E.y)
        } else {
            // Source and target are vertically aligned (or near-degenerate) —
            // skip the bend, just go straight.
            path.addLine(to: E)
            arrowFrom = S
        }

        return ElbowRoute(path: path, arrowTip: E, arrowFrom: arrowFrom)
    }

    // MARK: V → H → V

    private static func verticalZ(source: CGRect, target: CGRect, cornerRadius: CGFloat) -> ElbowRoute {
        let goingDown = target.midY >= source.midY
        let S = CGPoint(
            x: source.midX,
            y: goingDown ? source.maxY : source.minY
        )
        let E = CGPoint(
            x: target.midX,
            y: goingDown ? target.minY : target.maxY
        )

        let fallbackMidY = (source.midY + target.midY) / 2
        let midY: CGFloat = {
            if goingDown {
                return E.y > S.y ? (S.y + E.y) / 2 : fallbackMidY
            } else {
                return E.y < S.y ? (S.y + E.y) / 2 : fallbackMidY
            }
        }()

        let dirH: CGFloat = E.x >= S.x ? 1 : -1
        let dirV: CGFloat = E.y >= S.y ? 1 : -1

        let r = clampedRadius(
            cornerRadius,
            limits: [
                abs(midY - S.y), abs(E.y - midY),
                abs(E.x - S.x) / 2
            ]
        )

        var path = Path()
        path.move(to: S)
        var arrowFrom = S

        if r > 0.5 && abs(E.x - S.x) > 1 {
            path.addLine(to: CGPoint(x: S.x, y: midY - dirV * r))
            path.addQuadCurve(
                to: CGPoint(x: S.x + dirH * r, y: midY),
                control: CGPoint(x: S.x, y: midY)
            )
            path.addLine(to: CGPoint(x: E.x - dirH * r, y: midY))
            path.addQuadCurve(
                to: CGPoint(x: E.x, y: midY + dirV * r),
                control: CGPoint(x: E.x, y: midY)
            )
            path.addLine(to: E)
            arrowFrom = CGPoint(x: E.x, y: midY + dirV * r)
        } else {
            path.addLine(to: E)
            arrowFrom = S
        }

        return ElbowRoute(path: path, arrowTip: E, arrowFrom: arrowFrom)
    }

    private static func clampedRadius(_ desired: CGFloat, limits: [CGFloat]) -> CGFloat {
        let cap = (limits + [desired]).min() ?? desired
        return max(0, cap)
    }
}

// MARK: - Per-connector view (visual + hit area)

/// Renders one connector. The hit target is a thick stroked-path shape
/// filled with a near-invisible color so the line is clickable along its
/// entire length, while the visible stroke is drawn over it at normal
/// thickness with `.allowsHitTesting(false)` so it doesn't double-up hits.
struct ConnectorView: View {
    @EnvironmentObject var state: CanvasState
    let connector: Connector
    let route: ElbowRoute

    var body: some View {
        let isSelected = state.selectedConnectorIDs.contains(connector.id)
        let color: Color = isSelected
            ? Color.accentColor
            : Color(nsColor: .labelColor).opacity(0.85)
        let lineWidth: CGFloat = isSelected ? 2.5 : 2.0

        ZStack {
            // Wide invisible hit area along the stroke.
            ConnectorHitShape(path: route.path, lineWidth: 14)
                .fill(Color.black.opacity(0.001))
                .onTapGesture {
                    state.selectConnector(connector.id)
                }

            // Visual stroke + arrowhead (non-interactive).
            ConnectorPathShape(path: route.path)
                .stroke(
                    color,
                    style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .allowsHitTesting(false)

            ArrowheadShape(
                tip: route.arrowTip,
                from: route.arrowFrom,
                length: 11,
                halfWidth: 5
            )
            .fill(color)
            .allowsHitTesting(false)
        }
    }
}

/// Wraps a stored Path so it can be used as a SwiftUI Shape (and stroked).
struct ConnectorPathShape: Shape {
    var path: Path
    func path(in rect: CGRect) -> Path { path }
}

/// Returns the *stroked* outline of the elbow path as a fillable shape.
/// Used as an invisible-but-clickable hit target wider than the visual line.
struct ConnectorHitShape: Shape {
    var path: Path
    var lineWidth: CGFloat
    func path(in rect: CGRect) -> Path {
        path.strokedPath(StrokeStyle(
            lineWidth: lineWidth,
            lineCap: .round,
            lineJoin: .round
        ))
    }
}

// MARK: - Arrowhead shape (unchanged)

struct ArrowheadShape: Shape {
    var tip: CGPoint
    var from: CGPoint
    var length: CGFloat
    var halfWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dx = tip.x - from.x
        let dy = tip.y - from.y
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0.001 else { return path }
        let ux = dx / len, uy = dy / len
        let base = CGPoint(x: tip.x - ux * length, y: tip.y - uy * length)
        let p1 = CGPoint(x: base.x + uy * halfWidth, y: base.y - ux * halfWidth)
        let p2 = CGPoint(x: base.x - uy * halfWidth, y: base.y + ux * halfWidth)
        path.move(to: tip)
        path.addLine(to: p1)
        path.addLine(to: p2)
        path.closeSubpath()
        return path
    }
}
