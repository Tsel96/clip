import SwiftUI

/// FigJam-style sticky note: pastel block with editable text and a small
/// color-swatch palette that fades in on hover.
///
/// **Editing model.** `editingText` is the live edit buffer; the model is
/// only mutated once on commit (focus-lost / ⌘Return / Esc). This collapses
/// a typing session into one undo entry — matching `TextNodeView`. While
/// not editing, `content` from the model wins, so undo / paste / programmatic
/// edits are reflected immediately.
///
/// Selection chrome (the accent ring + resize handles) is owned by
/// `DraggableNode` so the corner radius stays consistent with the sticky's
/// own rounded shape (6pt).
struct StickyNodeView: View {
    @EnvironmentObject var state: CanvasState
    let node: CanvasNode
    let content: String
    let color: StickyColor

    /// Local edit buffer; authoritative only while focused.
    @State private var editingText: String = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    static let cornerRadius: CGFloat = 1
    private let shadowLipHeight: CGFloat = 6
    private let pickerReservedHeight: CGFloat = 26

    var body: some View {
        ZStack(alignment: .bottom) {
            // Body fill + shadow lip + soft shadow underneath.
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(color.swiftUIColor)
                .shadow(color: .black.opacity(0.14), radius: 6, x: 0, y: 3)

            // Darker bottom band — the FigJam "block" feel.
            UnevenRoundedRectangle(
                topLeadingRadius:     0,
                bottomLeadingRadius:  Self.cornerRadius,
                bottomTrailingRadius: Self.cornerRadius,
                topTrailingRadius:    0,
                style: .continuous
            )
            .fill(color.shadowLip)
            .frame(height: shadowLipHeight)

            // Text editor. Reserves `pickerReservedHeight` at the bottom so
            // the color picker doesn't overlap the caret when it fades in.
            TextEditor(text: $editingText)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.black.opacity(0.85))
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, shadowLipHeight + pickerReservedHeight)
                .onAppear {
                    editingText = content
                    if state.pendingFocusNodeID == node.id {
                        // Defer one runloop tick so the @FocusState binding
                        // is wired into the responder chain first.
                        DispatchQueue.main.async { focused = true }
                    }
                }
                .onChange(of: content) { newContent in
                    // External mutation (undo / paste) — sync the buffer
                    // only when we're not the one driving the change.
                    if !focused { editingText = newContent }
                }
                .onChange(of: focused) { isFocused in
                    if !isFocused { commit() }
                }
                .onExitCommand { focused = false }       // Esc commits + blurs
                .onSubmit { focused = false }            // ⌘Return → blur

            // Color picker fades in on hover or while editing. Sits inside
            // the bottom reserved band so it never overlaps the caret.
            colorPicker
                .padding(.bottom, shadowLipHeight + 4)
                .opacity(hovering || focused ? 1 : 0)
                .allowsHitTesting(hovering || focused)
                .animation(.easeInOut(duration: 0.15),
                           value: hovering || focused)
        }
        .onHover { newValue in
            withAnimation(.easeInOut(duration: 0.15)) { hovering = newValue }
        }
    }

    // MARK: - Commit

    private func commit() {
        if editingText != content {
            state.setStickyContent(id: node.id, to: editingText)
        }
        if state.pendingFocusNodeID == node.id {
            state.pendingFocusNodeID = nil
        }
    }

    // MARK: - Color picker

    @ViewBuilder
    private var colorPicker: some View {
        HStack(spacing: 6) {
            ForEach(StickyColor.allCases, id: \.self) { c in
                Button {
                    state.setStickyColor(id: node.id, to: c)
                } label: {
                    Circle()
                        .fill(c.swiftUIColor)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    c == color ? Color.black.opacity(0.45) : .clear,
                                    lineWidth: 1.5
                                )
                                .padding(-2)
                        )
                }
                .buttonStyle(.hover)
                .help(c.label)
                .accessibilityLabel("\(c.label) sticky")
                .accessibilityAddTraits(c == color ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule(style: .continuous))
    }
}
