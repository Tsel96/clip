import SwiftUI
import AppKit

/// Figma-style Smart Selection chrome — pink center rings, gutter handles,
/// tooltip readout during gap drags, and an insertion indicator during
/// reorder drags. All in screen space so handles stay legible at any zoom.
///
/// Inserted into `CanvasView`'s ZStack between `ConnectorsLayer` and
/// `AlignmentGuidesOverlay`. Observes `CameraStore` so pan / zoom re-renders
/// this layer (and only this layer + other camera-coupled chrome) — node
/// views remain untouched, preserving the P1-A invalidation isolation.
struct SmartSelectionLayer: View {
    @EnvironmentObject var state: CanvasState
    @EnvironmentObject var cameraStore: CameraStore
    @EnvironmentObject var controller: SmartSelectionController

    /// The ring under the cursor, if any — for the hover-to-fill state.
    @State private var hoveredRingID: UUID? = nil
    /// Tracks the last tap so we can implement the treatise's "double-click
    /// to mark row, second double-click to mark matrix" pattern without a
    /// SwiftUI tripleTap gesture (which doesn't compose with single-tap).
    @State private var lastTapTime: TimeInterval = 0
    @State private var lastTappedRingID: UUID? = nil
    @State private var tapCount: Int = 0
    /// Live cursor position in canvas-space (named coord space). Drives
    /// the floating gutter-tooltip and the reorder insertion indicator.
    @State private var cursorScreen: CGPoint? = nil

    /// True while a rubber-band marquee is being drawn over the canvas.
    /// We use this to both hide chrome AND disable its hit testing during
    /// the drag, so a marquee that started on empty canvas can't have its
    /// `onEnded` stolen by a ring's tap/drag gesture when the cursor
    /// crosses (or releases over) a Smart Selection affordance.
    private var marqueeInProgress: Bool {
        state.rubberBandScreenRect != nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let layout = controller.layout,
               state.canvasMode == .canvas,
               !marqueeInProgress {

                // Center rings — one per layout member.
                ForEach(layout.flatOrderedIDs, id: \.self) { id in
                    if let center = ringCenter(of: id) {
                        ring(for: id, center: center)
                    }
                }

                // Gutter handles — one per inter-element gap (and one per
                // inter-row gap for 2D grids).
                ForEach(Array(gutters(in: layout).enumerated()), id: \.offset) { _, g in
                    gutterHandle(g)
                }

                // Reorder insertion indicator.
                if let drag = controller.reorderDrag {
                    insertionIndicator(drag: drag, layout: layout)
                }

                // Gutter-drag tooltip.
                if let drag = controller.gutterDrag {
                    tooltipReadout(drag: drag)
                }
            }
        }
        // Hit testing is disabled when: no layout exists, we're outside
        // canvas mode, OR a marquee is in progress (otherwise the rings
        // would steal the mouseup that should terminate the marquee).
        .allowsHitTesting(
            controller.layout != nil &&
            state.canvasMode == .canvas &&
            !marqueeInProgress
        )
    }

    // MARK: - Geometry

    private var camera: Camera { cameraStore.camera }
    private var zoom: CGFloat { max(camera.zoom, 0.0001) }
    private var invZoom: CGFloat { 1 / zoom }

    private func screenRect(of nodeID: UUID) -> CGRect? {
        guard let node = state.nodeByID[nodeID] else { return nil }
        let h = state.renderedHeight(of: node)
        return CGRect(
            x: node.position.x * zoom + camera.x,
            y: node.position.y * zoom + camera.y,
            width:  node.width * zoom,
            height: h * zoom
        )
    }

    private func ringCenter(of id: UUID) -> CGPoint? {
        guard let r = screenRect(of: id) else { return nil }
        return CGPoint(x: r.midX, y: r.midY)
    }

    // MARK: - Center ring

    /// Hollow pink ring at the node's centre. Hovered → fills to 50%.
    /// Marked (in `controller.markedIDs`) → solid fill. Tap to mark,
    /// Shift-tap to toggle, double-tap to mark axis, triple-tap to mark all.
    /// Drag on the ring initiates a reorder drag.
    @ViewBuilder
    private func ring(for id: UUID, center: CGPoint) -> some View {
        let isMarked = controller.markedIDs.contains(id)
        let isHovered = hoveredRingID == id
        // Screen-constant sizes — these stay 8pt and 1.5pt regardless of
        // canvas zoom (we're already in screen space; no `invZoom` needed).
        let radius: CGFloat = 8

        Circle()
            .strokeBorder(
                isMarked ? Color.pink : Color.pink.opacity(isHovered ? 0.85 : 0.7),
                lineWidth: 1.5
            )
            .background(
                Circle().fill(
                    isMarked ? Color.pink.opacity(0.95)
                            : (isHovered ? Color.pink.opacity(0.5) : Color.clear)
                )
            )
            .frame(width: radius * 2, height: radius * 2)
            .position(center)
            .contentShape(Circle())
            .onHover { hovering in
                hoveredRingID = hovering ? id : (hoveredRingID == id ? nil : hoveredRingID)
            }
            .gesture(ringDragGesture(id: id))
            .simultaneousGesture(ringTapGesture(id: id))
    }

    /// Tap gesture handles single / double / triple tap behaviour. SwiftUI
    /// `.onTapGesture(count: N)` is exclusive (a 2-tap gesture won't fire
    /// a single-tap when the user only taps once with a delay), so we
    /// implement the staircase manually using `lastTapTime`/`tapCount`.
    private func ringTapGesture(id: UUID) -> some Gesture {
        TapGesture(count: 1).onEnded { _ in
            let now = CACurrentMediaTime()
            let elapsed = now - lastTapTime
            // 280ms multi-tap window (same as macOS default double-click).
            let isContinuation = (elapsed < 0.28) && (lastTappedRingID == id)
            tapCount = isContinuation ? tapCount + 1 : 1
            lastTapTime = now
            lastTappedRingID = id

            let shift = NSEvent.modifierFlags.contains(.shift)
            switch tapCount {
            case 1:
                if shift {
                    controller.toggleMark(id)
                } else {
                    controller.mark(id)
                }
            case 2:
                controller.markAxis(of: id)
            default:    // 3+ taps → matrix mark
                controller.markAll()
            }
        }
    }

    /// Drag on a ring starts a reorder. The cursor is reported in the
    /// `CanvasCoords` named space, which matches our screen-space camera
    /// projection. Translations divide by zoom to give world-space deltas
    /// for the dragged node's new position.
    private func ringDragGesture(id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(CanvasCoords.name))
            .onChanged { value in
                if controller.reorderDrag == nil {
                    // Begin: mark the element first (Figma autocomplete:
                    // dragging an unmarked ring also marks it).
                    controller.mark(id)
                    let directSwap = NSEvent.modifierFlags.contains(.command) ||
                                     NSEvent.modifierFlags.contains(.control)
                    _ = controller.beginReorderDrag(
                        elementID: id,
                        startCursorScreen: value.startLocation,
                        directSwap: directSwap
                    )
                }
                let worldTranslation = CGSize(
                    width:  value.translation.width  / zoom,
                    height: value.translation.height / zoom
                )
                controller.updateReorderDrag(
                    currentCursorScreen: value.location,
                    cursorWorldTranslation: worldTranslation,
                    zoom: zoom
                )
                cursorScreen = value.location
            }
            .onEnded { _ in
                controller.endReorderDrag()
                cursorScreen = nil
            }
    }

    // MARK: - Gutter handles

    private struct Gutter: Identifiable {
        enum Kind { case betweenSiblings, betweenRows }
        let id = UUID()
        let axis: SmartGapAxis
        let kind: Kind
        /// Screen position of the handle's centre.
        let centre: CGPoint
        /// Length of the handle perpendicular to the axis.
        let perpendicularExtent: CGFloat
    }

    /// Compute all gutter handles for the current layout. For a Row1D /
    /// Column1D, one per inter-element gap. For Grid2D, one per column
    /// gap (vertical handle drawn between two adjacent columns) and one
    /// per row gap.
    private func gutters(in layout: SmartSelectionLayout) -> [Gutter] {
        var out: [Gutter] = []
        switch layout {
        case .row1D(let ids, _, _):
            for i in 0..<(ids.count - 1) {
                if let g = horizontalGutter(leftID: ids[i], rightID: ids[i + 1]) {
                    out.append(g)
                }
            }
        case .column1D(let ids, _, _):
            for i in 0..<(ids.count - 1) {
                if let g = verticalGutter(topID: ids[i], bottomID: ids[i + 1]) {
                    out.append(g)
                }
            }
        case .grid2D(let rows, _, _):
            // Inter-column handles: between rows[r][c] and rows[r][c+1]
            // for r = some row (we use the middle row for visual anchor).
            guard let middleRow = rows.middleElement else { break }
            for i in 0..<(middleRow.count - 1) {
                if let g = horizontalGutter(leftID: middleRow[i], rightID: middleRow[i + 1]) {
                    out.append(g)
                }
            }
            // Inter-row handles: between rows[r].middle and rows[r+1].middle.
            for r in 0..<(rows.count - 1) {
                guard let upperMid = rows[r].middleElement,
                      let lowerMid = rows[r + 1].middleElement else { continue }
                if let g = verticalGutter(topID: upperMid, bottomID: lowerMid) {
                    out.append(g)
                }
            }
        }
        return out
    }

    private func horizontalGutter(leftID: UUID, rightID: UUID) -> Gutter? {
        guard let l = screenRect(of: leftID),
              let r = screenRect(of: rightID) else { return nil }
        guard r.minX > l.maxX else { return nil }
        let centre = CGPoint(
            x: (l.maxX + r.minX) / 2,
            y: (max(l.minY, r.minY) + min(l.maxY, r.maxY)) / 2
        )
        let perp = max(0, min(l.maxY, r.maxY) - max(l.minY, r.minY))
        return Gutter(axis: .horizontal, kind: .betweenSiblings, centre: centre, perpendicularExtent: perp)
    }
    private func verticalGutter(topID: UUID, bottomID: UUID) -> Gutter? {
        guard let t = screenRect(of: topID),
              let b = screenRect(of: bottomID) else { return nil }
        guard b.minY > t.maxY else { return nil }
        let centre = CGPoint(
            x: (max(t.minX, b.minX) + min(t.maxX, b.maxX)) / 2,
            y: (t.maxY + b.minY) / 2
        )
        let perp = max(0, min(t.maxX, b.maxX) - max(t.minX, b.minX))
        return Gutter(axis: .vertical, kind: .betweenRows, centre: centre, perpendicularExtent: perp)
    }

    /// Render one gutter handle. Pink pill, 6 × 16 screen-points, oriented
    /// perpendicular to the gap. Hover → cursor change + slight grow.
    @ViewBuilder
    private func gutterHandle(_ g: Gutter) -> some View {
        let isActive = controller.gutterDrag?.axis == g.axis
        let width:  CGFloat = g.axis == .horizontal ? 6  : 22
        let height: CGFloat = g.axis == .horizontal ? 22 : 6

        Capsule()
            .fill(Color.pink.opacity(isActive ? 0.95 : 0.7))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.7), lineWidth: 0.5))
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
            .position(g.centre)
            .contentShape(Rectangle().size(width: max(20, width), height: max(20, height)))
            .onHover { hovering in
                if hovering {
                    switch g.axis {
                    case .horizontal: NSCursor.resizeLeftRight.push()
                    case .vertical:   NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(gutterDragGesture(for: g))
    }

    private func gutterDragGesture(for gutter: Gutter) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(CanvasCoords.name))
            .onChanged { value in
                if controller.gutterDrag == nil {
                    controller.beginGutterDrag(
                        axis: gutter.axis,
                        startCursorScreen: value.startLocation
                    )
                }
                let quantize = NSEvent.modifierFlags.contains(.shift)
                controller.updateGutterDrag(
                    currentCursorScreen: value.location,
                    zoom: zoom,
                    quantize: quantize
                )
                cursorScreen = value.location
            }
            .onEnded { _ in
                controller.endGutterDrag()
                cursorScreen = nil
            }
    }

    // MARK: - Tooltip readout

    @ViewBuilder
    private func tooltipReadout(drag: GutterDragState) -> some View {
        // Show the current gap value computed live from anchor positions.
        // The drag's `anchorPositions` + the cursor delta tells us the gap
        // implicitly; we read it back off the in-flight layout's `gap`
        // (the controller updates positions, but the published `layout`
        // value still reports the pre-drag gap). For simplicity we
        // recompute from two anchored siblings.
        let gap = currentGap(of: drag.axis) ?? drag.originalGap
        let cursor = cursorScreen ?? drag.startCursorScreen
        Text("\(Int(round(gap))) px")
            .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4),
                                  lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
            .position(x: cursor.x, y: cursor.y - 26)
            .allowsHitTesting(false)
    }

    private func currentGap(of axis: SmartGapAxis) -> CGFloat? {
        guard let layout = controller.layout else { return nil }
        switch (layout, axis) {
        case (.row1D(let ids, _, _), .horizontal):
            return measuredGap(ids: ids, axis: .horizontal)
        case (.column1D(let ids, _, _), .vertical):
            return measuredGap(ids: ids, axis: .vertical)
        case (.grid2D(let rows, _, _), .horizontal):
            guard let row = rows.middleElement else { return nil }
            return measuredGap(ids: row, axis: .horizontal)
        case (.grid2D(let rows, _, _), .vertical):
            // Use the column's middle node from each row.
            var col: [UUID] = []
            for r in rows {
                if let mid = r.middleElement { col.append(mid) }
            }
            return measuredGap(ids: col, axis: .vertical)
        default:
            return nil
        }
    }
    private func measuredGap(ids: [UUID], axis: SmartGapAxis) -> CGFloat? {
        guard ids.count >= 2,
              let a = state.nodeByID[ids[0]],
              let b = state.nodeByID[ids[1]] else { return nil }
        switch axis {
        case .horizontal: return b.position.x - (a.position.x + a.width)
        case .vertical:   return b.position.y - (a.position.y + state.renderedHeight(of: a))
        }
    }

    // MARK: - Insertion indicator

    @ViewBuilder
    private func insertionIndicator(drag: SmartDragState, layout: SmartSelectionLayout) -> some View {
        // Draw a thick pink line across the gap at the placeholder slot —
        // this is the "thick stroke indicating exact insertion index"
        // affordance from the treatise.
        let indicatorPath = insertionPath(drag: drag, layout: layout)
        if let p = indicatorPath {
            Path { path in
                path.move(to: p.from)
                path.addLine(to: p.to)
            }
            .stroke(Color.pink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .allowsHitTesting(false)
        }
    }

    private struct LineSegment { let from: CGPoint; let to: CGPoint }
    private func insertionPath(drag: SmartDragState, layout: SmartSelectionLayout) -> LineSegment? {
        // Identify the slot the placeholder currently occupies in the
        // visual sense, and draw a perpendicular line across it.
        switch layout {
        case .row1D(let ids, _, _):
            return rowInsertion(at: drag.placeholderIndex, ids: ids, draggedID: drag.elementID)
        case .column1D(let ids, _, _):
            return columnInsertion(at: drag.placeholderIndex, ids: ids, draggedID: drag.elementID)
        case .grid2D(let rows, _, _):
            let cols = rows.first?.count ?? 0
            guard cols > 0 else { return nil }
            let r = drag.placeholderIndex / cols
            let c = drag.placeholderIndex % cols
            guard r < rows.count, c < rows[r].count else { return nil }
            // Use the row's draw method for the column index.
            return rowInsertion(at: c, ids: rows[r], draggedID: drag.elementID)
        }
    }
    private func rowInsertion(at index: Int, ids: [UUID], draggedID: UUID) -> LineSegment? {
        // Insert BEFORE the element at `index` in the visible row order
        // (after skipping the dragged element).
        let visible = ids.filter { $0 != draggedID }
        if visible.isEmpty { return nil }
        let i = min(index, visible.count)
        if i == 0 {
            guard let firstRect = screenRect(of: visible[0]) else { return nil }
            return LineSegment(
                from: CGPoint(x: firstRect.minX - 6, y: firstRect.minY),
                to:   CGPoint(x: firstRect.minX - 6, y: firstRect.maxY)
            )
        }
        if i >= visible.count {
            guard let lastRect = screenRect(of: visible[visible.count - 1]) else { return nil }
            return LineSegment(
                from: CGPoint(x: lastRect.maxX + 6, y: lastRect.minY),
                to:   CGPoint(x: lastRect.maxX + 6, y: lastRect.maxY)
            )
        }
        guard let leftRect = screenRect(of: visible[i - 1]),
              let rightRect = screenRect(of: visible[i]) else { return nil }
        let midX = (leftRect.maxX + rightRect.minX) / 2
        let topY = max(leftRect.minY, rightRect.minY)
        let botY = min(leftRect.maxY, rightRect.maxY)
        return LineSegment(from: CGPoint(x: midX, y: topY), to: CGPoint(x: midX, y: botY))
    }
    private func columnInsertion(at index: Int, ids: [UUID], draggedID: UUID) -> LineSegment? {
        let visible = ids.filter { $0 != draggedID }
        if visible.isEmpty { return nil }
        let i = min(index, visible.count)
        if i == 0 {
            guard let firstRect = screenRect(of: visible[0]) else { return nil }
            return LineSegment(
                from: CGPoint(x: firstRect.minX, y: firstRect.minY - 6),
                to:   CGPoint(x: firstRect.maxX, y: firstRect.minY - 6)
            )
        }
        if i >= visible.count {
            guard let lastRect = screenRect(of: visible[visible.count - 1]) else { return nil }
            return LineSegment(
                from: CGPoint(x: lastRect.minX, y: lastRect.maxY + 6),
                to:   CGPoint(x: lastRect.maxX, y: lastRect.maxY + 6)
            )
        }
        guard let topRect = screenRect(of: visible[i - 1]),
              let botRect = screenRect(of: visible[i]) else { return nil }
        let midY = (topRect.maxY + botRect.minY) / 2
        let leftX = max(topRect.minX, botRect.minX)
        let rightX = min(topRect.maxX, botRect.maxX)
        return LineSegment(from: CGPoint(x: leftX, y: midY), to: CGPoint(x: rightX, y: midY))
    }
}

// MARK: - Array convenience

private extension Array {
    /// The element at `count / 2` (rounded down). Used to pick the
    /// row / column representative for gutter-handle placement.
    var middleElement: Element? {
        guard !isEmpty else { return nil }
        return self[count / 2]
    }
}
