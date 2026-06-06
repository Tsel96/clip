import SwiftUI

/// Transient in-app toast payload (e.g. an arrival from the iPhone share
/// inbox). Lives on `CanvasState.toast`; auto-dismissed by `showToast`.
struct ToastContent: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let systemImage: String
}

/// A small frosted capsule that slides in from the top of the canvas when
/// something arrives (currently: links shared from the iPhone). Tapping it
/// jumps to the Incoming page. Matches the app's chrome — `.regularMaterial`
/// capsule, hairline border, soft shadow.
struct ToastView: View {
    let toast: ToastContent
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: toast.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(toast.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        }
        .buttonStyle(.hover)
        .help("Go to the Incoming page")
    }
}
