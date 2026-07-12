import SwiftUI
import AppKit
import AVFoundation
import Combine

// Split out of CanvasState.swift (god-object refactor): card-stack grouping + stack focus mode.
extension CanvasState {


    // MARK: - Card-stack grouping (⌘G / ⌘⇧G)

    /// Animated collapse: every non-head member spring-glides to the
    /// head's position with a small per-card stagger, then the
    /// `groupID` assignment lands and the stack visual takes over.
    /// One undo entry covers the full sequence so ⌘Z restores every
    /// original position in a single hop.
    ///
    /// The "head" of the group — the only member that renders on the
    /// canvas once the animation completes — is the node with the
    /// smallest UUID string within the set. Non-head members stay in
    /// `nodes` (so undo + Codable + drag-translation continue to work)
    /// but are hidden from rendering by `isHiddenByStack(_:)` once
    /// their `groupID` is set.
    @discardableResult
    func groupSelection() -> UUID? {
        // Ignore sections + already-grouped nodes; require at least two
        // candidates for a group to make sense.
        let candidates = selectedNodeIDs.compactMap { id -> CanvasNode? in
            guard let n = nodeByID[id], !n.isSection, n.groupID == nil else { return nil }
            return n
        }
        guard candidates.count >= 2 else { return nil }
        showToast("Grouped \(candidates.count) cards", systemImage: "square.stack.3d.up")
        let newGroupID = UUID()
        let head = candidates.min { $0.id.uuidString < $1.id.uuidString }!
        let headPos = head.position
        // Non-head members ordered by initial distance from the head:
        // closer cards arrive first, far cards trail. Makes the deck
        // assemble visibly rather than teleport.
        let movers = candidates
            .filter { $0.id != head.id }
            .sorted { lhs, rhs in
                let dl = hypot(lhs.position.x - headPos.x, lhs.position.y - headPos.y)
                let dr = hypot(rhs.position.x - headPos.x, rhs.position.y - headPos.y)
                return dl < dr
            }

        let before = snapshotForUndo()
        // Commit the group NOW — a keyboard action's state must never lag
        // its animation. ⌘Z, a second ⌘G, or a drag during the converge
        // all read committed state. `groupFormationInFlight` keeps the
        // movers visible (see `isHiddenByStack`) so the converge below
        // still plays as pure decoration over committed state.
        groupFormationInFlight.formUnion(movers.map(\.id))
        for c in candidates {
            mutateNode(c.id) { node in
                node.groupID = newGroupID
            }
        }
        // Converge decoration — spring-glide each member to the head's
        // position with a 30ms stagger. `updatePosition` writes the model
        // value synchronously; only the animation is delayed.
        let stagger: Double = 0.03
        for (i, mover) in movers.enumerated() {
            withAnimation(Motion.structure.delay(Double(i) * stagger)) {
                self.updatePosition(of: mover.id, to: headPos)
            }
        }
        // One undoable covering groupIDs + positions, committed before
        // the decoration finishes.
        commitUndoable(from: before)
        // End of converge: purely visual cleanup (safe against undo —
        // clearing the set never mutates the model) + the "deck formed"
        // haptic timed to the visual settle.
        let totalDuration = Double(max(0, movers.count - 1)) * stagger
            + Motion.structureResponse
        let moverIDs = movers.map(\.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration) { [weak self] in
            guard let self else { return }
            self.groupFormationInFlight.subtract(moverIDs)
            Haptics.threshold()
        }
        // Selection should immediately track the visible representative
        // (the head) — the stack-classifier and Smart Selection both
        // observe `selectedNodeIDs` and need to react before stage 2.
        select(head.id)
        return newGroupID
    }

    /// Animated eruption: clear every member's `groupID` first (so they
    /// re-appear at the head's position — they all share `headPos` while
    /// grouped), then spring-fly outward to a fan formation with a
    /// staggered cascade. The deck "explodes" outward last-in-first-out.
    /// One undo entry covers the full sequence.
    func ungroupSelection() {
        // Collect every distinct group implicated by the current selection.
        var groups = Set<UUID>()
        for id in selectedNodeIDs {
            if let g = nodeByID[id]?.groupID { groups.insert(g) }
        }
        guard !groups.isEmpty else { return }
        showToast(
            groups.count == 1 ? "Ungrouped stack" : "Ungrouped \(groups.count) stacks",
            systemImage: "square.stack.3d.down.right"
        )

        let before = snapshotForUndo()
        var released = Set<UUID>()
        // Stage 0 — collect per-group member lists + fan targets *before*
        // mutating anything, so the per-card stagger uses the correct
        // pre-mutation member ordering.
        struct FanPlan {
            let id: UUID
            let target: CGPoint
        }
        var plans: [FanPlan] = []
        let step: CGFloat = 32   // a bit wider than the old 24pt for a snappier fan
        for group in groups {
            let members = nodes
                .filter { $0.groupID == group }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            guard let head = members.first else { continue }
            let anchor = head.position
            for (i, m) in members.enumerated() {
                if m.id == head.id {
                    plans.append(FanPlan(id: m.id, target: anchor))
                } else {
                    plans.append(FanPlan(
                        id: m.id,
                        target: CGPoint(
                            x: anchor.x + CGFloat(i) * step,
                            y: anchor.y + CGFloat(i) * step
                        )
                    ))
                }
                released.insert(m.id)
            }
        }

        // Stage 1 — clear every `groupID` synchronously. Hidden members
        // become visible again at the head's stacked-up position. This
        // is the "explosion start" frame; from here the spring carries
        // each card outward.
        for plan in plans {
            mutateNode(plan.id) { node in
                node.groupID = nil
            }
        }

        // Stage 2 — staggered spring outward. Closer-to-head cards (low
        // index) fire first; outer cards trail. Feels like the deck
        // erupts last-in-first-out. `updatePosition` commits the model
        // value synchronously; the springs are decoration.
        let stagger: Double = 0.03
        for (i, plan) in plans.enumerated() {
            withAnimation(Motion.structure.delay(Double(i) * stagger)) {
                self.updatePosition(of: plan.id, to: plan.target)
            }
        }

        // Stage 3 — commit immediately: ⌘Z during the cascade must undo
        // THIS ungroup, not the action before it.
        Haptics.threshold()
        commitUndoable(from: before)

        // Selection updates immediately so the chrome reflects the new
        // member set (the loose cards) without waiting for stage 3.
        selectNodes(released)
    }

    /// Is this node the head of its stack (smallest UUID in the group)?
    /// Non-grouped nodes return false.
    func isStackHead(_ id: UUID) -> Bool {
        guard let node = nodeByID[id], node.groupID != nil else { return false }
        return stackMembers(of: id).first == id
    }

    /// Is this node hidden from rendering because it's a non-head
    /// member of a stack? Non-grouped nodes return false.
    /// **Focus-mode exception**: while the user is browsing a stack
    /// in focus mode, every member of THAT stack is rendered (at
    /// their `focusPositions` grid slots), so non-head members of
    /// the focused stack are un-hidden.
    func isHiddenByStack(_ id: UUID) -> Bool {
        guard let node = nodeByID[id], let group = node.groupID else { return false }
        if focusedStackID != nil, focusedStackID == group {
            return false
        }
        // Mid-converge: the group is committed but the card is still
        // visibly gliding into the deck.
        if groupFormationInFlight.contains(id) { return false }
        return !isStackHead(id)
    }

    /// Number of nodes in the current selection that are eligible for
    /// `groupSelection()` (i.e. non-section, not already grouped).
    /// `Edit ▸ Group (⌘G)` is enabled when this is ≥ 2.
    var groupableSelectionCount: Int {
        selectedNodeIDs.reduce(0) { acc, id in
            guard let n = nodeByID[id], !n.isSection, n.groupID == nil else { return acc }
            return acc + 1
        }
    }

    /// True if any node in the current selection belongs to a card-stack.
    /// `Edit ▸ Ungroup (⌘⇧G)` is enabled when this is true.
    var selectionHasGroupedNode: Bool {
        selectedNodeIDs.contains { nodeByID[$0]?.groupID != nil }
    }

    /// Apple-style auto-derived group name for the stack whose head
    /// is `headID`. Mirrors how Photos / Files surface collections —
    /// "N photos" when all members share a kind, "N items" for mixed
    /// stacks. Returns `nil` for non-stack nodes so callers can gate
    /// their label rendering with one optional check.
    func groupName(forHead headID: UUID) -> String? {
        guard isStackHead(headID) else { return nil }
        let memberIDs = stackMembers(of: headID)
        guard !memberIDs.isEmpty else { return nil }
        let members = memberIDs.compactMap { nodeByID[$0] }
        let count = members.count
        // Single-kind detection — if every member matches one of the
        // major content categories, we use a content-specific noun.
        let allVideos    = members.allSatisfy { if case .video    = $0.kind { return true }; return false }
        let allImages    = members.allSatisfy { if case .image    = $0.kind { return true }; return false }
        let allTweets    = members.allSatisfy { if case .tweet    = $0.kind { return true }; return false }
        let allInsta     = members.allSatisfy { if case .instagram = $0.kind { return true }; return false }
        let allText      = members.allSatisfy { if case .text     = $0.kind { return true }; return false }
        let allStickies  = members.allSatisfy { if case .stickyNote = $0.kind { return true }; return false }
        let allDrawings  = members.allSatisfy { if case .drawing  = $0.kind { return true }; return false }
        let label: String
        switch true {
        case allVideos:   label = count == 1 ? "Video"   : "\(count) Videos"
        case allImages:   label = count == 1 ? "Photo"   : "\(count) Photos"
        case allTweets:   label = count == 1 ? "Tweet"   : "\(count) Tweets"
        case allInsta:    label = count == 1 ? "Post"    : "\(count) Posts"
        case allText:     label = count == 1 ? "Note"    : "\(count) Notes"
        case allStickies: label = count == 1 ? "Sticky"  : "\(count) Stickies"
        case allDrawings: label = count == 1 ? "Sketch"  : "\(count) Sketches"
        default:          label = count == 1 ? "Item"    : "\(count) Items"
        }
        return label
    }

    /// Every member of the stack the given node belongs to, in head-first
    /// (uuid-ascending) order. Returns `[]` for non-grouped nodes.
    func stackMembers(of id: UUID) -> [UUID] {
        guard let node = nodeByID[id], let group = node.groupID else { return [] }
        return nodes
            .filter { $0.groupID == group }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// Expand a selection set to include every member of any card-stack
    /// referenced (by the head OR a hidden member) in the input. Used by:
    ///   • `DraggableNode.applyTranslation` — so the whole stack drags
    ///     together when the head moves.
    ///   • `removeNodesAndCascade` — so deleting a stack takes its hidden
    ///     members with it, not orphaning them with a dangling `groupID`.
    ///   • `duplicateNodes` — so duplicating a stack clones every member.
    /// The expansion is one-shot: once a group is included, the resulting
    /// set is closed under "share groupID."
    func expandedDragSet(from selection: Set<UUID>) -> Set<UUID> {
        var out = selection
        var seenGroups = Set<UUID>()
        for id in selection {
            guard let groupID = nodeByID[id]?.groupID,
                  !seenGroups.contains(groupID) else { continue }
            seenGroups.insert(groupID)
            for member in nodes where member.groupID == groupID {
                out.insert(member.id)
            }
        }
        return out
    }

    // MARK: - Stack focus mode (double-click on a stack)

    /// Enter focus mode for the stack that `headID` belongs to.
    /// Computes a Photos-style grid layout (via `StackFocusEngine`),
    /// snapshots the camera so exit can restore it, and animates
    /// every member from the stack's anchor position out to its
    /// computed grid slot. No-op if the node isn't a stack head.
    func enterStackFocus(headID: UUID) {
        guard let head = nodeByID[headID],
              let groupID = head.groupID,
              isStackHead(headID) else { return }
        let members = stackMembers(of: headID)
        guard members.count >= 2 else { return }

        // Focus choreographs the camera — stop any coast/glide first,
        // and snapshot the *resting* camera for the exit restore.
        cancelPanInertia()
        focusOriginCamera = cameraStore.camera

        // Compute the grid layout in viewport coords. The viewport's
        // natural canvas-space size is the world-space rectangle the
        // user sees at zoom 1.0 — we'll animate the camera to that
        // zoom so the grid uses real world coords directly.
        let layout = StackFocusEngine.layout(
            memberIDs: members,
            state: self,
            viewportSize: viewportSize
        )

        // Wrap the geometry mutations + camera reset in one spring so
        // every member visibly springs from its stack-anchor position
        // out to its grid slot in a single coordinated animation.
        withAnimation(Motion.structure) {
            self.focusedStackID = groupID
            self.focusPositions = layout.positions
            self.focusSizes     = layout.sizes
            // Camera to neutral so the focus chrome can position
            // itself in raw viewport coords without zoom skew.
            self.cameraStore.camera = Camera(x: 0, y: 0, zoom: 1.0)
        }
        // Tap haptic — focus engaged.
        Haptics.tap()
    }

    /// Exit focus mode. Cards spring back toward the stack head's
    /// anchor position (so they re-pile into the deck), the camera
    /// restores its pre-focus state, and the overlay chrome dismisses.
    func exitStackFocus() {
        guard focusedStackID != nil else { return }
        cancelPanInertia()   // the restore owns the camera from here
        let restoreCamera = focusOriginCamera ?? cameraStore.camera
        // Animate the dismissal — same spring as entry for symmetry.
        withAnimation(Motion.structure) {
            self.focusedStackID = nil
            self.focusPositions = [:]
            self.focusSizes = [:]
            self.cameraStore.camera = restoreCamera
        }
        focusOriginCamera = nil
        Haptics.tap()
    }

    /// Wrap the current selection in a new section that geographically
    /// contains every selected node. The section "owns" them via the
    /// existing spatial-containment model: dragging the header moves
    /// them as a unit, deleting it cascade-deletes them. One undo entry.
    @discardableResult
    func wrapSelectionInSection(color: SectionColor = .slate) -> UUID? {
        guard !selectedNodeIDs.isEmpty,
              let bounds = boundingRect(of: selectedNodeIDs) else { return nil }
        // Side padding gives the section a visible margin around the
        // contents; header overhead reserves room above for the 28pt
        // title bar so it doesn't crowd the topmost cards.
        let sidePadding: CGFloat = 32
        let headerOverhead: CGFloat = 48
        let rect = CGRect(
            x: bounds.minX - sidePadding,
            y: bounds.minY - headerOverhead,
            width:  bounds.width  + sidePadding * 2,
            height: bounds.height + headerOverhead + sidePadding
        )
        return addSection(rect: rect, color: color)
    }

    func setSectionTitle(id: UUID, to title: String) {
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
            if case .section(_, let color) = nodes[idx].kind {
                nodes[idx].kind = .section(title: title, color: color)
            }
        }
    }

    func setSectionColor(id: UUID, to color: SectionColor) {
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
            if case .section(let title, _) = nodes[idx].kind {
                nodes[idx].kind = .section(title: title, color: color)
            }
        }
    }

    /// Tint a folder from the flower color picker (`#RRGGBB` hex). Mutating
    /// `folderColor` changes the node's `nativeContentKey`, so the card re-renders.
    func setFolderColor(id: UUID, hex: String) {
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == id }),
                  nodes[idx].isFolder || nodes[idx].isStickyNote else { return }
            nodes[idx].folderColor = hex
        }
    }

    /// Live, NON-undoable folder tint used while hovering the flower picker, so a
    /// sweep across petals previews each colour on the folder without spamming the
    /// undo stack. `nil` restores the folder's previous (or default) tint. The
    /// commit on pick goes through `setFolderColor` (undoable).
    func previewFolderColor(id: UUID, hex: String?) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }),
              nodes[idx].isFolder || nodes[idx].isStickyNote else { return }
        guard nodes[idx].folderColor != hex else { return }
        nodes[idx].folderColor = hex
    }

    /// World rect of a section node by id, or nil if not a section.
    func sectionRect(of id: UUID) -> CGRect? {
        guard let n = nodeByID[id], n.isSection else { return nil }
        return CGRect(x: n.position.x, y: n.position.y,
                      width: n.width,
                      height: n.height ?? renderedHeight(of: n))
    }

    /// IDs of non-section nodes whose centre lies within the given world
    /// rect. Used so dragging or deleting a section also moves/deletes
    /// its contents as a unit.
    func nodeIDs(insideWorldRect rect: CGRect) -> Set<UUID> {
        var hits: Set<UUID> = []
        for n in nodes where !n.isSection {
            let h = renderedHeight(of: n)
            let cx = n.position.x + n.width / 2
            let cy = n.position.y + h / 2
            if rect.contains(CGPoint(x: cx, y: cy)) {
                hits.insert(n.id)
            }
        }
        return hits
    }
}
