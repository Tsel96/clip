import SwiftUI
import AppKit
import AVFoundation
import Combine

// Split out of CanvasState.swift (god-object refactor): mode dispatch + mode-aware rendering.
extension CanvasState {


    // MARK: - Mode dispatch

    /// Unified entry point for changing modes. Handles exiting the
    /// current mode and entering the new one with the correct ordering
    /// + async dispatch for modes that need it.
    func setMode(_ mode: CanvasMode) {
        guard mode != canvasMode else { return }
        // Mode transitions choreograph the camera themselves — coasting
        // or gliding must hand it over first.
        cancelPanInertia()
        // Exit whatever's active first so its transient state clears
        // before the next entry routine begins publishing.
        switch canvasMode {
        case .canvas:     break
        case .colorform:  exitColorform()
        case .archive:    exitArchive()
        }
        switch mode {
        case .canvas:     break    // already restored by exit above
        case .colorform:  Task { await enterColorform() }
        case .archive:    enterArchive()
        }
        // Remember the last *view* mode so a relaunch can restore it.
        // Colorform is intentionally excluded — it's too expensive to
        // recompute on cold start.
        if mode.isViewMode, mode != .colorform {
            lastViewMode = mode
        }
    }

    // MARK: - Mode-aware rendering

    /// Position used for rendering this node — accounts for any active
    /// mode's transient re-layout overlay. Falls through to
    /// `node.position` when no override applies.
    func effectivePosition(of node: CanvasNode) -> CGPoint {
        // Stack focus mode lives *inside* canvas mode (it's a transient
        // sub-state, not a top-level CanvasMode). Its override wins when
        // the node belongs to the currently-focused stack — the head
        // and every member fly into the focus grid.
        if focusedStackID != nil, let p = focusPositions[node.id] {
            return p
        }
        switch canvasMode {
        case .colorform:
            if let p = colorformPositions[node.id] { return p }
        case .archive:
            if let p = archivePositions[node.id] { return p }
        case .canvas:
            break
        }
        return node.position
    }

    /// Switch into Colorform mode: extract dominant colors for every node,
    /// cluster them, and compute new spatial positions. Non-destructive —
    /// underlying node positions are unchanged. The synchronous mode flip
    /// (so the switcher's pill animates immediately) and the eventual
    /// position publication are both wrapped in `withAnimation`, so the
    /// switcher's tab slide and the card re-flow each get spring physics.
    func enterColorform() async {
        guard canvasMode != .colorform else { return }
        let pageAtStart = activePageID
        // Snapshot the camera *before* mode flip so we can restore it
        // verbatim on exit.
        preColorformCamera = camera
        // Snap the mode + spinner immediately so the UI feels responsive
        // while we go off to extract colors.
        withAnimation(.smooth(duration: 0.35)) {
            canvasMode = .colorform
            isComputingColorform = true
        }
        await refreshDominantColors()
        guard activePageID == pageAtStart, canvasMode == .colorform else {
            isComputingColorform = false
            return
        }
        let clusters = ColorformEngine.cluster(dominantColors)
        let sizes = Dictionary(uniqueKeysWithValues: nodes.map {
            ($0.id, CGSize(width: $0.width, height: renderedHeight(of: $0)))
        })
        let result = ColorformEngine.layout(clusters: clusters, nodeSizes: sizes)
        let framedCamera = cameraFraming(bulbs: result.bulbs)
        withAnimation(Motion.structure) {
            colorformPositions = result.positions
            colorBulbs = result.bulbs
            if let cam = framedCamera { camera = cam }
        }
        isComputingColorform = false
    }

    /// Drop the Colorform overlay and return to normal canvas rendering.
    /// Underlying node positions and the user's prior camera are both
    /// restored, so leaving Colorform feels truly non-destructive.
    func exitColorform() {
        guard canvasMode == .colorform else { return }
        let restored = preColorformCamera
        withAnimation(Motion.structure) {
            canvasMode = .canvas
            colorformPositions = [:]
            colorBulbs = []
            if let cam = restored { camera = cam }
        }
        dominantColors = [:]
        isComputingColorform = false
        preColorformCamera = nil
    }

    /// Effective display size of a node when in a mode that re-flows
    /// or re-sizes cards. Archive's Bento level lays them out
    /// per-cardinality with explicit sizes. Falls through to natural
    /// size when no override applies.
    func effectiveSize(of node: CanvasNode) -> CGSize {
        // Stack focus mode wins over every other override — its bento
        // grid sets per-member explicit sizes that text caps + aspect-
        // preserves images/videos.
        if focusedStackID != nil, let s = focusSizes[node.id] {
            return s
        }
        // Bento layout: explicit per-card size.
        if canvasMode == .archive, let s = archiveSizes[node.id] {
            return s
        }
        return CGSize(width: node.width, height: renderedHeight(of: node))
    }
}
