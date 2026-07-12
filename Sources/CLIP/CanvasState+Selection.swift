import SwiftUI
import AppKit
import AVFoundation
import Combine

// Split out of CanvasState.swift (god-object refactor): drawing, selection/deletion, drag-active broadcast, connectors.
extension CanvasState {


    // MARK: - Drawing

    /// Convert a screen-space stroke into a drawing node (in world coords).
    func commitStroke(screenPoints: [CGPoint]) {
        guard screenPoints.count >= 2 else { return }
        commitStroke(worldPoints: screenPoints.map { screenToWorld(point: $0) })
    }

    /// Commit a stroke whose points are ALREADY in world coords (the native
    /// `CanvasInputView` draw path — its own coordinate system is content space,
    /// so it converts content→world itself and skips `screenToWorld`).
    func commitStroke(worldPoints world: [CGPoint]) {
        guard world.count >= 2 else { return }
        let simplified = PathMath.simplify(world, epsilon: 1.5)
        let pad = drawWidth + 4
        let bounds = PathMath.paddedBounds(of: simplified, pad: pad)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let local = simplified.map { CGPoint(x: $0.x - bounds.minX,
                                              y: $0.y - bounds.minY) }
        let stroke = DrawingStroke(points: local, color: drawColor, width: drawWidth, opacity: drawOpacity)

        withUndoable {
            nodes.append(.drawing(stroke: stroke,
                                  position: bounds.origin,
                                  size: bounds.size))
        }
    }

    // MARK: - Selection / deletion

    /// Select exactly one node (or clear if nil). Always clears connector selection.
    func select(_ id: UUID?) {
        selectedNodeIDs = id.map { [$0] } ?? []
        selectedConnectorIDs = []
    }

    /// Reveal a node from anywhere (⌘K search, Outline list): switch to its
    /// page if needed, then centre + select it. When a page switch happens
    /// the center/select runs on the next main-actor turn, after `switchTo`
    /// has rebuilt `nodeByID` and cleared the old selection.
    func jumpToNode(_ nodeID: UUID, onPage pageID: UUID) {
        if pageID != activePageID {
            if canvasMode != .canvas { setMode(.canvas) }
            switchTo(pageID: pageID)
            Task { @MainActor in self.frameAndSelect(nodeID) }
        } else {
            if canvasMode != .canvas { setMode(.canvas) }
            frameAndSelect(nodeID)
        }
    }

    private func frameAndSelect(_ nodeID: UUID) {
        guard let n = nodeByID[nodeID] else { return }
        let centre = CGPoint(x: n.position.x + n.width / 2,
                             y: n.position.y + renderedHeight(of: n) / 2)
        centerCamera(on: centre)
        select(nodeID)
    }

    /// Replace selection with the given set of node ids.
    func selectNodes(_ ids: Set<UUID>) {
        selectedNodeIDs = ids
        selectedConnectorIDs = []
    }

    /// Toggle a node in/out of the current selection (Shift+click semantics).
    func toggleNodeSelection(_ id: UUID) {
        if selectedNodeIDs.contains(id) {
            selectedNodeIDs.remove(id)
        } else {
            selectedNodeIDs.insert(id)
            selectedConnectorIDs = []
        }
    }

    /// Select exactly one connector (or clear). Always clears node selection.
    func selectConnector(_ id: UUID?) {
        selectedConnectorIDs = id.map { [$0] } ?? []
        selectedNodeIDs = []
    }

    /// Set (or clear) a connector's midpoint label. Trimmed; undoable.
    func setConnectorLabel(_ id: UUID, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = connectors.firstIndex(where: { $0.id == id }),
              connectors[idx].label != trimmed else { return }
        withUndoable { connectors[idx].label = trimmed }
    }

    /// Persist a dragged label's offset from the bezier midpoint (content units).
    func setConnectorLabelOffset(_ id: UUID, _ offset: CGPoint) {
        guard let idx = connectors.firstIndex(where: { $0.id == id }) else { return }
        withUndoable { connectors[idx].labelOffset = offset }
    }

    func toggleConnectorSelection(_ id: UUID) {
        if selectedConnectorIDs.contains(id) {
            selectedConnectorIDs.remove(id)
        } else {
            selectedConnectorIDs.insert(id)
            selectedNodeIDs = []
        }
    }

    func deselectAll() {
        selectedNodeIDs = []
        selectedConnectorIDs = []
    }

    func selectAll() {
        selectedNodeIDs = Set(nodes.map { $0.id })
        selectedConnectorIDs = []
    }

    /// Convert a screen-space rectangle to world coords and select every
    /// node whose rectangle intersects it. Used at the end of a marquee
    /// drag (or any one-shot call site); the live in-flight version is
    /// `liveSelectInMarquee(screenRect:base:additive:)`.
    func selectNodesIn(screenRect: CGRect, additive: Bool) {
        let hits = nodeIDs(intersectingScreenRect: screenRect)
        if additive {
            selectedNodeIDs.formUnion(hits)
        } else {
            selectedNodeIDs = hits
            selectedConnectorIDs = []
        }
    }

    /// Live (per-tick) marquee selection. `base` is the user's selection
    /// at the moment the drag began; on every tick the result is either
    /// `base ∪ hits` (shift held) or just `hits` (no modifier) — so
    /// shrinking the marquee past a node correctly deselects it.
    func liveSelectInMarquee(screenRect: CGRect,
                             base: Set<UUID>,
                             additive: Bool) {
        let hits = nodeIDs(intersectingScreenRect: screenRect)
        selectedNodeIDs = additive ? base.union(hits) : hits
        selectedConnectorIDs = []
    }

    /// Find every node whose world rect intersects the given screen-space
    /// rect. Single source of truth for marquee hit-tests.
    private func nodeIDs(intersectingScreenRect rect: CGRect) -> Set<UUID> {
        let z = camera.zoom
        guard z > 0 else { return [] }
        let world = CGRect(
            x: (rect.minX - camera.x) / z,
            y: (rect.minY - camera.y) / z,
            width:  rect.width  / z,
            height: rect.height / z
        )
        return Set(nodes.compactMap { node in
            let r = CGRect(x: node.position.x, y: node.position.y,
                           width: node.width, height: renderedHeight(of: node))
            return world.intersects(r) ? node.id : nil
        })
    }

    func delete(id: UUID) {
        removeNodesAndCascade([id], extraConnectorIDs: [])
    }

    func deleteConnector(id: UUID) {
        withUndoable {
            connectors.removeAll { $0.id == id }
        }
        selectedConnectorIDs.remove(id)
    }

    /// Remove every selected node and connector in one pass — coalesced
    /// into a single undo entry via re-entrant `withUndoable`.
    func deleteSelected() {
        removeNodesAndCascade(selectedNodeIDs, extraConnectorIDs: selectedConnectorIDs)
    }

    /// Single removal pipeline used by `delete(id:)` and `deleteSelected`.
    /// Expands the seed set with any contents of selected sections, every
    /// member of a referenced card-stack, drops dangling connectors, and
    /// clears transient per-node state — all in one undo entry.
    private func removeNodesAndCascade(_ seed: Set<UUID>,
                                       extraConnectorIDs: Set<UUID>) {
        guard !seed.isEmpty || !extraConnectorIDs.isEmpty else { return }

        // Compute the full deletion set up front so we don't re-traverse
        // for each id (and don't risk order-dependent behaviour).
        var allIDs = seed
        for id in seed {
            if let rect = sectionRect(of: id) {
                allIDs.formUnion(nodeIDs(insideWorldRect: rect))
            }
        }
        // Any card-stack head (or member) in the seed brings its entire
        // group along — deleting a stack must take its hidden members
        // with it, otherwise they become orphaned with a dangling
        // `groupID` and stay invisible forever.
        allIDs.formUnion(expandedDragSet(from: allIDs))

        let removedCount = nodes.lazy.filter { allIDs.contains($0.id) }.count
        withUndoable {
            nodes.removeAll { allIDs.contains($0.id) }
            connectors.removeAll { c in
                allIDs.contains(c.sourceID)
                || allIDs.contains(c.targetID)
                || extraConnectorIDs.contains(c.id)
            }
            // Prune deleted ids from any folder's contents (no dangling children).
            for i in nodes.indices {
                if case .folder(let t, let ic, let kids) = nodes[i].kind,
                   kids.contains(where: { allIDs.contains($0) }) {
                    nodes[i].kind = .folder(title: t, icon: ic,
                                            childIDs: kids.filter { !allIDs.contains($0) })
                }
            }
        }

        for cid in allIDs {
            measuredHeights.removeValue(forKey: cid)
            selectedNodeIDs.remove(cid)
            if pendingFocusNodeID == cid { pendingFocusNodeID = nil }
            // Release any cached web view / player for this card now, rather than
            // letting it idle through the cache's deferred-teardown window (a
            // deleted card shouldn't keep a WKWebView/AVPlayer alive). No-op when
            // the cache is off or the node was never cached.
            if FeatureFlags.useWebViewCache {
                WebViewCache.shared.evict(cid)
                PlayerCache.shared.evict(cid)
                NativeVideoCache.shared.evict(cid)
            }
        }
        selectedConnectorIDs.subtract(extraConnectorIDs)

        // If the unfolded folder was just deleted, re-fold to the main canvas.
        if let f = focusedFolderID, !nodes.contains(where: { $0.id == f }) {
            exitFolderFocus()
        }

        // Deletion leaves no visible trace where the cards were — confirm
        // it happened (and remind that it's reversible).
        if removedCount > 0 {
            showToast(
                removedCount == 1
                    ? "Deleted 1 card — ⌘Z to undo"
                    : "Deleted \(removedCount) cards — ⌘Z to undo",
                systemImage: "trash"
            )
        }
    }

    // Kept for backward-compat with menu wiring.
    func deleteSelectedNode() { deleteSelected() }

    // MARK: - Drag-active broadcast

    /// Called by `DraggableNode.initDrag` to publish "this node is
    /// being dragged" + which other nodes are connected to it. Used
    /// by `DraggableNode` to apply a small tug offset on its
    /// connected peers while the drag is active.
    func beginDrag(of id: UUID) {
        let connected: Set<UUID> = connectors.reduce(into: []) { acc, c in
            if c.sourceID == id { acc.insert(c.targetID) }
            if c.targetID == id { acc.insert(c.sourceID) }
        }
        withAnimation(Motion.pop) {
            activeDragID = id
            activeDragConnectedIDs = connected
        }
    }

    /// Mirror of `beginDrag(of:)` — called from `DraggableNode`'s
    /// drag-end (inside the same `withAnimation` block as the position
    /// spring so the tug releases in lockstep with the position).
    func endDrag() {
        activeDragID = nil
        activeDragConnectedIDs = []
    }

    // MARK: - Connectors

    /// Append a directed arrow from `source` to `target`, deduping if it
    /// already exists in either direction.
    func addConnector(from source: UUID, to target: UUID,
                      sourceSide: ConnSide? = nil, targetSide: ConnSide? = nil) {
        guard source != target else { return }
        let exists = connectors.contains {
            ($0.sourceID == source && $0.targetID == target) ||
            ($0.sourceID == target && $0.targetID == source)
        }
        guard !exists else { return }
        withUndoable {
            connectors.append(Connector(sourceID: source, targetID: target,
                                        sourceSide: sourceSide, targetSide: targetSide))
        }
        // Threshold haptic — the connector "landed" on a target node.
        Haptics.threshold()
    }

    /// Top-most node that contains the given world point, ignoring drawing
    /// nodes (they have non-rectangular hit shapes that look wrong as
    /// connector targets).
    func nodeAt(world point: CGPoint) -> CanvasNode? {
        for node in nodes.reversed() {
            if case .drawing = node.kind { continue }
            let h = renderedHeight(of: node)
            let rect = CGRect(x: node.position.x, y: node.position.y,
                              width: node.width, height: h)
            if rect.contains(point) { return node }
        }
        return nil
    }

    /// Best-known rendered height of a node — uses the explicit field for
    /// drawings, the live measurement for tweet/text, otherwise a default.
    func renderedHeight(of node: CanvasNode) -> CGFloat {
        if let h = node.height { return h }
        if let h = measuredHeights[node.id] { return h }
        switch node.kind {
        case .tweet:      return 220
        case .instagram:  return 540
        case .text:       return 56
        case .drawing:    return 100
        case .image:      return 360
        case .video:      return 270
        case .youtube:    return 203
        case .webclip:    return 320
        case .section:    return 200
        case .stickyNote: return 200
        case .folder:     return 224
        }
    }

    func reportMeasuredHeight(_ height: CGFloat, for id: UUID) {
        guard height > 0 else { return }
        // Skip sub-pixel jitter up front so a stable layout never schedules
        // a flush at all.
        guard abs((measuredHeights[id] ?? -1) - height) > 0.5 else { return }
        pendingHeights[id] = height
        guard !heightFlushScheduled else { return }
        heightFlushScheduled = true
        // Defer the @Published write off the current layout pass.
        // DispatchQueue.main.async is required here rather than
        // Task { @MainActor in }: on macOS 27 beta, CA::Transaction::flush
        // can drain Swift Concurrency tasks mid-layout, so the Task-based
        // deferral fires while _layoutSubtreeWithOldSize is still on the
        // stack, writing measuredHeights re-enters layout, and AppKit's
        // recursion guard trips at depth 16. DispatchQueue.main.async
        // always defers to the NEXT main queue drain (after the display
        // callback has returned to the runloop), breaking the cycle.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.flushMeasuredHeights() }
        }
    }

    /// Apply buffered height reports in one batch (one `objectWillChange`),
    /// on a fresh main-actor turn so it can't recurse into the layout pass
    /// that produced them.
    private func flushMeasuredHeights() {
        heightFlushScheduled = false
        guard !pendingHeights.isEmpty else { return }
        for (id, h) in pendingHeights {
            if abs((measuredHeights[id] ?? -1) - h) > 0.5 {
                measuredHeights[id] = h
            }
        }
        pendingHeights.removeAll(keepingCapacity: true)
    }
}
