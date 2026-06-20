import Foundation
import SwiftUI

/// Pure layout / data helpers for Archive mode. Mirrors the role of
/// `ColorformEngine.swift` for Colorform: deterministic, side-effect-
/// free functions that the view layer consumes.
enum ArchiveEngine {

    // MARK: - Day bucketing

    /// Group every non-section node by its `addedAt`'s local-time day
    /// (per the user's current `Calendar` and timezone). Sections are
    /// excluded — they're spatial wrappers without their own date.
    ///
    /// Values are sorted by `addedAt` ascending so the Bento layout
    /// (consumed in Phase B v2) has a stable order independent of the
    /// underlying `nodes` array.
    static func daysWithContent(from nodes: [CanvasNode]) -> [Date: [UUID]] {
        let cal = Calendar.current
        var buckets: [Date: [(node: CanvasNode, idx: Int)]] = [:]
        for (idx, node) in nodes.enumerated() where !node.isSection {
            let day = cal.startOfDay(for: node.addedAt)
            buckets[day, default: []].append((node, idx))
        }
        // Stable sort within each day: by addedAt ascending, then by
        // page-array index.
        return buckets.mapValues { entries in
            entries.sorted {
                if $0.node.addedAt != $1.node.addedAt {
                    return $0.node.addedAt < $1.node.addedAt
                }
                return $0.idx < $1.idx
            }.map { $0.node.id }
        }
    }

    // MARK: - Calendar cell colouring

    /// Hybrid activity + mood colour for a calendar cell.
    ///
    /// *Lightness* tracks activity: an empty day is near-white at 4 %
    /// opacity (so the gridline anchors the calendar without visual
    /// noise), a day with `maxCount` cards reaches full saturation.
    /// *Hue* is the average of the day's cards' dominant colours
    /// (`dominantColors`), so a "blue day" reads as blue at a glance.
    /// Falls back to a neutral graphite hue when no colours have been
    /// extracted yet (Archive doesn't run the extractor itself — it'd
    /// be too expensive on entry; mood is upgraded opportunistically
    /// if Colorform has already populated the cache during this
    /// session, otherwise the cell is plain graphite).
    static func calendarHeat(
        cardIDs: [UUID],
        dominantColors: [UUID: RGB],
        maxCount: Int
    ) -> Color {
        let count = cardIDs.count
        guard count > 0 else {
            return Color.black.opacity(0.04)        // empty days fade away
        }
        // Activity: 0..1 normalised, eased so the curve saturates fast
        // (a single card is already clearly visible).
        let activity = pow(min(1, Double(count) / max(1, Double(maxCount))), 0.6)

        // Mood: average the available dominant colours; fall back to
        // neutral graphite if none have been extracted in this session.
        var r: Double = 0, g: Double = 0, b: Double = 0, n: Int = 0
        for id in cardIDs {
            guard let c = dominantColors[id] else { continue }
            r += c.r; g += c.g; b += c.b; n += 1
        }
        if n == 0 {
            // Graphite, lightness modulated by activity.
            let v = 0.85 - 0.55 * activity
            return Color(red: v, green: v, blue: v)
        }
        let mr = r / Double(n), mg = g / Double(n), mb = b / Double(n)
        // Pull the mood toward off-white at low activity, toward its
        // saturated hue at high activity. Keeps the calendar legible
        // (no full-saturation blocks at a glance).
        let bg = 0.97
        let mix = 0.25 + 0.65 * activity      // 0.25 .. 0.90
        return Color(
            red:   bg + (mr - bg) * mix,
            green: bg + (mg - bg) * mix,
            blue:  bg + (mb - bg) * mix
        )
    }

    // MARK: - Grid layout

    /// Width of a single calendar cell, including the 4 pt gap to the
    /// next cell. The layout reads as a 7-wide grid: Sunday … Saturday.
    static let cellSize: CGFloat = 56
    static let cellGap: CGFloat = 4
    static let cellPitch: CGFloat = cellSize + cellGap

    // MARK: - Bento layout

    /// Cardinality-aware Bento layout for one day's cards. Returns
    /// world-space (= viewport-space, since Archive parks the camera
    /// at neutral 0,0,1.0) positions + sizes per card.
    ///
    /// Per-cardinality layouts (Apple Photos "Memories" pattern):
    ///   1 → single centered hero, ~65 % viewport width
    ///   2 → two equal columns
    ///   3 → hero on top + two stacked below
    ///   4+ → 3-column stable shelf-pack (shortest-column-next)
    static func bentoLayout(
        cardIDs: [UUID],
        naturalSizes: [UUID: CGSize],
        viewportSize: CGSize
    ) -> (positions: [UUID: CGPoint], sizes: [UUID: CGSize]) {
        let topInset: CGFloat   = 96    // clear the breadcrumb pill
        let sideInset: CGFloat  = 64
        let bottomInset: CGFloat = 48
        let gutter: CGFloat = 16
        let usableW = max(200, viewportSize.width - sideInset * 2)
        let usableH = max(200, viewportSize.height - topInset - bottomInset)

        var positions: [UUID: CGPoint] = [:]
        var sizes:     [UUID: CGSize]  = [:]

        // Helper: aspect-preserving height for a card at a target width.
        func heightFor(_ id: UUID, width: CGFloat) -> CGFloat {
            let n = naturalSizes[id] ?? CGSize(width: 360, height: 240)
            return max(80, width * (n.height / max(1, n.width)))
        }
        // Helper: clamp a card height so a single card doesn't dwarf
        // the viewport — used for the 1- and 3-card hero slots.
        func clampedHeroHeight(_ desired: CGFloat) -> CGFloat {
            return min(desired, usableH * 0.85)
        }

        switch cardIDs.count {
        case 0:
            return ([:], [:])

        case 1:
            // Centered hero. Width = 65 % viewport; height honours
            // aspect but capped to 85 % of usable height. Center
            // vertically within the bento area.
            let id = cardIDs[0]
            let w  = usableW * 0.65
            let h  = clampedHeroHeight(heightFor(id, width: w))
            let x  = sideInset + (usableW - w) / 2
            let y  = topInset + (usableH - h) / 2
            sizes[id] = CGSize(width: w, height: h)
            positions[id] = CGPoint(x: x, y: y)

        case 2:
            // Two equal columns, vertically centered.
            let colW = (usableW - gutter) / 2
            // Tallest card determines the row height (the shorter card
            // is centered vertically within its slot).
            let heights = cardIDs.map { heightFor($0, width: colW) }
            let rowH = min(heights.max() ?? colW * 0.7, usableH * 0.85)
            let y = topInset + (usableH - rowH) / 2
            for (i, id) in cardIDs.enumerated() {
                let h = min(heights[i], rowH)
                let x = sideInset + CGFloat(i) * (colW + gutter)
                let yi = y + (rowH - h) / 2
                sizes[id] = CGSize(width: colW, height: h)
                positions[id] = CGPoint(x: x, y: yi)
            }

        case 3:
            // Hero on top spanning full width; two equal cards below.
            let hero = cardIDs[0]
            let heroW = usableW
            let heroH = min(heightFor(hero, width: heroW), usableH * 0.50)
            sizes[hero] = CGSize(width: heroW, height: heroH)
            positions[hero] = CGPoint(x: sideInset, y: topInset)

            let bottomY = topInset + heroH + gutter
            let colW = (usableW - gutter) / 2
            let remH = max(80, usableH - heroH - gutter)
            for (i, id) in cardIDs.dropFirst().enumerated() {
                let natural = heightFor(id, width: colW)
                let h = min(natural, remH)
                let x = sideInset + CGFloat(i) * (colW + gutter)
                sizes[id] = CGSize(width: colW, height: h)
                positions[id] = CGPoint(x: x, y: bottomY)
            }

        default:
            // 3-column stable shelf-pack. New cards land in the
            // shortest column — so adding a card never reshuffles
            // existing tiles (audit A4).
            let columnCount = 3
            let colW = (usableW - gutter * CGFloat(columnCount - 1))
                       / CGFloat(columnCount)
            var columnHeights = Array(repeating: CGFloat(0), count: columnCount)

            for id in cardIDs {
                let h = heightFor(id, width: colW)
                // Shortest column.
                var col = 0
                for i in 1..<columnCount where columnHeights[i] < columnHeights[col] {
                    col = i
                }
                let x = sideInset + CGFloat(col) * (colW + gutter)
                let y = topInset + columnHeights[col]
                sizes[id] = CGSize(width: colW, height: h)
                positions[id] = CGPoint(x: x, y: y)
                columnHeights[col] += h + gutter
            }
        }

        return (positions, sizes)
    }

    // MARK: - Lightbox layout

    /// Centered single-card layout for the Lightbox level. Per-kind
    /// sizing per audit A8: image / video get aspect-fit at ≤ 85 %
    /// usable; sticky and text get a calmer 1.5× upsize; drawing fits
    /// to ≤ 70 %; tweet / instagram use a fixed 480 pt card width.
    static func lightboxLayout(
        for node: CanvasNode,
        renderedHeight: CGFloat,
        viewportSize: CGSize
    ) -> (positions: [UUID: CGPoint], sizes: [UUID: CGSize]) {
        let topInset: CGFloat    = 96      // breadcrumb + breathing
        let bottomInset: CGFloat = 132     // caption + action row
        let sideInset: CGFloat   = 96
        let usableW = max(200, viewportSize.width  - sideInset * 2)
        let usableH = max(200, viewportSize.height - topInset - bottomInset)

        let natW = max(1, node.width)
        let natH = max(1, renderedHeight)
        let aspect = natW / natH

        let size: CGSize = {
            switch node.kind {
            case .image, .video, .youtube:
                // Aspect-fit within 85 % of the usable area.
                let maxW = usableW * 0.85
                let maxH = usableH * 0.95
                let scale = min(maxW / natW, maxH / natH)
                return CGSize(width: natW * scale, height: natH * scale)

            case .tweet, .instagram, .webclip:
                // Fixed 480 pt card width, height by natural aspect,
                // capped to the usable height.
                let w: CGFloat = 480
                let candidateH = w / aspect
                let cappedH = min(candidateH, usableH * 0.95)
                if candidateH > cappedH {
                    return CGSize(width: cappedH * aspect, height: cappedH)
                }
                return CGSize(width: w, height: candidateH)

            case .stickyNote, .text:
                // 1.5× the natural size, capped to 70 % usable so a big
                // sticky doesn't fill the screen with type.
                let scale: CGFloat = 1.5
                let w = min(natW * scale, usableW * 0.7)
                let h = min(natH * scale, usableH * 0.85)
                return CGSize(width: w, height: h)

            case .drawing:
                // Aspect-fit within 70 % of the usable area.
                let maxW = usableW * 0.7
                let maxH = usableH * 0.85
                let scale = min(maxW / natW, maxH / natH)
                return CGSize(width: natW * scale, height: natH * scale)

            case .section, .folder:
                // Sections shouldn't appear in Lightbox (they're hidden
                // upstream in archive `daysWithContent`) — fall back
                // safely.
                return CGSize(width: 240, height: 120)
            }
        }()

        // Center horizontally; center vertically within the usable area.
        let x = (viewportSize.width  - size.width)  / 2
        let y = topInset + (usableH - size.height) / 2

        return (
            positions: [node.id: CGPoint(x: x, y: y)],
            sizes:     [node.id: size]
        )
    }

    /// Generate the ordered list of weeks (oldest first) from the
    /// earliest dated card back to today's week — clipped to a minimum
    /// 8-week span so a brand-new canvas still shows a recognisable
    /// calendar.
    ///
    /// Each `Week` carries its `startOfWeek` so the calendar layer can
    /// stamp month dividers and render the date inside each cell.
    static func weeks(
        for days: [Date: [UUID]],
        today: Date = Date(),
        minimumWeeksBack: Int = 8
    ) -> [Date] {
        let cal = Calendar.current
        let todayStartOfWeek = cal.dateInterval(
            of: .weekOfYear, for: today
        )?.start ?? today

        let earliest: Date = days.keys.min() ?? today
        let earliestStartOfWeek = cal.dateInterval(
            of: .weekOfYear, for: earliest
        )?.start ?? earliest

        var weeksBack = max(
            minimumWeeksBack,
            cal.dateComponents([.weekOfYear],
                               from: earliestStartOfWeek,
                               to: todayStartOfWeek).weekOfYear ?? 0
        ) + 1   // include the earliest week itself

        // Generate oldest → newest so the calendar can render with the
        // newest row at the top by reversing the iteration.
        var result: [Date] = []
        while weeksBack > 0 {
            if let d = cal.date(byAdding: .weekOfYear,
                                value: -(weeksBack - 1),
                                to: todayStartOfWeek) {
                result.append(d)
            }
            weeksBack -= 1
        }
        return result.reversed()                // newest first
    }
}
