import SwiftUI

/// Figma-style frame: a labelled rectangle that visually owns the cards
/// dropped inside it. Drag the header to move the section + its contents
/// as a unit; double-click the title to rename; click the colour swatch
/// to retint.
///
/// **Containment is spatial, not hierarchical.** Sections don't own their
/// contents via a foreign key — the relationship is recomputed at each
/// drag-start / delete time by `CanvasState.nodeIDs(insideWorldRect:)`.
/// This keeps the persistence schema trivial and matches Figma frames.
///
/// **Editing model.** Title rename uses a local `draftTitle` buffer that
/// is committed on Return / focus-lost. While renaming the buffer wins;
/// once not renaming, `title` from the model is authoritative — so an
/// undo of a rename is reflected immediately.
///
/// Selection chrome (accent ring + resize handles) is owned by
/// `DraggableNode` so the corner radius stays consistent.
struct SectionNodeView: View {
    @EnvironmentObject var state: CanvasState
    let node: CanvasNode
    let title: String
    let color: SectionColor

    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var hovering = false
    @FocusState private var titleFocused: Bool

    static let cornerRadius: CGFloat = 0
    private let headerHeight: CGFloat = 28

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Tinted body — fill at low alpha, border at mid alpha.
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(color.swiftUIColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(color.swiftUIColor.opacity(0.30), lineWidth: 1)
                )
                .allowsHitTesting(false)   // body is non-interactive

            // Header bar across the top — this is the section's "handle".
            headerBar
                .frame(height: headerHeight)
        }
        .onHover { newValue in
            withAnimation(.easeInOut(duration: 0.15)) { hovering = newValue }
        }
    }

    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color.swiftUIColor.opacity(0.85))
                .accessibilityHidden(true)

            if renaming {
                TextField("Section name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .focused($titleFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { cancelRename() }
                    .onChange(of: titleFocused) { focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(title.isEmpty ? "Section" : title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture(count: 2) { beginRename() }
                    .accessibilityLabel(title.isEmpty
                                        ? "Untitled section"
                                        : "Section: \(title)")
                    .accessibilityHint("Double-click to rename")
            }

            Spacer(minLength: 0)

            colorPicker
                .opacity(hovering || renaming ? 1 : 0)
                .allowsHitTesting(hovering || renaming)
                .animation(.easeInOut(duration: 0.15),
                           value: hovering || renaming)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius:     Self.cornerRadius,
                bottomLeadingRadius:  0,
                bottomTrailingRadius: 0,
                topTrailingRadius:    Self.cornerRadius,
                style: .continuous
            )
            .fill(color.swiftUIColor.opacity(0.15))
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(color.swiftUIColor.opacity(0.30))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var colorPicker: some View {
        HStack(spacing: 4) {
            ForEach(SectionColor.allCases, id: \.self) { c in
                Button {
                    setColor(c)
                } label: {
                    Circle()
                        .fill(c.swiftUIColor)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    c == color ? Color.primary.opacity(0.7) : .clear,
                                    lineWidth: 1.5
                                )
                                .padding(-2)
                        )
                }
                .buttonStyle(.hover)
                .help(c.label)
                .accessibilityLabel("\(c.label) section")
                .accessibilityAddTraits(c == color ? [.isSelected] : [])
            }
        }
    }

    // MARK: - Mutations

    private func beginRename() {
        draftTitle = title
        renaming = true
        // Defer one runloop so the @FocusState binding is wired up before
        // we try to drive focus. Without this, focus is sometimes dropped
        // on the very first rename of a freshly-created section.
        DispatchQueue.main.async { titleFocused = true }
    }

    private func commitRename() {
        guard renaming else { return }
        renaming = false
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != title {
            state.setSectionTitle(id: node.id, to: trimmed)
        }
    }

    /// Esc — exit rename without writing through.
    private func cancelRename() {
        renaming = false
        draftTitle = title
        titleFocused = false
    }

    private func setColor(_ newColor: SectionColor) {
        state.setSectionColor(id: node.id, to: newColor)
    }
}
