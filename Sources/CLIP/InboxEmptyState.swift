import SwiftUI
import AppKit

/// Shown centered on the pinned **"from my iPhone"** page while it has no
/// cards yet: invites the user to share a link from their phone and opens a
/// step-by-step setup guide. Typography + surfaces mirror the lightbox
/// inspector panel so the whole app reads one design language.
struct InboxEmptyState: View {
    @EnvironmentObject private var state: CanvasState
    @Environment(\.clipTheme) private var theme

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.surfaceInset)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: 1))
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(theme.accent)
            }
            .frame(width: 64, height: 64)

            VStack(spacing: 9) {
                Text("Send references from your iPhone")
                    .font(.clip(15.5, true))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Share any link from your phone — posts, images, videos, YouTube — and it lands on this page automatically.")
                    .font(.clip(11))
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                state.isInboxGuidePresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.accent)
                    Text("HOW TO SET IT UP")
                        .font(.clip(10.5))
                        .tracking(1.2)
                        .foregroundStyle(theme.textPrimary)
                }
                .padding(.vertical, 11)
                .padding(.horizontal, 16)
                .background(theme.surfaceElevated, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(theme.border, lineWidth: 1))
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.hover)
        }
        .frame(maxWidth: 320)
        .padding(30)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
        .shadow(color: theme.shadow, radius: 30, y: 12)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}

// MARK: - Setup guide sheet

/// Three-step "how to set up iPhone sharing" guide. Same inspector idiom:
/// SF Mono step labels, surface-inset step rows, restrained accent.
struct InboxSetupGuide: View {
    @EnvironmentObject private var state: CanvasState
    @Environment(\.clipTheme) private var theme

    /// Where the iCloud "Add to Canvas" Shortcut + setup live (the landing site).
    private let helpURL = URL(string: "https://clip-umprum.netlify.app")!

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.border)

            VStack(alignment: .leading, spacing: 20) {
                step(1, "Add the Shortcut",
                     "On your iPhone, install the “Add to Canvas” Shortcut — it puts CLIP in your Share sheet.") {
                    guideButton("Get the Shortcut", system: "arrow.up.forward.square") {
                        NSWorkspace.shared.open(helpURL)
                    }
                }
                step(2, "Point CLIP at a folder",
                     "Choose the iCloud Drive folder this Mac watches. New links drop in here.") {
                    guideButton("Choose folder…", system: "folder") { chooseFolder() }
                }
                step(3, "Share from your phone",
                     "In any app, tap Share → Add to Canvas. Links appear on this page within seconds.") { EmptyView() }
            }
            .padding(24)

            Divider().overlay(theme.border)
            HStack {
                Spacer()
                Button { state.isInboxGuidePresented = false } label: {
                    Text("DONE")
                        .font(.clip(10.5)).tracking(1.2)
                        .foregroundStyle(theme.accentInkOrInk)
                        .padding(.vertical, 9).padding(.horizontal, 18)
                        .background(theme.accent, in: Capsule(style: .continuous))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.hover)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 460)
        .background(theme.surface)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("SETUP")
                    .font(.clip(9)).tracking(1.6)
                    .foregroundStyle(theme.textTertiary)
                Text("Send references from your iPhone")
                    .font(.clip(15, true))
                    .foregroundStyle(theme.textPrimary)
            }
            Spacer()
            Button { state.isInboxGuidePresented = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.hover)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private func step<Trailing: View>(_ n: Int, _ title: String, _ desc: String,
                                      @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.clip(13, true))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 30, height: 30)
                .background(theme.surfaceInset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.clip(12.5, true))
                    .foregroundStyle(theme.textPrimary)
                Text(desc)
                    .font(.clip(11))
                    .foregroundStyle(theme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                trailing().padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private func guideButton(_ label: String, system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: system).font(.system(size: 11, weight: .semibold))
                Text(label).font(.clip(11))
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.vertical, 8).padding(.horizontal, 13)
            .background(theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.hover)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the shared-links folder"
        panel.message = "Pick an iCloud Drive folder CLIP should watch for links from your iPhone."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch Folder"
        if panel.runModal() == .OK, let url = panel.url {
            state.setSharedInboxFolder(url)
        }
    }
}

private extension ClipTheme {
    /// Readable ink for text/icons sitting on the accent fill.
    var accentInkOrInk: Color { Color(red: 0.10, green: 0.08, blue: 0.0) }
}
