import SwiftUI
import AppKit

// MARK: - SwiftUI bridge: presents the native detail view, driven by state

/// The ONLY SwiftUI in the detail-view stack: a thin `NSViewRepresentable` that
/// mounts the fully-native `CardDetailView` into the app's SwiftUI shell and
/// drives present/dismiss/navigation from `CanvasState`. The detail UI itself
/// (`CardDetailView`) is 100% AppKit — no SwiftUI views, no `Color`.
struct NativeDetailHost: NSViewRepresentable {
    @EnvironmentObject var state: CanvasState

    func makeNSView(context: Context) -> CardDetailView { CardDetailView() }

    func updateNSView(_ v: CardDetailView, context: Context) {
        v.onClose = { state.closeLightbox() }
        v.onStep = { state.lightboxStep($0) }
        v.onOpenLink = { urlString in
            if let u = URL(string: urlString) { NSWorkspace.shared.open(u) }
        }

        // Begin close: shrink, then unmount the model once the animation lands.
        if state.lightboxClosing, v.presentedID != nil {
            v.dismiss { state.finalizeLightboxClose() }
            return
        }
        guard let id = state.lightboxCardID, let node = state.nodeByID[id] else {
            if v.presentedID != nil { v.dismiss() }
            return
        }
        v.onDelete = { state.delete(id: id); state.closeLightbox() }
        v.onDuplicate = { _ = state.duplicateNode(id); state.closeLightbox() }
        v.onSaveNote = { state.setNodeNote(id, $0) }
        v.onDownload = Self.downloadAction(node)

        if v.presentedID != id {
            v.present(node: node, sourceRect: state.lightboxSourceRect)
            DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        }
    }

    /// Native download: image → save panel; video → reveal in Finder.
    private static func downloadAction(_ node: CanvasNode) -> (() -> Void)? {
        switch node.kind {
        case .image(let data, let filename):
            return {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = filename.isEmpty ? "image" : filename
                if panel.runModal() == .OK, let url = panel.url { try? data.write(to: url) }
            }
        case .video(let fileURL, _):
            return { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
        default:
            return nil
        }
    }
}
