import SwiftUI
import AppKit
import AVFoundation
import Combine

// Split out of CanvasState.swift (god-object refactor): node mutation,
// pasteboard (cut/copy/paste/z-order) and duplicate.
extension CanvasState {

    // MARK: - Node mutation

    /// Fast in-place single-node mutation for hot-path field writes
    /// (drag, resize). Bypasses the `nodes` computed setter — so it does
    /// NOT rebuild the whole `nodeByID` index or the archive-days cache
    /// on every tick — and patches `nodeByID` for just the one key.
    /// Structural edits (add / delete / reorder) still go through the
    /// `nodes` setter, which rebuilds the index wholesale.
    func mutateNode(_ id: UUID, _ transform: (inout CanvasNode) -> Void) {
        let pageIdx = activePageIndex
        guard pages.indices.contains(pageIdx),
              let nodeIdx = pages[pageIdx].nodes.firstIndex(where: { $0.id == id })
        else { return }
        var node = pages[pageIdx].nodes[nodeIdx]
        transform(&node)
        nodeByID[id] = node
        pages[pageIdx].nodes[nodeIdx] = node
    }

    func updatePosition(of id: UUID, to position: CGPoint) {
        mutateNode(id) { $0.position = position }
    }

    /// Resize a node. Width is always written; height is written for any
    /// node kind that has a fixed height (everything except auto-sizing
    /// tweets / text — those keep nil so they continue auto-sizing).
    /// Caller passes a frame; we clamp to the kind's `minSize`.
    func resize(id: UUID, frame: CGRect) {
        mutateNode(id) { node in
            let minSize = node.kind.minSize
            node.position = CGPoint(x: frame.minX, y: frame.minY)
            node.width = max(minSize.width, frame.width)
            switch node.kind {
            case .text:
                // Text auto-sizes; never write an explicit height.
                break
            default:
                node.height = max(minSize.height, frame.height)
            }
        }
    }

    /// A media card (tweet) resolved its real media aspect asynchronously —
    /// snap the node's height to it so the aspect-fit card fills its frame
    /// instead of leaving a gray gap around it. Routed through `resize` so it
    /// persists + re-lays out (not a separate undoable action). Idempotent:
    /// no-ops once the height already matches, so it can't fight a user's
    /// aspect-locked resize.
    func snapMediaAspect(_ id: UUID, aspect: CGFloat) {
        guard aspect > 0.01, let n = nodeByID[id] else { return }
        let target = (n.width / aspect).rounded()
        guard abs((n.height ?? -1) - target) > 1 else { return }
        resize(id: id, frame: CGRect(x: n.position.x, y: n.position.y,
                                     width: n.width, height: target))
    }

    /// Insert a copy of `id` at the same position with a fresh UUID.
    /// Used by Option-drag and ⌘D duplicate.
    @discardableResult
    func duplicateNode(_ id: UUID) -> UUID? {
        guard let original = nodeByID[id] else { return nil }
        let copy = CanvasNode(
            position: original.position,
            width: original.width,
            height: original.height,
            kind: original.kind
        )
        withUndoable { nodes.append(copy) }
        return copy.id
    }

    // MARK: - Pasteboard / cut / copy / paste / Z-order

    /// Custom pasteboard type used to cut & paste nodes (+ their internal
    /// connectors) between operations. Plain-text URL paste still works
    /// via `pasteFromClipboard()` — the two layers don't conflict.
    static let nodePasteboardType =
        NSPasteboard.PasteboardType("com.embeddedvideocanvas.nodes")

    /// Codable payload written to the pasteboard.
    private struct NodeClipboard: Codable {
        var nodes: [CanvasNode]
        var connectors: [Connector]
    }

    /// Copy the current selection onto the pasteboard. Connectors are
    /// included only if BOTH endpoints are inside the selected set.
    func copySelection() {
        guard !selectedNodeIDs.isEmpty else { return }
        let selectedNodes = nodes.filter { selectedNodeIDs.contains($0.id) }
        let internalConnectors = connectors.filter {
            selectedNodeIDs.contains($0.sourceID) && selectedNodeIDs.contains($0.targetID)
        }
        guard let data = try? JSONEncoder().encode(
            NodeClipboard(nodes: selectedNodes, connectors: internalConnectors)
        ) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: Self.nodePasteboardType)
    }

    /// Copy + delete.
    func cutSelection() {
        copySelection()
        deleteSelected()
    }

    /// Paste from the pasteboard.
    ///   • If the pasteboard contains our node payload → insert those nodes
    ///     (with fresh UUIDs) onto the current page, slightly offset.
    ///   • Otherwise → fall through to the existing URL-paste flow.
    func pasteFromPasteboard() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: Self.nodePasteboardType),
           let payload = try? JSONDecoder().decode(NodeClipboard.self, from: data) {
            paste(payload: payload)
        } else {
            pasteFromClipboard()
        }
    }

    private func paste(payload: NodeClipboard) {
        guard !payload.nodes.isEmpty else { return }
        // Rewrite every UUID so pasted nodes don't collide with existing ones
        // (and so connector endpoints can be remapped to the new ids).
        var idMap: [UUID: UUID] = [:]
        for n in payload.nodes { idMap[n.id] = UUID() }
        // Drop the group CENTRED on the viewport ("paste where I'm looking") rather
        // than at the original coords +24 — so it lands on-screen on whatever page
        // / scroll position you're viewing. The group's internal layout is kept.
        let minX = payload.nodes.map { $0.position.x }.min() ?? 0
        let minY = payload.nodes.map { $0.position.y }.min() ?? 0
        let maxX = payload.nodes.map { $0.position.x + $0.width }.max() ?? 0
        let maxY = payload.nodes.map { $0.position.y + ($0.height ?? 120) }.max() ?? 0
        let groupCentre = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let target = screenToWorld(point: viewportCentre)
        let dx = target.x - groupCentre.x, dy = target.y - groupCentre.y
        let newNodes: [CanvasNode] = payload.nodes.map { n in
            CanvasNode(
                id: idMap[n.id] ?? UUID(),
                position: CGPoint(x: n.position.x + dx, y: n.position.y + dy),
                width: n.width,
                height: n.height,
                kind: n.kind
            )
        }
        let newConnectors: [Connector] = payload.connectors.compactMap { c in
            guard let s = idMap[c.sourceID], let t = idMap[c.targetID] else { return nil }
            return Connector(sourceID: s, targetID: t, label: c.label,
                             sourceSide: c.sourceSide, targetSide: c.targetSide,
                             labelOffset: c.labelOffset)
        }
        withUndoable {
            nodes.append(contentsOf: newNodes)
            connectors.append(contentsOf: newConnectors)
        }
        selectedNodeIDs = Set(newNodes.map(\.id))
        selectedConnectorIDs = []
    }

    /// Move the given node ids to the END of the array (front in z-order
    /// because we render via `ForEach` and later items paint on top).
    func bringToFront(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        withUndoable {
            let moving = nodes.filter { ids.contains($0.id) }
            let rest   = nodes.filter { !ids.contains($0.id) }
            nodes = rest + moving
        }
    }

    /// Move the given node ids to the START of the array (back in z-order).
    func sendToBack(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        withUndoable {
            let moving = nodes.filter { ids.contains($0.id) }
            let rest   = nodes.filter { !ids.contains($0.id) }
            nodes = moving + rest
        }
    }

    // MARK: - Duplicate (continued)

    /// Duplicate every given node id; returns the set of new copies.
    /// One undo entry covers the whole batch via re-entrant `withUndoable`.
    ///
    /// Card-stack semantics: each duplicated group gets a fresh `groupID`
    /// shared by all of its copies, so the result is a new stack that
    /// can be moved + ungrouped independently of its source. Sections
    /// are duplicated as-is — their members are copied via the seed
    /// expansion (`expandedDragSet`) and continue to render at their
    /// duplicated positions.
    @discardableResult
    /// Live (per-tick, non-undoable) rotation set while dragging the rotate
    /// handle. Undo is provided by the drag-start page snapshot, like resize.
    func setRotation(id: UUID, to radians: CGFloat) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[idx].rotation = radians
    }

    /// Option-drag: AFTER the originals have been dragged to their drop, drop a
    /// clone of each at its ORIGINAL position (`startPositions[id]`). Done on
    /// mouse-up — never mid-drag — so dragging stays smooth (no live duplicate of
    /// a heavy web/video card rendering every frame). One undo entry.
    func leaveCopies(at startPositions: [UUID: CGPoint]) {
        let expanded = expandedDragSet(from: Set(startPositions.keys))
        guard !expanded.isEmpty else { return }
        var freshGroupForOriginal: [UUID: UUID] = [:]
        withUndoable {
            for original in nodes where expanded.contains(original.id) {
                let newGroupID: UUID? = {
                    guard let g = original.groupID else { return nil }
                    if let existing = freshGroupForOriginal[g] { return existing }
                    let fresh = UUID(); freshGroupForOriginal[g] = fresh; return fresh
                }()
                let copy = CanvasNode(
                    position: startPositions[original.id] ?? original.position,
                    width: original.width,
                    height: original.height,
                    kind: original.kind,
                    groupID: newGroupID,
                    folderID: nil,                 // copies live on the board, not inside a folder
                    origin: original.origin,
                    name: original.name, note: original.note, linkURL: original.linkURL,
                    tags: original.tags, imagePrompt: original.imagePrompt,
                    trimStart: original.trimStart, trimEnd: original.trimEnd,
                    folderColor: original.folderColor,
                    attributedContent: original.attributedContent,
                    rotation: original.rotation)
                nodes.append(copy)
            }
        }
    }

    func duplicateNodes(_ ids: Set<UUID>) -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        // Expand so a stack head pulls its hidden members; without this
        // a stack duplicate would clone the head only, orphaning the
        // (now uncloned) members under a still-shared groupID.
        let expanded = expandedDragSet(from: ids)
        // One fresh groupID per original group, so duplicates form an
        // independent new stack instead of merging into the original.
        var freshGroupForOriginal: [UUID: UUID] = [:]
        var copies: Set<UUID> = []
        withUndoable {
            for original in nodes where expanded.contains(original.id) {
                let newGroupID: UUID? = {
                    guard let originalGroup = original.groupID else { return nil }
                    if let existing = freshGroupForOriginal[originalGroup] {
                        return existing
                    }
                    let fresh = UUID()
                    freshGroupForOriginal[originalGroup] = fresh
                    return fresh
                }()
                let copy = CanvasNode(
                    position: original.position,
                    width: original.width,
                    height: original.height,
                    kind: original.kind,
                    groupID: newGroupID
                )
                nodes.append(copy)
                copies.insert(copy.id)
            }
        }
        return copies
    }
}
