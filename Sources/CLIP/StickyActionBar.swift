import SwiftUI
import AppKit

/// Shared green-outer / yellow-inner pill style for the sticky bars (Figma
/// 104:651 / 104:593) — the same toolbar family as the bottom tool palette.
enum StickyBarStyle {
    static let green  = Color(rgb: 0x3DA726)
    static let topY   = Color(rgb: 0xFFF53B)
    static let botY   = Color(rgb: 0xF8DE47)
    static let border = Color(rgb: 0xFFFCA9)
    static let shadow = Color(rgb: 0x005C02)
}

extension View {
    func stickyBarPill() -> some View {
        self
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 50, style: .continuous)
                    .fill(LinearGradient(colors: [StickyBarStyle.topY, StickyBarStyle.botY],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 50, style: .continuous)
                        .strokeBorder(StickyBarStyle.border, lineWidth: 1.5))
            )
            .padding(2)
            .background(StickyBarStyle.green, in: Capsule(style: .continuous))
            .shadow(color: StickyBarStyle.shadow.opacity(0.12), radius: 1.5, y: 2)
            .shadow(color: StickyBarStyle.shadow.opacity(0.10), radius: 3, y: 6)
            .shadow(color: StickyBarStyle.shadow.opacity(0.06), radius: 4, y: 14)
            .fixedSize()
    }
}

private func stickyBarButton(_ symbol: String, _ help: String,
                             action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.black.opacity(0.82))
            .frame(width: 52, height: 52)
            .contentShape(Rectangle())
    }
    .buttonStyle(.hover)
    .help(help)
}

/// Figma 104:651 — shown in the BOTTOM toolbar when a sticky is selected:
/// Download · Color · Folder.
struct StickyActionBar: View {
    let current: StickyColor
    let onDownload: () -> Void
    let onPickColor: (StickyColor) -> Void
    let onFolder: () -> Void
    @State private var showColors = false

    var body: some View {
        HStack(spacing: 0) {
            stickyBarButton("square.and.arrow.down", "Download image", action: onDownload)
            stickyBarButton("drop", "Colour") { showColors.toggle() }
                .popover(isPresented: $showColors, arrowEdge: .top) { palette }
            stickyBarButton("folder.badge.plus", "Add to a new folder", action: onFolder)
        }
        .stickyBarPill()
    }

    private var palette: some View {
        HStack(spacing: 10) {
            ForEach(StickyColor.allCases, id: \.self) { c in
                Button { onPickColor(c); showColors = false } label: {
                    Circle()
                        .fill(Color(nsColor: c.nsColor))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(.black.opacity(c == current ? 0.5 : 0.12),
                                                       lineWidth: c == current ? 2 : 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }
}

/// Figma 104:593 — shown in the BOTTOM toolbar while EDITING a sticky's text:
/// Bold · Italic · Underline · Strike · Eraser. Actions go to the live field
/// editor via the responder chain (best-effort until sticky rich-text lands).
struct StickyTextEditBar: View {
    var body: some View {
        HStack(spacing: 0) {
            stickyBarButton("bold", "Bold") { send("toggleBold:") }
            stickyBarButton("italic", "Italic") { send("toggleItalic:") }
            stickyBarButton("underline", "Underline") { send("underline:") }
            stickyBarButton("strikethrough", "Strikethrough") { send("toggleStrikethrough:") }
            stickyBarButton("eraser", "Clear formatting") { send("removeAttributes:") }
        }
        .stickyBarPill()
    }
    private func send(_ selector: String) {
        NSApp.sendAction(Selector((selector)), to: nil, from: nil)
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

/// Minimal sticky rendering used only for PNG export (Download).
struct StickyExportView: View {
    let content: String
    let color: StickyColor
    var body: some View {
        Text(content)
            .font(.system(size: 16, weight: .medium, design: .rounded))
            .foregroundStyle(.black.opacity(0.85))
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: color.nsColor))
    }
}
