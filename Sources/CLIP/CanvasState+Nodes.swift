import SwiftUI
import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

// Split out of CanvasState.swift (god-object refactor): text / sticky-note / folder creation.
extension CanvasState {


    // MARK: - Text creation / editing

    /// Create a text node at the given world position and put it straight into
    /// edit mode. If `worldPoint` is nil, place at viewport centre.
    /// White-pill internal padding (text → white edge), Figma 96-720 proportions.
    static func textPillPadding(_ fontSize: CGFloat) -> (h: CGFloat, v: CGFloat) {
        (h: fontSize * 0.62, v: fontSize * 0.36)   // roomier breathing space (user)
    }

    /// The green band + yellow border around the white pill (Figma 96-720) — the
    /// text node's permanent border (all states).
    static func textPillBorder(_ fontSize: CGFloat) -> (band: CGFloat, yellow: CGFloat) {
        (band: fontSize * 0.18, yellow: fontSize * 0.05)
    }

    /// Glyph box for `content` (IBM Plex Sans SemiBold); placeholder if empty.
    static func textGlyphSize(content: String, fontSize: CGFloat) -> CGSize {
        let text = content.isEmpty ? "Text" : content
        let font = NSFont(name: "IBMPlexSans-SemiBold", size: fontSize)
            ?? .systemFont(ofSize: fontSize, weight: .semibold)
        let b = (text as NSString).boundingRect(
            with: CGSize(width: 100_000, height: 100_000),
            options: [.usesLineFragmentOrigin], attributes: [.font: font])
        return CGSize(width: ceil(b.width), height: ceil(b.height))
    }

    /// Full node frame = glyphs + white-pill padding + green/yellow border.
    static func textPillSize(content: String, fontSize: CGFloat) -> CGSize {
        let g = textGlyphSize(content: content, fontSize: fontSize)
        let pad = textPillPadding(fontSize)
        let bd = textPillBorder(fontSize)
        let e = bd.band + bd.yellow
        return CGSize(width: g.width + pad.h * 2 + e * 2,
                      height: g.height + pad.v * 2 + e * 2)
    }

    @discardableResult
    func addText(at worldPoint: CGPoint? = nil) -> UUID {
        let fontSize: CGFloat = 64   // 4× the old default (Figma 96-720 reads large)
        let size = Self.textPillSize(content: "", fontSize: fontSize)
        let centre = worldPoint ?? screenToWorld(point: viewportCentre)
        let position = CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2)
        var node = CanvasNode.text(content: "", position: position, fontSize: fontSize)
        node.width = size.width
        node.height = size.height
        withUndoable { nodes.append(node) }
        // editingTextNodeID mounts the SwiftUI inline editor immediately
        // (pendingFocus then focuses it on appear).
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
                let s = Self.textPillSize(content: content, fontSize: fontSize)
                nodes[idx].width = s.width
                nodes[idx].height = s.height
            }
        }
        if pendingFocusNodeID == id { pendingFocusNodeID = nil }
    }

    /// Live (non-undoable) resize of a text node's pill while typing, so the
    /// pill + selection grow with the glyphs before the commit lands.
    func liveResizeText(id: UUID, content: String) {
        guard let idx = nodes.firstIndex(where: { $0.id == id }),
              case .text(_, let fontSize) = nodes[idx].kind else { return }
        let s = Self.textPillSize(content: content, fontSize: fontSize)
        guard abs(nodes[idx].width - s.width) > 0.5
           || abs((nodes[idx].height ?? 0) - s.height) > 0.5 else { return }
        // Hot path (every keystroke): patch the one node in place via
        // `mutateNode` instead of `nodes[idx].width/height =`, which would route
        // through the `nodes` computed setter TWICE — each rebuilding the whole
        // `nodeByID` index O(n) and firing `@Published pages`.
        mutateNode(id) {
            $0.width = s.width
            $0.height = s.height
        }
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

    /// Commit a sticky / text node's RICH text: archive the attributed string to
    /// RTF in `attributedContent` AND keep the plain `content` in `Kind` in sync
    /// (search / archive / lightbox read the plain string). One undo entry per
    /// edit session — called on commit, like `setStickyContent`.
    func setStickyAttributed(id: UUID, _ attributed: NSAttributedString) {
        let range = NSRange(location: 0, length: attributed.length)
        let rtf = try? attributed.data(from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let plain = attributed.string
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == id }) else { return }
            // Drop the archive when the text carries no formatting differences
            // worth storing? Keep it simple: store whenever there's any text.
            nodes[idx].attributedContent = attributed.length > 0 ? rtf : nil
            switch nodes[idx].kind {
            case .stickyNote(_, let color):
                nodes[idx].kind = .stickyNote(content: plain, color: color)
            case .text(_, let fontSize):
                nodes[idx].kind = .text(content: plain, fontSize: fontSize)
                let s = Self.textPillSize(content: plain, fontSize: fontSize)   // keep the pill sized
                nodes[idx].width = s.width
                nodes[idx].height = s.height
            default: break
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

    // MARK: - Sticky action bar (Figma 104:651)

    /// Create a folder at the sticky's position and tuck the sticky into it.
    func addStickerToNewFolder(_ id: UUID) {
        guard let n = nodeByID[id], n.isStickyNote else { return }
        let centre = CGPoint(x: n.position.x + n.width / 2,
                             y: n.position.y + (n.height ?? n.width) / 2)
        let fid = addFolder(at: centre)
        addToFolder(fid, nodeIDs: [id])
    }

    /// Render the sticky to a PNG and save it (Download).
    @MainActor
    func exportSticker(_ id: UUID) {
        guard let n = nodeByID[id], case .stickyNote(let content, let color) = n.kind else { return }
        let size = CGSize(width: n.width, height: n.height ?? n.width)
        let renderer = ImageRenderer(content:
            StickyExportView(content: content, color: color)
                .frame(width: size.width, height: size.height))
        renderer.scale = max(2, NSScreen.main?.backingScaleFactor ?? 2)
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "sticker.png"
        panel.begin { resp in
            if resp == .OK, let url = panel.url { try? png.write(to: url) }
        }
    }

    // MARK: - Folders

    /// Create an empty "Untitled" folder at the given world point (or viewport
    /// centre when `nil`), selected and ready. Sized to the Figma folder aspect.
    @discardableResult
    func addFolder(at worldPoint: CGPoint? = nil) -> UUID {
        let width: CGFloat = 437               // 20% smaller than 546
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
