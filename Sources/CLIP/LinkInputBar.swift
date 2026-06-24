import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Inline "Insert link here" field that drops in above the toolbar "+"
/// (Figma node 72:36784). A green capsule wraps a white pill input; submitting
/// a URL routes through `addPostFromURL`, and Escape — or re-tapping "+" —
/// dismisses it. The richer Link / From-Computer sheet stays on ⌘N.
///
/// Mounted by `CanvasView` as its own bottom overlay (NOT inside the AppKit
/// palette, whose fixed frame would clip this floating popover) and nudged to
/// sit centered above the round "+" button.
struct LinkInputBar: View {
    @EnvironmentObject var state: CanvasState
    @State private var text = ""
    @FocusState private var focused: Bool

    /// Figma 72:36785: inner white pill 292 × 50, 4 pt green padding → outer capsule 300 × 58.
    static let fieldWidth: CGFloat  = 292
    static let fieldHeight: CGFloat = 50

    /// Enter.svg (Figma 72:36787) — 24×24 submit icon from bundle.
    private static let enterIcon: NSImage? = {
        guard let url = Bundle.module.url(forResource: "Enter", withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: 24, height: 24)
        return img
    }()

    /// Monospace font shared by the placeholder and the field (Figma: SF Mono Semibold 17).
    private static let inputFont = Font.system(size: 17, weight: .semibold, design: .monospaced)

    var body: some View {
        // The "+" popover row (Figma 89-690): link input + OS-file-browser + Folder.
        HStack(spacing: 12) {
            linkInput
            iconButton("os-file-browser", help: "Import a file from your computer",
                       action: openFileBrowser)
            iconButton("popover-folder", help: "New folder") { state.addFolder(); dismiss() }
        }
        .onExitCommand(perform: dismiss)            // Escape
        // Panel is always mounted (so it can scale OUT of the "+"); focus the
        // field only when it actually opens, and clear it each time.
        .onChange(of: state.isLinkInputPresented) { shown in
            if shown {
                // Pre-fill from the clipboard if it holds a link — one Enter to add.
                text = Self.clipboardLink() ?? ""
                // Focus immediately AND again after the open animation: a panel that
                // is still scaling in (ToolbarPanelTransition) can reject first
                // responder mid-transition, so one attempt alone often misses.
                focused = true
                DispatchQueue.main.async { focused = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { focused = true }
            } else {
                focused = false
            }
        }
    }

    /// The clipboard's contents IF they look like a single URL (http(s) or a bare
    /// dotted domain, no spaces) — so opening the add field offers a paste-ready link.
    private static func clipboardLink() -> String? {
        guard let s = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, !s.contains(" "), s.count < 2048 else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        if s.contains("."), let url = URL(string: s), url.host != nil { return s }
        return nil
    }

    private var linkInput: some View {
        HStack(spacing: 10) {
            // The field + an explicit placeholder overlay. SwiftUI's `prompt:` did
            // not render here, so the placeholder is drawn manually and shown
            // whenever the field is empty (Figma 72:36786 — black @ 20%).
            ZStack(alignment: .leading) {
                // Display layer — placeholder when empty, else the typed text shown
                // UPPERCASE (Figma). `.textCase` is ignored on an editable TextField,
                // so we draw the display ourselves and keep the field's text clear.
                Text(text.isEmpty ? "INSERT LINK HERE" : text.uppercased())
                    .font(Self.inputFont)
                    .foregroundStyle(.black.opacity(text.isEmpty ? 0.2 : 1.0))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                // Real editable field — transparent text so only the uppercase
                // display shows, but the field still owns the caret + the RAW value
                // (real case preserved for the URL). SF Mono is monospaced, so the
                // hidden real text and the uppercase overlay share metrics → the
                // green caret lands in the right spot.
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(Self.inputFont)
                    .foregroundStyle(.clear)
                    .tint(Color(rgb: 0x3DA726))     // brand-green caret (Figma 72:36791)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(submit)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Trailing submit affordance — Enter.svg (Figma 72:36787), 24×24 @ 40 %.
            Button(action: submit) {
                Group {
                    if let icon = Self.enterIcon {
                        Image(nsImage: icon).resizable().renderingMode(.original)
                    } else {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: 24, height: 24)
                .opacity(text.isEmpty ? 0.4 : 1.0)   // fully opaque once there's text
            }
            .buttonStyle(.plain)
            .help("Add link to canvas")
        }
        .padding(.leading, 19)
        .padding(.trailing, 13)
        .frame(width: Self.fieldWidth, height: Self.fieldHeight)
        .background(whiteField)
        .padding(4)
        .background(greenWrapper)
    }

    // MARK: Popover buttons (Figma 89-690)

    private static func bundleIcon(_ name: String, size: CGFloat = 24) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = NSSize(width: size, height: size)
        return img
    }

    /// 36×36 white-60% pill with a 24px icon (Figma 89-676 / 89-683).
    private func iconButton(_ name: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon = Self.bundleIcon(name) {
                    Image(nsImage: icon).resizable().renderingMode(.original)
                } else {
                    Image(systemName: "questionmark").font(.system(size: 14))
                }
            }
            .frame(width: 24, height: 24)
            .frame(width: 36, height: 36)
            .background(
                Circle().fill(.white.opacity(0.6))
                    .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
                    .shadow(color: .black.opacity(0.02), radius: 4, y: 4))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func openFileBrowser() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie]
        dismiss()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importFile(url) }
    }

    private func importFile(_ url: URL) {
        let isMovie = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
        if isMovie {
            state.addVideo(fileURL: url)
        } else if let data = try? Data(contentsOf: url) {
            state.addImage(data: data, filename: url.lastPathComponent)
        }
    }

    // MARK: Skins

    /// White input pill: Figma 72:36785 — #EFEFEF at top, white reached at 43 % of height,
    /// white for the remainder. 2 pt white border on all edges (Figma `border-t-2` + border-color white).
    private var whiteField: some View {
        ZStack {
            Capsule().fill(
                LinearGradient(
                    stops: [
                        .init(color: Color(rgb: 0xEFEFEF), location: 0.00),
                        .init(color: .white,               location: 0.43),
                        .init(color: .white,               location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom))
            Capsule().strokeBorder(Color.white, lineWidth: 2)
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

    // MARK: Actions

    private func submit() {
        let url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        state.addPostFromURL(url)
        dismiss()
    }

    private func dismiss() {
        focused = false
        withAnimation(Motion.popper) { state.isLinkInputPresented = false }
    }
}

private extension Color {
    /// 0xRRGGBB literal → sRGB Color (local helper; the project has no global one).
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red:   Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >>  8) & 0xFF) / 255,
                  blue:  Double( rgb        & 0xFF) / 255)
    }
}
