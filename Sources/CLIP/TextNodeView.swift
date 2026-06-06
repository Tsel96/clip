import SwiftUI

/// Bare canvas text — no background / no border / no padding.
/// Display & edit both auto-size to the rendered glyphs so the surrounding
/// selection rectangle in `DraggableNode` hugs the text (Figma-style).
struct TextNodeView: View {
    @EnvironmentObject var state: CanvasState
    let nodeID: UUID
    let content: String
    let fontSize: CGFloat
    let isSelected: Bool

    @State private var isEditing: Bool = false
    @State private var editingText: String = ""
    @State private var editorSize: CGSize = .zero
    @FocusState private var focused: Bool

    /// Floor so the empty-state TextField is wide enough to comfortably
    /// receive the first few keystrokes.
    private let minWidth: CGFloat = 40
    /// Extra room for the caret beyond the rightmost glyph.
    private let trailingCaretPadding: CGFloat = 4

    var body: some View {
        Group {
            if isEditing {
                editor
            } else {
                display
            }
        }
        .font(.system(size: fontSize))
        .contentShape(Rectangle())
        .onAppear {
            editingText = content
            if state.pendingFocusNodeID == nodeID {
                DispatchQueue.main.async { startEditing() }
            }
        }
        .onChange(of: state.pendingFocusNodeID) { newID in
            if newID == nodeID && !isEditing { startEditing() }
        }
        // Click-out / Esc / clicking another node all deselect this node.
        // When we leave the selection while editing, commit & exit edit mode
        // so the TextField is removed and the caret stops blinking.
        .onChange(of: state.selectedNodeIDs) { selected in
            if isEditing && !selected.contains(nodeID) { commit() }
        }
    }

    // MARK: - Editor (auto-sizing TextField)

    private var editor: some View {
        // ZStack with a hidden `Text` that mirrors the editing content.
        // The Text drives sizing via a PreferenceKey, and we apply that size
        // to the TextField — which on its own has a fixed intrinsic width
        // and would otherwise clip everything except the last character.
        ZStack(alignment: .topLeading) {
            Text(editingText.isEmpty ? " " : editingText)
                .font(.system(size: fontSize))
                .fixedSize(horizontal: true, vertical: true)
                .opacity(0)
                .allowsHitTesting(false)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: TextSizePrefKey.self,
                                                value: geo.size)
                    }
                )

            TextField("", text: $editingText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize))
                .lineLimit(1...50)
                .focused($focused)
                .onAppear { focused = true }
                .onExitCommand { commit() }                // Esc
                .onChange(of: focused) { isFocused in
                    if !isFocused { commit() }             // click-away
                }
        }
        .frame(
            width:  max(minWidth, editorSize.width + trailingCaretPadding),
            height: max(fontSize * 1.4, editorSize.height),
            alignment: .topLeading
        )
        .onPreferenceChange(TextSizePrefKey.self) { editorSize = $0 }
    }

    // MARK: - Display

    @ViewBuilder
    private var display: some View {
        Group {
            if content.isEmpty {
                Text("Text").foregroundStyle(.tertiary)
            } else {
                Text(content).textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .onTapGesture(count: 2) { startEditing() }
    }

    // MARK: - Helpers

    private func startEditing() {
        editingText = content
        isEditing = true
        focused = true
    }

    private func commit() {
        // Idempotent: protects against the focused-onChange firing again
        // *after* we already exited edit mode (because the TextField was
        // removed from the view tree).
        guard isEditing else { return }

        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            state.delete(id: nodeID)
        } else if trimmed != content {
            state.updateText(id: nodeID, content: trimmed)
        }
        if state.pendingFocusNodeID == nodeID { state.pendingFocusNodeID = nil }
        isEditing = false
        // Drop just this node from the selection; multi-select stays intact.
        state.selectedNodeIDs.remove(nodeID)
    }
}

// MARK: - Size measurement

private struct TextSizePrefKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        value = CGSize(width:  max(value.width,  n.width),
                       height: max(value.height, n.height))
    }
}
