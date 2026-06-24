import SwiftUI

/// Spatial-style sticky note (Figma 88-415): a light `#F3F4F5` rounded card with
/// a soft drop shadow and editable dark `#16181A` text. Recolour is driven by the
/// toolbar action bar (the same flower picker as folders) and stored in
/// `node.folderColor`; `nil` = the default light card.
///
/// **Editing model.** `editingText` is the live edit buffer; the model is only
/// mutated once on commit (focus-lost / Esc). This collapses a typing session
/// into one undo entry — matching `TextNodeView`. While not editing, `content`
/// from the model wins, so undo / paste / programmatic edits reflect immediately.
///
/// Selection chrome (accent ring + resize handles) is owned by `DraggableNode`,
/// which reads `StickyNodeView.cornerRadius` so the clip matches this shape.
struct StickyNodeView: View {
    @EnvironmentObject var state: CanvasState
    let node: CanvasNode
    let content: String
    let color: StickyColor          // legacy (archive / lightbox); canvas tint = folderColor

    static let cornerRadius: CGFloat = 37

    /// Default light card (#F3F4F5), overridden by the recolour tint. Reads the
    /// LIVE node from `state` so the flower picker's preview/commit re-renders
    /// (the captured `node` value wouldn't reflect a `folderColor` change).
    private var liveNode: CanvasNode { state.nodes.first(where: { $0.id == node.id }) ?? node }
    private var fill: Color {
        if let hex = liveNode.folderColor, let c = Color(hexString: hex) { return c }
        return Color(hexString: "#F3F4F5") ?? Color(white: 0.957)
    }
    private static let textNSColor = NSColor(srgbRed: 0x16/255, green: 0x18/255, blue: 0x1A/255, alpha: 1)

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(fill)
            .overlay(alignment: .topLeading) {
                // Native rich-text editor (NSTextView): real caret/selection +
                // bold/italic/underline/strike that persist. Only the editing
                // sticky captures clicks; at rest the canvas owns them (drag /
                // select) via CanvasInputView.
                StickyRichTextEditor(
                    node: liveNode,
                    isEditing: isEditing,
                    textColor: Self.textNSColor,
                    onCommit: { attr in state.setStickyAttributed(id: node.id, attr) },
                    onEndEditing: {
                        if state.editingTextNodeID == node.id { state.editingTextNodeID = nil }
                        if state.pendingFocusNodeID == node.id { state.pendingFocusNodeID = nil }
                    })
                .allowsHitTesting(isEditing)
            }
    }

    /// This sticky is the one being edited (drives focus + click capture).
    private var isEditing: Bool { state.editingTextNodeID == node.id }
}

private extension Color {
    /// `#RRGGBB` (sRGB) → Color; `nil` on malformed input.
    init?(hexString: String) {
        var s = hexString
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red:   Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >>  8) & 0xFF) / 255,
                  blue:  Double( v        & 0xFF) / 255)
    }
}
