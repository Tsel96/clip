import SwiftUI

/// Floating chrome pill shown in Archive's Day and Card levels. Click
/// the leading chevron to pop one level (Card → Day, Day → Calendar).
/// The trailing date label provides orientation — exactly the audit's
/// A12 fix ("breadcrumb belongs in the chrome, not inline").
struct ArchiveBreadcrumb: View {
    @EnvironmentObject var state: CanvasState

    var body: some View {
        HStack(spacing: 0) {
            backButton

            Text("·")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)

            label
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5),
                              lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 5, y: 1)
    }

    // MARK: - Back chevron

    @ViewBuilder
    private var backButton: some View {
        Button {
            state.popArchiveLevel()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text(backLabel)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .help("Back to \(backLabel.lowercased())")
        .accessibilityLabel("Back to \(backLabel)")
    }

    // MARK: - Right-hand label

    @ViewBuilder
    private var label: some View {
        Text(currentLabel)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
    }

    // MARK: - Strings

    /// Label for the back button — names the level we'd pop to.
    private var backLabel: String {
        switch state.archiveLevel {
        case .calendar: return "Canvas"      // can't actually happen — breadcrumb hidden here
        case .day:      return "All days"
        case .card:     return "Day"
        }
    }

    /// Label shown after the dot — names where we currently are.
    private var currentLabel: String {
        switch state.archiveLevel {
        case .calendar:
            return "Calendar"
        case .day(let date):
            return formatDay(date)
        case .card(let cardID):
            // O(1) reverse lookup of the owning day, then the card's
            // index within that day — shows "Mar 4 · 3 of 7".
            if let date = state.cardToDay[cardID],
               let ids = state.archiveDays[date] {
                let idx = (ids.firstIndex(of: cardID) ?? 0) + 1
                return "\(formatDay(date)) · \(idx) of \(ids.count)"
            }
            return "Card"
        }
    }

    private func formatDay(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date)     { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
            f.setLocalizedDateFormatFromTemplate("EEEE, MMM d")
        } else {
            f.setLocalizedDateFormatFromTemplate("EEEE, MMM d, yyyy")
        }
        return f.string(from: date)
    }
}
