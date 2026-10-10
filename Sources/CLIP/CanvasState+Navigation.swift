import Foundation
import AppKit
import SwiftUI

// Keyboard card navigation (N / ⇧N) + open source — split out of CanvasState.swift (behaviour unchanged).
@MainActor
extension CanvasState {
    // MARK: - Keyboard card navigation (N / ⇧N) + open source

    /// Select and frame the next (or previous) card, Figma-style. Cards are
    /// visited in spatial reading order — top-to-bottom, then left-to-right
    /// — and the camera animates to frame each via `zoomToSelection`. Wraps
    /// around at the ends. Sections are skipped (they're containers, not
    /// cards). Canvas-mode only.
    func selectNextNode(reverse: Bool = false) {
        guard canvasMode == .canvas else { return }
        let ordered = activePage.nodes
            .filter { !$0.isSection }
            .sorted { a, b in
                if abs(a.position.y - b.position.y) > 1 { return a.position.y < b.position.y }
                return a.position.x < b.position.x
            }
        guard !ordered.isEmpty else { return }

        let currentID = selectedNodeIDs.count == 1 ? selectedNodeIDs.first : nil
        let currentIdx = currentID.flatMap { id in ordered.firstIndex(where: { $0.id == id }) }
        let nextIdx: Int
        if let i = currentIdx {
            nextIdx = reverse ? (i - 1 + ordered.count) % ordered.count
                              : (i + 1) % ordered.count
        } else {
            nextIdx = reverse ? ordered.count - 1 : 0
        }
        select(ordered[nextIdx].id)
        zoomToSelection()
    }

    /// Open the source URL(s) of the selected card(s) — tweet / Instagram /
    /// YouTube — in the default browser. Toasts if the selection has no link.
    func openSelectedSource() {
        let urls: [URL] = selectedNodeIDs.compactMap { id -> URL? in
            guard let node = nodeByID[id] else { return nil }
            let s: String?
            switch node.kind {
            case .tweet(let u), .instagram(let u), .youtube(let u): s = u
            default: s = nil
            }
            return s.flatMap { URL(string: $0) }
        }
        guard !urls.isEmpty else {
            showToast("No source link on the selected card", systemImage: "link.slash")
            return
        }
        for url in urls.prefix(12) { NSWorkspace.shared.open(url) }
    }
}
