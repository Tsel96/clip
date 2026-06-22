import SwiftUI

/// Full-screen folder view (Spatial-style): a SOLID background tinted to the
/// folder's colour, with the folder's child cards laid out in a scrollable grid.
/// Replaces the old "sub-canvas" unfold — opening a folder is now a grid, not
/// another pannable canvas. Mounted by `CanvasView` whenever `focusedFolderID`
/// is set; the back chip (top-left) and Esc exit it.
struct FolderGridView: View {
    @ObservedObject var state: CanvasState
    let folderID: UUID

    /// Target column width; each card is scaled to it (aspect preserved).
    private let columnWidth: CGFloat = 280
    private let spacing: CGFloat = 28

    private var folder: CanvasNode? { state.nodes.first { $0.id == folderID } }

    private var children: [CanvasNode] {
        guard case .folder(_, _, let ids)? = folder?.kind else { return [] }
        return ids.compactMap { id in state.nodes.first { $0.id == id } }
    }

    /// Solid background = the folder's colour (or the default folder lavender).
    private var background: Color {
        if let hex = folder?.folderColor, let c = Color(folderHex: hex) { return c }
        return Color(folderHex: FolderGridView.defaultFolderHex) ?? Color(white: 0.93)
    }
    /// Default (untinted) folder lavender — matches `Folder_Rest` art.
    static let defaultFolderHex = "#E7E3F7"

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: columnWidth, maximum: columnWidth + 60),
                  spacing: spacing, alignment: .top)]
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            if children.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.black.opacity(0.25))
                    Text("No items yet")
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.35))
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .center, spacing: spacing) {
                        ForEach(children) { node in
                            gridCard(node)
                        }
                    }
                    .padding(.horizontal, 44)
                    .padding(.top, 96)      // clear the top folder-name pill
                    .padding(.bottom, 64)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// One card cell: render the real card content (reusing `DraggableNode` in its
    /// non-interactive `positioned: false` mode, exactly as the native canvas
    /// does), scaled down to the column width with aspect preserved.
    @ViewBuilder
    private func gridCard(_ node: CanvasNode) -> some View {
        let w = max(node.width, 1)
        let h = node.height ?? node.width
        let scale = columnWidth / w
        let cellH = min(h * scale, columnWidth * 1.6)   // cap very tall cards

        DraggableNode(node: node, positioned: false)
            .environmentObject(state)
            .frame(width: w, height: h)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: columnWidth, height: h * scale, alignment: .topLeading)
            .frame(height: cellH, alignment: .top)
            .clipped()
            .allowsHitTesting(false)        // display-only inside the folder grid
    }
}

// MARK: - FolderNameField (Figma 105-755 rest / 105-764 edit)

/// The folder-name pill shown at the top-centre IN PLACE of the Canvas/Colorform/
/// Archive segmented control while a folder is open. Green-bordered white pill
/// with the folder name in uppercase SF Mono; click to rename inline. Reuses the
/// `LinkInputBar` skin (green wrapper + white field), rearranged for renaming.
struct FolderNameField: View {
    @ObservedObject var state: CanvasState
    let folderID: UUID

    @State private var text: String = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    private var folder: CanvasNode? { state.nodes.first { $0.id == folderID } }
    private var title: String {
        if case .folder(let t, _, _)? = folder?.kind { return t }
        return ""
    }
    private static let font = Font.system(size: 15, weight: .bold, design: .monospaced)

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Text((text.isEmpty ? "Folder's name" : text).uppercased())
                    .font(Self.font)
                    .foregroundStyle(.black.opacity(text.isEmpty ? 0.3 : 1))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(Self.font)
                    .foregroundStyle(.clear)
                    .multilineTextAlignment(.center)
                    .tint(Color(rgb: 0x3DA726))
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(commit)
            }
            .fixedSize()

            // Rename glyph (Figma 105-764) — visible on hover / while editing.
            Image(systemName: "square.and.pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black.opacity(0.55))
                .opacity(hovering || focused ? 1 : 0)
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
        .frame(minWidth: 150)
        .background(whiteField)
        .padding(4)
        .background(greenWrapper)
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .onHover { hovering = $0 }
        .onAppear { text = title }
        .onChange(of: title) { newTitle in if !focused { text = newTitle } }
        .onChange(of: focused) { isFocused in if !isFocused { commit() } }
        .onExitCommand { focused = false }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        state.setFolderTitle(id: folderID, to: trimmed)
        focused = false
    }

    /// White inner pill (Figma 105: pure white + 2pt white rim).
    private var whiteField: some View {
        ZStack {
            Capsule().fill(.white)
            Capsule().strokeBorder(.white, lineWidth: 2)
        }
    }
    /// Green capsule wrapper + the brand's layered green drop shadow.
    private var greenWrapper: some View {
        Capsule()
            .fill(Color(rgb: 0x3DA726))
            .shadow(color: Color(rgb: 0x005C02).opacity(0.12), radius: 1.5, y: 2)
            .shadow(color: Color(rgb: 0x005C02).opacity(0.10), radius: 3,   y: 6)
            .shadow(color: Color(rgb: 0x005C02).opacity(0.06), radius: 4,   y: 14)
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red:   Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >>  8) & 0xFF) / 255,
                  blue:  Double( rgb        & 0xFF) / 255)
    }
    /// `#RRGGBB` (sRGB) → Color; `nil` on malformed input.
    init?(folderHex: String) {
        var s = folderHex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red:   Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >>  8) & 0xFF) / 255,
                  blue:  Double( v        & 0xFF) / 255)
    }
}
