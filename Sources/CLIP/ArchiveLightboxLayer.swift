import SwiftUI
import AppKit

/// Theater-mode single-card focus. The card itself is rendered by the
/// regular node group (positioned + sized via `archivePositions` /
/// `archiveSizes`) so we inherit all the existing card-content
/// renderers for free. This layer paints the chrome around it:
///
///   • A soft radial vignette over the dark backdrop (set on
///     `CanvasView.backgroundColor` for `.card` level).
///   • A bottom-of-screen caption ("Mar 4 · 3 of 7") for orientation.
///   • A per-kind primary action — Reveal in Finder for media, Open
///     Source for web embeds, Open in Canvas for everything else.
///   • Key handling for ← → ↑ ↓ + Esc (installed at the CanvasView
///     level so editing in other modes isn't disturbed).
struct ArchiveLightboxLayer: View {
    @EnvironmentObject var state: CanvasState
    let cardID: UUID

    var body: some View {
        ZStack(alignment: .center) {
            // Radial vignette on top of the (already dark) background.
            // Pure visual — fully non-interactive.
            RadialGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                center: .center,
                startRadius: 200,
                endRadius: 1000
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // Caption + actions sit at the bottom; the card is rendered
            // through the normal node group so we don't draw it here.
            VStack {
                Spacer()
                bottomChrome
                    .padding(.bottom, 36)
            }
        }
    }

    // MARK: - Bottom chrome

    @ViewBuilder
    private var bottomChrome: some View {
        VStack(spacing: 14) {
            captionPill
            actionRow
        }
    }

    /// Tiny rounded caption identifying where we are in the day —
    /// e.g. "Tuesday, Mar 4 · 3 of 7". Matches the breadcrumb's
    /// formatting but shows here too, where the user is staring.
    @ViewBuilder
    private var captionPill: some View {
        Text(captionText)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.78))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.10), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
            .accessibilityLabel(captionText)
    }

    /// Action buttons row — per-kind, always with "Open in Canvas"
    /// as the universal escape hatch.
    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 10) {
            ForEach(actions(), id: \.title) { action in
                actionButton(action)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: LightboxAction) -> some View {
        Button {
            action.run()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: action.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(action.title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(Color.white.opacity(0.92))
            .background(Color.white.opacity(action.emphasized ? 0.18 : 0.10),
                        in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.hover)
        .help(action.title)
    }

    // MARK: - Caption text

    private var captionText: String {
        // O(1) reverse lookup of the focused card's day, then its
        // ordered card list.
        guard let day = state.cardToDay[cardID],
              let cards = state.archiveDays[day]
        else { return "" }
        let idx = (cards.firstIndex(of: cardID) ?? 0) + 1
        let f = DateFormatter()
        let cal = Calendar.current
        if cal.isDate(day, equalTo: Date(), toGranularity: .year) {
            f.setLocalizedDateFormatFromTemplate("EEEE, MMM d")
        } else {
            f.setLocalizedDateFormatFromTemplate("EEEE, MMM d, yyyy")
        }
        return "\(f.string(from: day)) · \(idx) of \(cards.count)"
    }

    // MARK: - Per-kind actions

    /// Build the action row for the focused card. Order matters:
    /// kind-specific action first (emphasised), then "Open in Canvas"
    /// as the universal escape hatch.
    private func actions() -> [LightboxAction] {
        guard let node = state.nodeByID[cardID] else {
            return [openInCanvasAction]
        }
        switch node.kind {
        case .tweet(let url), .instagram(let url), .youtube(let url):
            return [
                LightboxAction(
                    title: "Open Source",
                    symbol: "safari",
                    emphasized: true
                ) {
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                },
                openInCanvasAction
            ]
        case .video(let fileURL, _):
            return [
                LightboxAction(
                    title: "Reveal in Finder",
                    symbol: "folder",
                    emphasized: true
                ) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                },
                openInCanvasAction
            ]
        case .image, .text, .stickyNote, .drawing, .section:
            return [openInCanvasAction]
        }
    }

    private var openInCanvasAction: LightboxAction {
        LightboxAction(
            title: "Open in Canvas",
            symbol: "arrow.up.left.and.arrow.down.right",
            emphasized: false
        ) { [cardID, state] in
            // Pop out of Archive entirely and frame Canvas on this card.
            state.setMode(.canvas)
            state.select(cardID)
            if let n = state.nodeByID[cardID] {
                let rect = CGRect(
                    x: n.position.x, y: n.position.y,
                    width: n.width, height: state.renderedHeight(of: n)
                )
                state.frameRect(rect, padding: 120)
            }
        }
    }
}

/// One row of the Lightbox action bar. Value type so a switch over
/// `actions()` produces fresh button identities cleanly.
private struct LightboxAction {
    let title: String
    let symbol: String
    let emphasized: Bool
    let run: () -> Void
}
