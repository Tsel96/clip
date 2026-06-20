import AppKit
import SwiftUI

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
        HStack(spacing: 10) {
            // The field + an explicit placeholder overlay. SwiftUI's `prompt:` did
            // not render here, so the placeholder is drawn manually and shown
            // whenever the field is empty (Figma 72:36786 — black @ 20%).
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(verbatim: "INSERT LINK HERE")
                        .font(Self.inputFont)
                        .foregroundStyle(.black.opacity(0.2))
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(Self.inputFont)
                    .foregroundStyle(.black)
                    .tint(Color(rgb: 0x3DA726))     // brand-green caret (Figma 72:36791)
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
                .opacity(0.4)
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
        .onExitCommand(perform: dismiss)            // Escape
        .onAppear { text = ""; focused = true }
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
        withAnimation(Motion.pop) { state.isLinkInputPresented = false }
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
