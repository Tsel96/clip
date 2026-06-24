import SwiftUI
import AppKit

/// Figma-style in-app update prompt. When `UpdateChecker` has downloaded and
/// verified a newer build (`available`), this overlays the app with a dimmed
/// backdrop and a centered card offering **Restart & Install** or **Install
/// Later** — replacing the old silent swap-and-relaunch so a running session is
/// never interrupted without consent. Mounted as an `.overlay` on the app root
/// (`ClipApp`); inert in dev builds (no update feed → `available` stays nil).
struct UpdateModalHost: View {
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        ZStack {
            if let update = updater.available {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .transition(.opacity)
                UpdateCard(
                    update: update,
                    onInstall: { updater.installNow() },
                    onLater: { updater.installLater() }
                )
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: updater.available)
    }
}

private struct UpdateCard: View {
    let update: UpdateChecker.AvailableUpdate
    let onInstall: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 60, height: 60)
                    .padding(.top, 28)
            }

            Text("Update Available")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 14)

            Text("CLIP \(update.version) has been downloaded and is ready to install.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)
                .padding(.horizontal, 30)

            HStack(spacing: 10) {
                Button(action: onLater) {
                    Text("Install Later").frame(maxWidth: .infinity)
                }
                .buttonStyle(UpdateButtonStyle(prominent: false))

                Button(action: onInstall) {
                    Text("Restart & Install").frame(maxWidth: .infinity)
                }
                .buttonStyle(UpdateButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 22)
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .frame(width: 344)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 34, y: 14)
    }
}

/// Pill button matching the canvas chrome: a filled dark-green primary for the
/// install action, a neutral 6%-fill secondary for "later".
private struct UpdateButtonStyle: ButtonStyle {
    let prominent: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(fill(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.black.opacity(prominent ? 0 : 0.10), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func fill(pressed: Bool) -> Color {
        if prominent {
            // CLIP's connector/accent green.
            let base = Color(red: 0.133, green: 0.62, blue: 0.34)
            return pressed ? base.opacity(0.82) : (hovering ? base.opacity(0.92) : base)
        } else {
            return Color.primary.opacity(pressed ? 0.14 : (hovering ? 0.10 : 0.06))
        }
    }
}
