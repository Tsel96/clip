import SwiftUI

/// Canvas text restyled as a white **pill** (Figma 96-720): IBM Plex Sans
/// SemiBold green text on a fully-rounded white card. The node is sized to the
/// glyphs + pill padding (`CanvasState.textPillSize`), so this view just fills
/// the item and centres the text; selection ring + float shadow are owned by the
/// native chrome (pill-shaped to match).
///
/// NOTE: editing uses a SwiftUI `TextField` — NOT the embedded `StickyRichTextEditor`
/// (NSTextView). An embedded NSTextView composites as a transparent window-hole while
/// it's first responder, revealing the grey canvas instead of the white pill (the
/// "text greys while editing" regression). A pure-SwiftUI field has no such hole.
struct TextNodeView: View {
    @EnvironmentObject var state: CanvasState
    let nodeID: UUID
    let content: String
    let fontSize: CGFloat
    let isSelected: Bool

    @State private var isEditing: Bool = false
    @State private var editingText: String = ""
    @FocusState private var focused: Bool

    private var textFont: Font { .custom("IBMPlexSans-SemiBold", size: fontSize) }
    /// #3DA726
    private let green  = Color(.sRGB, red: 0.239, green: 0.655, blue: 0.149, opacity: 1)
    /// #F0EC00
    private let yellow = Color(.sRGB, red: 0.943, green: 0.926, blue: 0.0,   opacity: 1)

    var body: some View {
        // The green band + yellow border are the node's permanent border (all
        // states, Figma 96-720). The white pill is inset inside them; the node is
        // sized to glyphs + white padding + this border, so content stays centred.
        let bd = CanvasState.textPillBorder(fontSize)
        let inset = bd.band + bd.yellow
        ZStack {
            Capsule(style: .continuous).fill(green)                          // green pill (shows as a band)
            Capsule(style: .continuous).fill(Color.white).padding(inset)     // white pill, inset by band+yellow
            (isEditing ? AnyView(editor) : AnyView(display))                 // text, centred in the white pill
            Capsule(style: .continuous).strokeBorder(yellow, lineWidth: bd.yellow)  // yellow border at the edge
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                editingText = content
                if state.pendingFocusNodeID == nodeID {
                    DispatchQueue.main.async { startEditing() }
                }
            }
            .onChange(of: state.pendingFocusNodeID) { newID in
                if newID == nodeID && !isEditing {
                    startEditing()
                    DispatchQueue.main.async { state.pendingFocusNodeID = nil }
                }
            }
            .onChange(of: state.selectedNodeIDs) { selected in
                if isEditing && !selected.contains(nodeID) { commit() }
            }
    }

    // MARK: - Display / Editor

    private var display: some View {
        Text(content.isEmpty ? "Text" : content)
            .font(textFont)
            .foregroundStyle(content.isEmpty ? green.opacity(0.4) : green)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var editor: some View {
        TextField("", text: $editingText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(textFont)
            .foregroundStyle(green)
            .tint(green)
            .multilineTextAlignment(.center)
            .focused($focused)
            .frame(width: editorTextWidth)                  // synchronous → never wraps the last glyph
            .onAppear { focused = true }
            .onExitCommand { commit() }                     // Esc
            .onChange(of: focused) { if !$0 { commit() } }  // click-away
            .onChange(of: editingText) { newValue in
                state.liveResizeText(id: nodeID, content: newValue)  // grow the pill live
            }
    }

    /// Glyph width measured synchronously from the content (same font as the pill
    /// sizing) — no PreferenceKey lag, so the field never wraps the last typed
    /// character. The roomy pill padding absorbs any item-resize lag.
    private var editorTextWidth: CGFloat {
        max(fontSize * 0.5,
            CanvasState.textGlyphSize(content: editingText, fontSize: fontSize).width + 12)
    }

    // MARK: - Helpers

    private func startEditing() {
        editingText = content
        isEditing = true
        focused = true
        state.editingTextNodeID = nodeID
    }

    private func commit() {
        guard isEditing else { return }
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            state.delete(id: nodeID)
        } else if trimmed != content {
            state.updateText(id: nodeID, content: trimmed)
        }
        if state.pendingFocusNodeID == nodeID { state.pendingFocusNodeID = nil }
        if state.editingTextNodeID == nodeID { state.editingTextNodeID = nil }
        isEditing = false
        state.selectedNodeIDs.remove(nodeID)
    }
}
