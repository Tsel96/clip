import Foundation
import Combine
import CoreGraphics
import QuartzCore

/// Axis a gutter handle drags along. `.horizontal` adjusts the gap between
/// columns (i.e. the inter-element gap inside a row). `.vertical` adjusts
/// the inter-row gap inside a column.
enum SmartGapAxis: Hashable { case horizontal, vertical }

/// Live state of an in-flight gutter drag.
struct GutterDragState {
    let axis: SmartGapAxis
    let originalGap: CGFloat
    /// Anchor positions captured at gesture-start; per-tick repositioning
    /// is computed from these so the drag is monotonic and round-trippable.
    let anchorPositions: [UUID: CGPoint]
    let undoSnapshot: PageSnapshot
    /// Screen-space cursor coordinate at drag-start — used to convert the
    /// per-tick delta into world units (`delta / zoom`).
    let startCursorScreen: CGPoint
    /// Most recently emitted 8pt-quantized gap value while the user
    /// holds Shift. We fire one haptic per *new* 8pt multiple crossed
    /// (so slow drags get discrete taps at 8 / 16 / 24 / 32 …); fast
    /// drags still cap at one tap per boundary because the rounded
    /// value either equals the previous or doesn't.
    var lastQuantizedGap: CGFloat? = nil
}

/// Live state of an in-flight reorder drag.
struct SmartDragState {
    let elementID: UUID
    /// Index of the dragged element in the abstract `flatOrderedIDs` array.
    let originIndex: Int
    /// Cursor history (4 most recent samples) — drives the velocity-
    /// prediction step described in the treatise.
    var cursorHistory: [(point: CGPoint, time: TimeInterval)]
    /// Where the placeholder currently lives in the abstract array. The
    /// remaining siblings reorder around it; when the drag ends, the
    /// dragged element snaps to whatever world-position the placeholder
    /// resolves to.
    var placeholderIndex: Int
    /// True if `⌘ / Ctrl` was held at gesture-start. Direct-swap mode
    /// bypasses the reflow: the first sibling crossing the 50%
    /// intersection threshold swaps indices with the dragged element
    /// once, no cascading.
    let directSwapMode: Bool
    /// Anchor positions captured at gesture-start.
    let anchorPositions: [UUID: CGPoint]
    let undoSnapshot: PageSnapshot
}

/// Holds the live Smart Selection layout and transient interaction state,
/// and owns the mutation API the chrome layer + key monitor invoke. One
/// instance per `CanvasState`; injected as an `@EnvironmentObject`.
@MainActor
final class SmartSelectionController: ObservableObject {

    /// The currently-active Smart Selection structure, or `nil` if the
    /// selection doesn't qualify. Recomputed automatically by a Combine
    /// pipeline on `(selectedNodeIDs, pages, canvasMode)`.
    @Published private(set) var layout: SmartSelectionLayout? = nil

    /// Explicitly marked elements (clicked center rings). A subset of
    /// `layout.flatOrderedIDs`. Cleared when the layout changes shape.
    @Published var markedIDs: Set<UUID> = []

    /// Active gutter drag, if any.
    @Published private(set) var gutterDrag: GutterDragState? = nil

    /// Active reorder drag, if any.
    @Published private(set) var reorderDrag: SmartDragState? = nil

    /// Bumped each time `layout` recomputes — drives implicit animations
    /// on chrome positions without coupling to the layout enum's equality.
    @Published private(set) var layoutEpoch: Int = 0

    private unowned let state: CanvasState
    private var cancellables: Set<AnyCancellable> = []

    init(state: CanvasState) {
        self.state = state

        // Recompute the layout whenever:
        //   • the selection changes
        //   • any node mutates (drag, resize, add, delete)
        //   • the canvas mode changes (chrome hides outside .canvas)
        // The 16ms debounce coalesces multi-publish bursts in the same
        // run-loop tick (e.g. a selection change + a position update fire
        // both `$selectedNodeIDs` and `$pages` back-to-back).
        Publishers.CombineLatest4(
            state.$selectedNodeIDs,
            state.$pages,
            state.$canvasMode,
            state.$activeDragID
        )
        .debounce(for: .milliseconds(16), scheduler: DispatchQueue.main)
        .sink { [weak self] _, _, _, dragID in
            // Suspended while a drag is in flight: per-tick position writes
            // fire `$pages` continuously, so classifying every tick is pure
            // churn. `endDrag()` clears `activeDragID`, which re-fires this
            // pipeline for the single post-drag recompute.
            guard dragID == nil else { return }
            self?.recompute()
        }
        .store(in: &cancellables)
    }

    // MARK: - Classification

    private func recompute() {
        // Chrome appears in Canvas mode only — Colorform / Archive
        // are read-only.
        guard state.canvasMode == .canvas else {
            applyLayout(nil)
            return
        }
        let ids = state.selectedNodeIDs
        guard ids.count >= 2 else {
            applyLayout(nil)
            return
        }
        // Build (id, rect) pairs. Sections excluded — Smart Selection is
        // for content cards, not containers.
        var items: [(id: UUID, rect: CGRect)] = []
        items.reserveCapacity(ids.count)
        for id in ids {
            guard let node = state.nodeByID[id], !node.isSection else {
                applyLayout(nil)
                return
            }
            let h = state.renderedHeight(of: node)
            items.append((
                id: id,
                rect: CGRect(
                    x: node.position.x, y: node.position.y,
                    width: node.width, height: h
                )
            ))
        }
        applyLayout(SmartSelectionClassifier.classify(items: items))
    }

    private func applyLayout(_ next: SmartSelectionLayout?) {
        if layout != next {
            layout = next
            layoutEpoch &+= 1
            // Drop marks that no longer belong to a member of the current layout.
            if let next = next {
                let valid = Set(next.flatOrderedIDs)
                let trimmed = markedIDs.intersection(valid)
                if trimmed != markedIDs { markedIDs = trimmed }
            } else if !markedIDs.isEmpty {
                markedIDs = []
            }
        }
    }

    // MARK: - Marking

    /// Set the marked set to exactly one id (Click on its center ring).
    func mark(_ id: UUID) {
        guard let layout, layout.flatOrderedIDs.contains(id) else { return }
        markedIDs = [id]
        Haptics.tap()
    }
    /// Toggle membership (Shift-click on its center ring).
    func toggleMark(_ id: UUID) {
        guard let layout, layout.flatOrderedIDs.contains(id) else { return }
        if markedIDs.contains(id) { markedIDs.remove(id) } else { markedIDs.insert(id) }
        Haptics.tap()
    }
    /// Mark every element on the same 1D axis as `id` (double-click).
    /// In Grid2D, this is the full row containing `id`. In a Row1D /
    /// Column1D, it's the whole selection.
    func markAxis(of id: UUID) {
        guard let layout else { return }
        switch layout {
        case .row1D(let ids, _, _), .column1D(let ids, _, _):
            markedIDs = Set(ids)
        case .grid2D(let rows, _, _):
            if let r = rows.firstIndex(where: { $0.contains(id) }) {
                markedIDs = Set(rows[r])
            }
        }
        Haptics.tap()
    }
    /// Mark the entire layout (second double-click in a Grid2D).
    func markAll() {
        guard let layout else { return }
        markedIDs = Set(layout.flatOrderedIDs)
        Haptics.tap()
    }
    func clearMarks() {
        if !markedIDs.isEmpty { markedIDs = [] }
    }

    // MARK: - Tidy Up command

    /// Runs `TidyUpEngine` over the current selection and writes the result
    /// back through `state.updatePosition(of:to:)`. Commits one undoable
    /// entry covering the whole batch.
    func tidyUp() {
        let ids = state.selectedNodeIDs
        guard ids.count >= 2 else { return }
        // Deterministic order: by node creation date (matches `addedAt`).
        // Falls back to UUID string for stable tie-breaking.
        let ordered = ids.compactMap { state.nodeByID[$0] }
            .sorted { lhs, rhs in
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        // Sections are skipped — they're containers, not Tidy-Up targets.
        let payload = ordered.filter { !$0.isSection }
        guard payload.count >= 2 else { return }

        let rects = payload.map { n -> CGRect in
            CGRect(
                x: n.position.x, y: n.position.y,
                width: n.width, height: state.renderedHeight(of: n)
            )
        }
        let zoom = state.cameraStore.camera.zoom
        let (snapped, _) = TidyUpEngine.tidy(rects: rects, zoom: zoom)

        let before = state.snapshotForUndo()
        for (i, node) in payload.enumerated() {
            state.updatePosition(of: node.id, to: snapped[i].origin)
        }
        state.commitUndoable(from: before)
        // Tap haptic — cards just snapped into alignment.
        Haptics.tap()
    }

    // MARK: - Gutter drag

    /// Begin a gutter drag. Snapshots the original gap, every selected
    /// node's current world-position, the page (for undo), and the cursor
    /// in screen coordinates so the per-tick delta can convert to world
    /// units via division by zoom.
    func beginGutterDrag(axis: SmartGapAxis, startCursorScreen: CGPoint) {
        guard let layout else { return }
        let originalGap: CGFloat
        switch (layout, axis) {
        case (.row1D(_, let g, _), .horizontal):        originalGap = g
        case (.column1D(_, let g, _), .vertical):       originalGap = g
        case (.grid2D(_, let gx, _), .horizontal):      originalGap = gx
        case (.grid2D(_, _, let gy), .vertical):        originalGap = gy
        default: return
        }
        var anchors: [UUID: CGPoint] = [:]
        for id in layout.flatOrderedIDs {
            if let node = state.nodeByID[id] {
                anchors[id] = node.position
            }
        }
        gutterDrag = GutterDragState(
            axis: axis,
            originalGap: originalGap,
            anchorPositions: anchors,
            undoSnapshot: state.snapshotForUndo(),
            startCursorScreen: startCursorScreen
        )
    }

    /// Apply a per-tick cursor update. Caller supplies cursor delta in
    /// screen units and current zoom; the controller computes the new
    /// gap and re-flows all elements accordingly. If `quantize` is true
    /// (Shift held), the new gap snaps to 8pt increments.
    func updateGutterDrag(
        currentCursorScreen: CGPoint,
        zoom: CGFloat,
        quantize: Bool
    ) {
        guard var drag = gutterDrag, let layout else { return }
        let deltaScreen: CGFloat
        switch drag.axis {
        case .horizontal:
            deltaScreen = currentCursorScreen.x - drag.startCursorScreen.x
        case .vertical:
            deltaScreen = currentCursorScreen.y - drag.startCursorScreen.y
        }
        var newGap = drag.originalGap + deltaScreen / max(zoom, 0.0001)
        if quantize {
            newGap = (newGap / 8).rounded() * 8
            // Boundary-crossing haptic: tap exactly once per new 8pt
            // multiple — slow drags get discrete taps at 8/16/24/…,
            // fast drags are naturally throttled because consecutive
            // ticks land on the same multiple until the cursor
            // physically crosses the next boundary.
            if drag.lastQuantizedGap != newGap {
                drag.lastQuantizedGap = newGap
                gutterDrag = drag
                Haptics.tap()
            }
        }
        // Clamp: gap of zero means edge-to-edge; negative means overlap,
        // which we don't allow during a gutter drag (Figma also clamps).
        newGap = max(0, newGap)

        applyGap(layout: layout, axis: drag.axis, gap: newGap, anchors: drag.anchorPositions)
    }

    /// Commit the drag as a single undoable entry.
    func endGutterDrag() {
        guard let drag = gutterDrag else { return }
        gutterDrag = nil
        state.commitUndoable(from: drag.undoSnapshot)
    }

    /// Abort an in-flight gutter drag, restoring every member to the
    /// position it had at gesture-start. Symmetric counterpart to
    /// `cancelReorderDrag()`. Safe to call when no drag is active.
    func cancelGutterDrag() {
        guard let drag = gutterDrag else { return }
        for (id, pos) in drag.anchorPositions {
            state.updatePosition(of: id, to: pos)
        }
        gutterDrag = nil
    }

    /// One-call safety net: cancel any in-flight Smart Selection drag
    /// (reorder or gutter), restoring anchors. Used by the rubber-band
    /// marquee on gesture-start and by the Esc-key panic handler, so a
    /// previously-interrupted gesture can't leak its visuals onto the
    /// next interaction.
    func cancelAllDrags() {
        cancelReorderDrag()
        cancelGutterDrag()
    }

    /// Re-flow all member nodes using `anchors[firstNode]` as the origin
    /// and the supplied `gap` value. Writes positions via `updatePosition`
    /// (no undo each — caller wraps the whole drag in `commitUndoable`).
    private func applyGap(
        layout: SmartSelectionLayout,
        axis: SmartGapAxis,
        gap: CGFloat,
        anchors: [UUID: CGPoint]
    ) {
        switch layout {
        case .row1D(let ids, _, _) where axis == .horizontal:
            applyRowGap(ids: ids, gap: gap, anchors: anchors)
        case .column1D(let ids, _, _) where axis == .vertical:
            applyColumnGap(ids: ids, gap: gap, anchors: anchors)
        case .grid2D(let rows, _, let gapY) where axis == .horizontal:
            applyGrid(rows: rows, gapX: gap, gapY: gapY, anchors: anchors)
        case .grid2D(let rows, let gapX, _) where axis == .vertical:
            applyGrid(rows: rows, gapX: gapX, gapY: gap, anchors: anchors)
        default:
            break
        }
    }

    private func applyRowGap(ids: [UUID], gap: CGFloat, anchors: [UUID: CGPoint]) {
        guard let firstID = ids.first,
              let anchor = anchors[firstID],
              let first = state.nodeByID[firstID] else { return }
        var cursorX = anchor.x + first.width
        state.updatePosition(of: firstID, to: anchor)
        for id in ids.dropFirst() {
            guard let node = state.nodeByID[id] else { continue }
            let pos = CGPoint(x: cursorX + gap, y: anchor.y)
            state.updatePosition(of: id, to: pos)
            cursorX += gap + node.width
        }
    }
    private func applyColumnGap(ids: [UUID], gap: CGFloat, anchors: [UUID: CGPoint]) {
        guard let firstID = ids.first,
              let anchor = anchors[firstID],
              let first = state.nodeByID[firstID] else { return }
        var cursorY = anchor.y + state.renderedHeight(of: first)
        state.updatePosition(of: firstID, to: anchor)
        for id in ids.dropFirst() {
            guard let node = state.nodeByID[id] else { continue }
            let pos = CGPoint(x: anchor.x, y: cursorY + gap)
            state.updatePosition(of: id, to: pos)
            cursorY += gap + state.renderedHeight(of: node)
        }
    }
    private func applyGrid(rows: [[UUID]], gapX: CGFloat, gapY: CGFloat, anchors: [UUID: CGPoint]) {
        guard let firstID = rows.first?.first, let anchor = anchors[firstID] else { return }
        var rowY = anchor.y
        for (rIdx, row) in rows.enumerated() {
            // Use the row's leftmost node to anchor; subsequent in the row use cumulative cursorX.
            var cursorX = anchor.x
            for (cIdx, id) in row.enumerated() {
                guard let node = state.nodeByID[id] else { continue }
                let pos = CGPoint(x: cursorX, y: rowY)
                state.updatePosition(of: id, to: pos)
                cursorX += node.width + (cIdx < row.count - 1 ? gapX : 0)
            }
            if rIdx < rows.count - 1, let firstInRow = row.first,
               let first = state.nodeByID[firstInRow] {
                rowY += state.renderedHeight(of: first) + gapY
            }
        }
    }

    // MARK: - Reorder drag

    /// Begin a reorder drag for the given marked element.
    /// Captures the undo snapshot + every layout member's current
    /// position. Returns false if the element isn't part of the layout.
    @discardableResult
    func beginReorderDrag(
        elementID: UUID,
        startCursorScreen: CGPoint,
        directSwap: Bool
    ) -> Bool {
        guard let layout, let originIndex = layout.flatOrderedIDs.firstIndex(of: elementID)
        else { return false }
        var anchors: [UUID: CGPoint] = [:]
        for id in layout.flatOrderedIDs {
            if let node = state.nodeByID[id] {
                anchors[id] = node.position
            }
        }
        reorderDrag = SmartDragState(
            elementID: elementID,
            originIndex: originIndex,
            cursorHistory: [(startCursorScreen, CACurrentMediaTime())],
            placeholderIndex: originIndex,
            directSwapMode: directSwap,
            anchorPositions: anchors,
            undoSnapshot: state.snapshotForUndo()
        )
        return true
    }

    /// Per-tick reorder update. The dragged element follows the cursor
    /// directly (in world coords). The other elements stay anchored at
    /// their original positions UNLESS a swap fires.
    func updateReorderDrag(
        currentCursorScreen: CGPoint,
        cursorWorldTranslation: CGSize,
        zoom: CGFloat
    ) {
        guard var drag = reorderDrag, let layout else { return }

        // Update cursor history (cap at 4 samples — treatise's velocity window).
        let now = CACurrentMediaTime()
        drag.cursorHistory.append((currentCursorScreen, now))
        if drag.cursorHistory.count > 4 {
            drag.cursorHistory.removeFirst(drag.cursorHistory.count - 4)
        }

        // Position the dragged element to follow the cursor in world space.
        guard let draggedNode = state.nodeByID[drag.elementID],
              let origin = drag.anchorPositions[drag.elementID] else { return }
        let draggedPos = CGPoint(
            x: origin.x + cursorWorldTranslation.width,
            y: origin.y + cursorWorldTranslation.height
        )
        state.updatePosition(of: drag.elementID, to: draggedPos)

        // Velocity-predicted dragged rect (one frame ahead) — treatise's
        // "continuous velocity vector based on the cursor's drag direction."
        let predicted = predictNextRect(
            currentRect: CGRect(
                x: draggedPos.x, y: draggedPos.y,
                width: draggedNode.width,
                height: state.renderedHeight(of: draggedNode)
            ),
            history: drag.cursorHistory,
            zoom: zoom
        )

        // 50%-intersection swap check against every sibling currently
        // occupying its layout slot (using the placeholder-index
        // arithmetic so we test against the *new* slot positions).
        let siblings = layout.flatOrderedIDs
        for siblingIdx in siblings.indices where siblings[siblingIdx] != drag.elementID {
            let siblingID = siblings[siblingIdx]
            guard let sibling = state.nodeByID[siblingID] else { continue }
            let sRect = CGRect(
                x: sibling.position.x, y: sibling.position.y,
                width: sibling.width,
                height: state.renderedHeight(of: sibling)
            )
            let curRatio = intersectionRatio(of: draggedPos.rect(width: draggedNode.width,
                                                                  height: state.renderedHeight(of: draggedNode)),
                                              against: sRect)
            let predRatio = intersectionRatio(of: predicted, against: sRect)
            let trigger = max(curRatio, predRatio)
            if trigger >= 0.5 {
                if drag.directSwapMode {
                    // Direct swap: swap originIndex with siblingIdx once.
                    if drag.placeholderIndex == drag.originIndex {
                        swapPositionsInModel(
                            a: drag.elementID,
                            b: siblingID,
                            anchors: drag.anchorPositions
                        )
                        drag.placeholderIndex = siblingIdx
                        Haptics.tap()   // one tap per direct swap
                    }
                } else {
                    // Reflow: move the placeholder to siblingIdx and re-lay
                    // every sibling (except dragged) onto the new slot
                    // arrangement, animated implicitly by `animation(.timingCurve)`.
                    if drag.placeholderIndex != siblingIdx {
                        drag.placeholderIndex = siblingIdx
                        reflowOnPlaceholderMove(layout: layout, drag: drag)
                        Haptics.tap()   // one tap per index slot crossed
                    }
                }
                break    // one swap per tick
            }
        }

        reorderDrag = drag
    }

    /// Snap the dragged element to the placeholder's world position and
    /// commit. One undo entry covers the entire drag.
    func endReorderDrag() {
        guard let drag = reorderDrag, let layout else {
            reorderDrag = nil
            return
        }
        // Re-build the abstract array with the dragged element at
        // placeholderIndex, then place every node onto its computed slot.
        var order = layout.flatOrderedIDs
        order.removeAll { $0 == drag.elementID }
        let insertAt = min(drag.placeholderIndex, order.count)
        order.insert(drag.elementID, at: insertAt)
        placeOnSlots(orderedIDs: order, layout: layout, anchors: drag.anchorPositions)
        reorderDrag = nil
        state.commitUndoable(from: drag.undoSnapshot)
    }

    /// Cancel a reorder drag without committing (e.g. Escape mid-drag).
    func cancelReorderDrag() {
        guard let drag = reorderDrag else { return }
        // Restore every anchor.
        for (id, pos) in drag.anchorPositions {
            state.updatePosition(of: id, to: pos)
        }
        reorderDrag = nil
    }

    // MARK: - Reorder helpers

    private func reflowOnPlaceholderMove(layout: SmartSelectionLayout, drag: SmartDragState) {
        // Compute the new ordering with the placeholder at its current index.
        var order = layout.flatOrderedIDs
        order.removeAll { $0 == drag.elementID }
        let insertAt = min(drag.placeholderIndex, order.count)
        order.insert(drag.elementID, at: insertAt)
        // Place every sibling onto its new slot; the dragged element is
        // re-positioned right after, by the caller (followCursor).
        placeOnSlots(
            orderedIDs: order,
            layout: layout,
            anchors: drag.anchorPositions,
            excluding: [drag.elementID]
        )
    }

    private func placeOnSlots(
        orderedIDs: [UUID],
        layout: SmartSelectionLayout,
        anchors: [UUID: CGPoint],
        excluding: Set<UUID> = []
    ) {
        switch layout {
        case .row1D(let originalIDs, let gap, _):
            guard let firstAnchor = anchors[originalIDs.first ?? UUID()] else { return }
            var cursorX = firstAnchor.x
            for id in orderedIDs {
                guard let node = state.nodeByID[id] else { continue }
                if !excluding.contains(id) {
                    state.updatePosition(of: id, to: CGPoint(x: cursorX, y: firstAnchor.y))
                }
                cursorX += node.width + gap
            }
        case .column1D(let originalIDs, let gap, _):
            guard let firstAnchor = anchors[originalIDs.first ?? UUID()] else { return }
            var cursorY = firstAnchor.y
            for id in orderedIDs {
                guard let node = state.nodeByID[id] else { continue }
                if !excluding.contains(id) {
                    state.updatePosition(of: id, to: CGPoint(x: firstAnchor.x, y: cursorY))
                }
                cursorY += state.renderedHeight(of: node) + gap
            }
        case .grid2D(let rows, let gapX, let gapY):
            // Original 2D shape: same rows × cols. We treat `orderedIDs`
            // as a row-major flat sequence, repacking into the same
            // rectangle. Treatise: deletion wraps "start of row n+1 into
            // tail of row n" — emerges from modulo arithmetic.
            let cols = rows.first?.count ?? 0
            guard cols > 0, let firstAnchor = anchors[rows.first?.first ?? UUID()] else { return }
            for (i, id) in orderedIDs.enumerated() {
                guard let node = state.nodeByID[id] else { continue }
                let r = i / cols
                let c = i % cols
                // Anchor + accumulated row heights + accumulated col widths.
                // (For simplicity we approximate with the first node's
                // size — fine for grids where cells are uniform, which is
                // the only valid Grid2D in this app.)
                let x = firstAnchor.x + CGFloat(c) * (node.width + gapX)
                let y = firstAnchor.y + CGFloat(r) * (state.renderedHeight(of: node) + gapY)
                if !excluding.contains(id) {
                    state.updatePosition(of: id, to: CGPoint(x: x, y: y))
                }
            }
        }
    }

    private func swapPositionsInModel(a: UUID, b: UUID, anchors: [UUID: CGPoint]) {
        guard let pa = anchors[a], let pb = anchors[b] else { return }
        state.updatePosition(of: a, to: pb)
        state.updatePosition(of: b, to: pa)
    }

    private func intersectionRatio(of a: CGRect, against b: CGRect) -> Double {
        let interW = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let interH = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        let inter = Double(interW) * Double(interH)
        let target = Double(b.width) * Double(b.height)
        return target > 0 ? inter / target : 0
    }

    /// 1-frame-ahead velocity prediction. Uses the last two samples to
    /// estimate cursor velocity (screen units / second) and projects the
    /// dragged rect along that vector by 1/60 s, dividing by zoom to
    /// reach world units.
    private func predictNextRect(
        currentRect: CGRect,
        history: [(point: CGPoint, time: TimeInterval)],
        zoom: CGFloat
    ) -> CGRect {
        guard history.count >= 2 else { return currentRect }
        let last = history.last!
        let prev = history[history.count - 2]
        let dt = max(1e-6, last.time - prev.time)
        let vx = (last.point.x - prev.point.x) / CGFloat(dt)
        let vy = (last.point.y - prev.point.y) / CGFloat(dt)
        let frameSeconds: CGFloat = 1.0 / 60.0
        let z = max(zoom, 0.0001)
        let dx = vx * frameSeconds / z
        let dy = vy * frameSeconds / z
        return currentRect.offsetBy(dx: dx, dy: dy)
    }

    // MARK: - Cascade delete + duplicate

    /// Delete every marked element and reflow remaining siblings into
    /// the void. One undo entry. (Outside Smart Selection, the
    /// keyboard monitor passes through to `state.deleteSelected()`.)
    func deleteMarked() {
        guard let layout, !markedIDs.isEmpty else { return }
        let order = layout.flatOrderedIDs
        let kept = order.filter { !markedIDs.contains($0) }

        let before = state.snapshotForUndo()
        // Capture anchors BEFORE deletion so the reflow has the original geometry.
        var anchors: [UUID: CGPoint] = [:]
        for id in order {
            if let n = state.nodeByID[id] { anchors[id] = n.position }
        }
        // Delete via the existing per-node path; we accumulate one undo
        // entry via the outer `commitUndoable`.
        for id in markedIDs {
            state.delete(id: id)
        }
        // Reflow the remaining elements onto the original slot grid.
        placeOnSlots(orderedIDs: kept, layout: layout, anchors: anchors)
        markedIDs = []
        state.commitUndoable(from: before)
        // The classifier will re-run via the Combine pipeline.
    }

    /// Duplicate every marked element, inserting each clone immediately
    /// after its source in the abstract order. Then reflow.
    func duplicateMarked() {
        guard let layout, !markedIDs.isEmpty else { return }
        let order = layout.flatOrderedIDs
        var anchors: [UUID: CGPoint] = [:]
        for id in order {
            if let n = state.nodeByID[id] { anchors[id] = n.position }
        }

        let before = state.snapshotForUndo()
        // duplicateNodes is itself undoable; the outer commit collapses
        // them via the re-entrant `undoDepth` guard.
        let copies = state.duplicateNodes(markedIDs)
        // Map original → copy by matching positions (duplicateNodes copies
        // the original's position verbatim, so we identify pairs by
        // "share position" lookup).
        var copyByOriginal: [UUID: UUID] = [:]
        for id in markedIDs {
            guard let originalPos = anchors[id] else { continue }
            if let match = copies.first(where: { copyID in
                state.nodeByID[copyID]?.position == originalPos
            }) {
                copyByOriginal[id] = match
            }
        }
        // New abstract ordering: insert each copy immediately after its source.
        var newOrder: [UUID] = []
        for id in order {
            newOrder.append(id)
            if let copy = copyByOriginal[id] {
                newOrder.append(copy)
            }
        }
        // Update markedIDs to point at the copies (Figma-style — newly
        // duplicated content stays selected).
        markedIDs = Set(copyByOriginal.values)
        // Reflow onto the original slot grid (sizes may now overflow if
        // the grid was tight — that's expected, Tidy Up can be re-run).
        placeOnSlots(orderedIDs: newOrder, layout: layout, anchors: anchors)
        // Also bring the new copies into the selection so chrome re-includes them.
        state.selectNodes(state.selectedNodeIDs.union(copyByOriginal.values))
        state.commitUndoable(from: before)
    }
}

// MARK: - Convenience

private extension CGPoint {
    /// Build a rect anchored at this point with the supplied size.
    func rect(width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
