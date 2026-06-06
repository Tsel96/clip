import SwiftUI
import AppKit

/// Card-stack focus mode overlay — Apple Photos / iOS Music / Files
/// folder-preview style. The view splits into two layers that must
/// mount at **different z positions** inside `CanvasView`'s ZStack:
///
///   • `.backdrop` — the dimmed material + vignette. Mounts BEHIND
///     the node group so the focused cards paint on top of it.
///   • `.chrome` — the count pill + exit chip + click-to-dismiss
///     hit zone. Mounts ABOVE the node group so it's always
///     interactable.
///
/// The actual focused cards are drawn by the existing node group
/// via `effectivePosition` / `effectiveSize` overrides; this layer
/// only supplies the surrounding atmosphere.
struct StackFocusLayer: View {
    /// Which sub-layer to render. Splitting via this enum lets a
    /// single SwiftUI view type sit at two different z positions
    /// inside the host ZStack without duplicating the @EnvironmentObject
    /// plumbing or the memberCount helper.
    enum Layer { case backdrop, chrome }
    let layer: Layer

    @EnvironmentObject var state: CanvasState

    /// Member count badge — null when not in focus.
    private var memberCount: Int {
        guard let groupID = state.focusedStackID else { return 0 }
        return state.nodes.filter { $0.groupID == groupID }.count
    }

    /// Auto-derived label for the focused stack — "3 Photos",
    /// "2 Videos", etc. Falls back to "N items" when the helper
    /// can't resolve a head (rare, only if focus survives an
    /// out-of-band mutation that removed the head node).
    private var titleLabel: String {
        guard let groupID = state.focusedStackID else { return "" }
        // Find the head of the focused group (smallest UUID member).
        let memberIDs = state.nodes
            .filter { $0.groupID == groupID }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        if let head = memberIDs.first, let name = state.groupName(forHead: head) {
            return name
        }
        return "\(memberCount) item\(memberCount == 1 ? "" : "s")"
    }

    var body: some View {
        switch layer {
        case .backdrop: backdropBody
        case .chrome:   chromeBody
        }
    }

    /// Behind-the-cards layer: dimmed material + radial vignette.
    /// Clicking anywhere on the backdrop exits focus mode.
    @ViewBuilder
    private var backdropBody: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(Color.black.opacity(0.42))
                .contentShape(Rectangle())
                .onTapGesture {
                    state.exitStackFocus()
                }
            // Radial vignette — same lensing effect ArchiveLightboxLayer
            // uses to draw the eye toward the focused grid centre.
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.clear,                 location: 0.0),
                    .init(color: Color.clear,                 location: 0.45),
                    .init(color: Color.black.opacity(0.45),   location: 1.0),
                ]),
                center: .center,
                startRadius: 240,
                endRadius: 1200
            )
            .allowsHitTesting(false)
        }
        .transition(.opacity)
    }

    /// Above-the-cards layer: the count pill + exit chip. The hit
    /// zones here are narrow so clicks elsewhere fall through to the
    /// focused cards (interactive) or all the way to the backdrop
    /// (dismiss).
    @ViewBuilder
    private var chromeBody: some View {
        ZStack(alignment: .top) {
            // A transparent fill so SwiftUI gives this ZStack the full
            // canvas frame. `allowsHitTesting(false)` lets clicks pass
            // through to the focused cards beneath; the count pill +
            // exit chip add their own (re-enabled) hit zones below.
            Color.clear
                .allowsHitTesting(false)

            HStack {
                Spacer()
                countPill
                Spacer()
            }
            .padding(.top, 24)
            .overlay(alignment: .topTrailing) {
                exitChip
                    .padding(.top, 18)
                    .padding(.trailing, 24)
            }
        }
        .transition(.opacity)
    }

    /// Content-derived caption above the grid — "3 Photos",
    /// "2 Videos", "5 Items" — same naming convention used for the
    /// on-canvas group chip so the focus mode reads consistently.
    @ViewBuilder
    private var countPill: some View {
        Text(titleLabel)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5),
                                  lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    /// Top-right exit chip — explicit X button for users who'd rather
    /// click than press Esc.
    @ViewBuilder
    private var exitChip: some View {
        Button {
            state.exitStackFocus()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        }
        .buttonStyle(.hover)
        .help("Close focus  (Esc)")
    }
}
