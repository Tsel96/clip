import SwiftUI
import AppKit
import AVFoundation
import Combine

// Split out of CanvasState.swift (god-object refactor): text / sticky-note / folder creation.
extension CanvasState {


    // MARK: - Text creation / editing

    /// Create a text node at the given world position and put it straight into
    /// edit mode. If `worldPoint` is nil, place at viewport centre.
    @discardableResult
    func addText(at worldPoint: CGPoint? = nil) -> UUID {
        let position = worldPoint ?? {
            let c = screenToWorld(point: viewportCentre)
            return CGPoint(x: c.x - 120, y: c.y - 14)
        }()
        let node = CanvasNode.text(content: "", position: position)
        withUndoable { nodes.append(node) }
        // Native text: editingTextNodeID makes the new item mount the SwiftUI
        // inline editor immediately (pendingFocus then focuses it on appear).
        editingTextNodeID = node.id
        pendingFocusNodeID = node.id
        select(node.id)
        toolMode = .select
        return node.id
    }

    func updateText(id: UUID, content: String) {
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
            if case .text(_, let fontSize) = nodes[idx].kind {
                nodes[idx].kind = .text(content: content, fontSize: fontSize)
            }
        }
        if pendingFocusNodeID == id { pendingFocusNodeID = nil }
    }

    // MARK: - Sticky notes

    /// Create a sticky (Figma 88-415, 382×408) at the given world point (or
    /// viewport centre when `nil`) and immediately auto-focus its editor — same
    /// pattern as `addText`.
    @discardableResult
    func addStickyNote(at worldPoint: CGPoint? = nil) -> UUID {
        let size = CGSize(width: 382, height: 408)   // Figma 88-415
        let position: CGPoint = {
            if let p = worldPoint {
                return CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2)
            }
            let c = screenToWorld(point: viewportCentre)
            return CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2)
        }()
        let node = CanvasNode.stickyNote(position: position, size: size)
        withUndoable { nodes.append(node) }
        // Drive the SwiftUI StickyNodeView into edit mode (focused caret), same
        // as `addText`; `editingTextNodeID` also makes CanvasInputView pass clicks
        // through to the editor.
        editingTextNodeID = node.id
        pendingFocusNodeID = node.id
        select(node.id)
        toolMode = .select
        return node.id
    }

    func setStickyContent(id: UUID, to content: String) {
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
            if case .stickyNote(_, let color) = nodes[idx].kind {
                nodes[idx].kind = .stickyNote(content: content, color: color)
            }
        }
    }

    func setStickyColor(id: UUID, to color: StickyColor) {
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
            if case .stickyNote(let content, _) = nodes[idx].kind {
                nodes[idx].kind = .stickyNote(content: content, color: color)
            }
        }
    }

    // MARK: - Folders

    /// Create an empty "Untitled" folder at the given world point (or viewport
    /// centre when `nil`), selected and ready. Sized to the Figma folder aspect.
    @discardableResult
    func addFolder(at worldPoint: CGPoint? = nil) -> UUID {
        let width: CGFloat = 260
        let height = (width / 1.165).rounded()
        let position: CGPoint = {
            if let p = worldPoint {
                return CGPoint(x: p.x - width / 2, y: p.y - height / 2)
            }
            let c = screenToWorld(point: viewportCentre)
            return CGPoint(x: c.x - width / 2, y: c.y - height / 2)
        }()
        let node = CanvasNode.folder(position: position, width: width)
        withUndoable { nodes.append(node) }
        select(node.id)
        toolMode = .select
        return node.id
    }

    /// Rename a folder (inline edit / Edit Folder).
    func setFolderTitle(id: UUID, to title: String) {
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == id }),
                  case .folder(_, let icon, let childIDs) = nodes[idx].kind else { return }
            nodes[idx].kind = .folder(title: title, icon: icon, childIDs: childIDs)
        }
    }

    /// Set a folder's identity icon (SF Symbol name, "" for none).
    func setFolderIcon(id: UUID, to icon: String) {
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == id }),
                  case .folder(let title, _, let childIDs) = nodes[idx].kind else { return }
            nodes[idx].kind = .folder(title: title, icon: icon, childIDs: childIDs)
        }
    }
}
