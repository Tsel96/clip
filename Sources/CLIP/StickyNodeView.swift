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

    /// Local edit buffer; authoritative only while focused.
    @State private var editingText: String = ""
    @FocusState private var focused: Bool

    static let cornerRadius: CGFloat = 37

    /// Default light card (#F3F4F5), overridden by the recolour tint. Reads the
    /// LIVE node from `state` so the flower picker's preview/commit re-renders
    /// (the captured `node` value wouldn't reflect a `folderColor` change).
    private var fill: Color {
        let hex = state.nodes.first(where: { $0.id == node.id })?.folderColor
        if let hex, let c = Color(hexString: hex) { return c }
        return Color(hexString: "#F3F4F5") ?? Color(white: 0.957)
    }
    private var textColor: Color { Color(hexString: "#16181A") ?? .black }

    var body: some View {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(fill)
            .overlay(alignment: .topLeading) {
                TextEditor(text: $editingText)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .font(.system(size: 17, weight: .medium, design: .monospaced))  // SF Mono Medium (88-415)
                    .kerning(-0.17)
                    .lineSpacing(2)                                                  // ≈ 22pt line height
                    .foregroundStyle(textColor)
                    .tint(textColor)
                    .focused($focused)
                    .padding(.horizontal, 30)
                    .padding(.vertical, 28)
                    // Only the editing sticky captures clicks; at rest the canvas
                    // owns them (drag / select) via CanvasInputView.
                    .allowsHitTesting(isEditing)
            }
            .onAppear {
                editingText = content
                if isEditing { DispatchQueue.main.async { focused = true } }
            }
            .onChange(of: content) { newContent in
                // External mutation (undo / paste) — sync the buffer only when
                // we're not the one driving the change.
                if !focused { editingText = newContent }
            }
            .onChange(of: isEditing) { editing in
                // Created / double-clicked → focus; cleared → blur (commits).
                if editing { DispatchQueue.main.async { focused = true } }
                else if focused { focused = false }
            }
            .onChange(of: focused) { isFocused in
                if !isFocused { commit() }
            }
            .onExitCommand { focused = false }       // Esc commits + blurs
    }

    /// This sticky is the one being edited (drives focus + click capture).
    private var isEditing: Bool { state.editingTextNodeID == node.id }

    // MARK: - Commit

    private func commit() {
        if editingText != content {
            state.setStickyContent(id: node.id, to: editingText)
        }
        if state.editingTextNodeID == node.id { state.editingTextNodeID = nil }
        if state.pendingFocusNodeID == node.id { state.pendingFocusNodeID = nil }
    }
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
