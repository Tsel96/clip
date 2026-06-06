import SwiftUI

/// Calendar level of Archive mode. Renders a 7-column × N-week grid
/// where each cell represents a single local-time day, coloured by
/// activity + mood (`ArchiveEngine.calendarHeat`). Cells with content
/// punch through; empty cells fade to 4 % opacity so the grid reads as
/// "where the work happened" at a glance.
///
/// Layout decisions (Apple-tier polish):
///   • Newest week at top, oldest at bottom — matches Apple Photos's
///     descending chronology.
///   • Sunday-rooted columns (US convention; can swap to locale's
///     `firstWeekday` if requested).
///   • Today's cell has a 2 pt accent ring at all times so the user's
///     "now" is anchored.
///   • Month dividers as faint horizontal rules between weeks that
///     cross a month boundary — orients the eye without dominating.
///   • Empty-state: when there's literally nothing in the canvas, show
///     a centered prompt rather than an empty heatmap.
struct ArchiveCalendarLayer: View {
    @EnvironmentObject var state: CanvasState

    /// Top padding so the grid clears the floating mode switcher.
    private let topPadding: CGFloat = 80
    private let cellSize  = ArchiveEngine.cellSize
    private let cellGap   = ArchiveEngine.cellGap
    private let cellPitch = ArchiveEngine.cellPitch
    private let cal = Calendar.current

    var body: some View {
        if state.archiveDays.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                grid
                    .padding(.vertical, topPadding)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        VStack(spacing: 0) {
            weekdayHeader
                .padding(.bottom, 12)
            ForEach(weeks(), id: \.self) { weekStart in
                weekRow(weekStart: weekStart)
            }
        }
        .frame(width: gridWidth)
    }

    /// Sunday … Saturday weekday tick labels above the grid. 9pt
    /// rounded captions in the secondary text colour.
    @ViewBuilder
    private var weekdayHeader: some View {
        HStack(spacing: cellGap) {
            ForEach(0..<7, id: \.self) { i in
                Text(weekdayLabel(i))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(width: cellSize, height: 14, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func weekRow(weekStart: Date) -> some View {
        // Month divider when this week starts in a different month than
        // the previous one in the list.
        let showsMonthDivider = isFirstWeekOfMonth(weekStart)
        VStack(spacing: 0) {
            if showsMonthDivider {
                monthDivider(for: weekStart)
            }
            HStack(spacing: cellGap) {
                ForEach(0..<7, id: \.self) { dayIdx in
                    cell(for: cal.date(byAdding: .day, value: dayIdx, to: weekStart)!)
                }
            }
            .padding(.vertical, cellGap / 2)
        }
    }

    // MARK: - Cell

    @ViewBuilder
    private func cell(for day: Date) -> some View {
        let normalized = cal.startOfDay(for: day)
        let cards = state.archiveDays[normalized] ?? []
        let isToday = cal.isDateInToday(day)
        let isFuture = day > Date()
        let heatColor = ArchiveEngine.calendarHeat(
            cardIDs: cards,
            dominantColors: state.dominantColors,
            maxCount: maxCountAcrossDays
        )
        let hasContent = !cards.isEmpty

        Button {
            guard hasContent else { return }
            state.drillToDay(normalized)
        } label: {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isFuture ? Color.clear : heatColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(
                                Color(nsColor: .separatorColor).opacity(0.4),
                                lineWidth: 0.5
                            )
                    )
                // Today's accent ring (audit A11).
                if isToday {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
                // Day-of-month numeral in the corner. Slightly subdued
                // when the day is in a different month from the week
                // we're rendering, but for v1 we just use the secondary
                // text color always — readability over fastidiousness.
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(hasContent ? Color.primary.opacity(0.75)
                                                : Color.primary.opacity(0.35))
                    .padding(.horizontal, 6)
                    .padding(.top, 5)
            }
            .frame(width: cellSize, height: cellSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .disabled(!hasContent)
        .help(hoverDescription(day: normalized, count: cards.count))
        .accessibilityLabel(
            "\(weekdayName(day)) \(dateString(day)), \(cards.count) cards"
        )
    }

    // MARK: - Month divider

    @ViewBuilder
    private func monthDivider(for weekStart: Date) -> some View {
        HStack {
            Text(monthLabel(weekStart))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.4))
                .frame(height: 0.5)
        }
        .frame(width: gridWidth)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    // MARK: - Empty state

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Your archive is empty")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Text("Add content to the canvas — it'll appear here by date.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var gridWidth: CGFloat {
        cellPitch * 7 - cellGap
    }

    private func weeks() -> [Date] {
        ArchiveEngine.weeks(for: state.archiveDays).reversed()
    }

    private var maxCountAcrossDays: Int {
        max(1, state.archiveDays.values.map(\.count).max() ?? 1)
    }

    private func isFirstWeekOfMonth(_ weekStart: Date) -> Bool {
        // Show a month divider the first time we hit a new month in
        // the rendered (newest-first) order. Easiest: check whether
        // the previous week (one week newer) was in a different month.
        let nextWeek = cal.date(byAdding: .weekOfYear, value: 1, to: weekStart)!
        return cal.component(.month, from: weekStart)
             != cal.component(.month, from: nextWeek)
    }

    private func weekdayLabel(_ idx: Int) -> String {
        // Sun, Mon, … Sat. Use the locale's short weekday symbols and
        // offset so the column matches our Sunday-rooted layout.
        let symbols = cal.veryShortWeekdaySymbols
        return symbols[idx % 7]
    }

    private func weekdayName(_ day: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f.string(from: day)
    }

    private func dateString(_ day: Date) -> String {
        let f = DateFormatter()
        if cal.isDate(day, equalTo: Date(), toGranularity: .year) {
            f.setLocalizedDateFormatFromTemplate("MMM d")
        } else {
            f.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        }
        return f.string(from: day)
    }

    private func monthLabel(_ d: Date) -> String {
        let f = DateFormatter()
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) {
            f.setLocalizedDateFormatFromTemplate("MMMM")
        } else {
            f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        }
        return f.string(from: d)
    }

    private func hoverDescription(day: Date, count: Int) -> String {
        guard count > 0 else { return "" }
        let ds = dateString(day)
        return count == 1 ? "1 card · \(ds)" : "\(count) cards · \(ds)"
    }
}
