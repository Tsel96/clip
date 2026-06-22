import SwiftUI
import AppKit

/// Figma 104:651 — the action bar shown above a SELECTED sticky note: Download ·
/// Color · Folder, rendered in the app's green-outer / yellow-inner pill (the
/// toolbar family). Color opens a swatch popover; Folder creates a folder and
/// tucks the sticker in; Download exports the sticker as a PNG.
struct StickyActionBar: View {
    let current: StickyColor
    let onDownload: () -> Void
    let onPickColor: (StickyColor) -> Void
    let onFolder: () -> Void
    @State private var showColors = false

    private static let green  = Color(rgb: 0x3DA726)
    private static let topY   = Color(rgb: 0xFFF53B)
    private static let botY   = Color(rgb: 0xF8DE47)
    private static let border = Color(rgb: 0xFFFCA9)
    private static let shadow = Color(rgb: 0x005C02)

    var body: some View {
        HStack(spacing: 0) {
            barButton("square.and.arrow.down", "Download image", action: onDownload)
            barButton("drop", "Colour") { showColors.toggle() }
                .popover(isPresented: $showColors, arrowEdge: .bottom) { palette }
            barButton("folder.badge.plus", "Add to a new folder", action: onFolder)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 50, style: .continuous)
                .fill(LinearGradient(colors: [Self.topY, Self.botY], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 50, style: .continuous)
                    .strokeBorder(Self.border, lineWidth: 1.5))
        )
        .padding(2)
        .background(Self.green, in: Capsule(style: .continuous))
        .shadow(color: Self.shadow.opacity(0.12), radius: 1.5, y: 2)
        .shadow(color: Self.shadow.opacity(0.10), radius: 3, y: 6)
        .shadow(color: Self.shadow.opacity(0.06), radius: 4, y: 14)
        .fixedSize()
    }

    private func barButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
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
