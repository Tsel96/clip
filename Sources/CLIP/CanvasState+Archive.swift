import SwiftUI
import AppKit
import AVFoundation
import Combine

// Split out of CanvasState.swift (god-object refactor): archive mode.
extension CanvasState {


    // MARK: - Archive mode

    /// Switch into Archive at the top level (Calendar). Computes the
    /// per-day cache once on entry; further mutations to `nodes` while
    /// in Archive call `refreshArchiveDays()` to keep it fresh.
    func enterArchive() {
        guard canvasMode != .archive else { return }
        preArchiveCamera = camera
        let days = ArchiveEngine.daysWithContent(from: nodes)
        // Archive's calendar layer is positioned in screen coords, not
        // world coords, so we don't need the camera. Park it at neutral
        // values so any leak-through has predictable behaviour.
        let neutral = Camera(x: 0, y: 0, zoom: 1.0)
        withAnimation(Motion.structure) {
            canvasMode = .archive
            archiveLevel = .calendar
            setArchiveDays(days)
            camera = neutral
        }
    }

    /// Set `archiveDays` and the matching reverse `cardToDay` index in
    /// one place — every other entry point routes through here so the
    /// two stay in sync.
    func setArchiveDays(_ days: [Date: [UUID]]) {
        archiveDays = days
        var reverse: [UUID: Date] = [:]
        reverse.reserveCapacity(days.values.reduce(0) { $0 + $1.count })
        for (day, ids) in days {
            for id in ids { reverse[id] = day }
        }
        cardToDay = reverse
    }

    /// Pop one level up: card → day, day → calendar, calendar → exit
    /// Archive. Used by the breadcrumb and Esc handler.
    func popArchiveLevel() {
        switch archiveLevel {
        case .card(let cardID):
            withAnimation(Motion.structure) {
                // O(1) reverse lookup: which day owns this card?
                if let dayForCard = cardToDay[cardID] {
                    archiveLevel = .day(dayForCard)
                } else {
                    archiveLevel = .calendar
                }
            }
        case .day:
            withAnimation(Motion.structure) {
                archiveLevel = .calendar
                archivePositions = [:]
                archiveSizes = [:]
            }
        case .calendar:
            setMode(.canvas)
        }
    }

    /// Drill from Calendar into a specific day's Bento. Computes the
    /// cardinality-aware layout and publishes positions + sizes so the
    /// rendered cards smoothly glide into the magazine grid.
    func drillToDay(_ day: Date) {
        let normalized = Calendar.current.startOfDay(for: day)
        guard let ids = archiveDays[normalized], !ids.isEmpty else { return }
        let (positions, sizes) = ArchiveEngine.bentoLayout(
            cardIDs: ids,
            naturalSizes: ids.reduce(into: [UUID: CGSize]()) { dict, id in
                if let n = nodeByID[id] {
                    dict[id] = CGSize(width: n.width, height: renderedHeight(of: n))
                }
            },
            viewportSize: viewportSize.width > 0
                ? viewportSize
                : CGSize(width: 1200, height: 800)
        )
        withAnimation(Motion.structure) {
            archiveLevel = .day(normalized)
            archivePositions = positions
            archiveSizes = sizes
        }
    }

    /// Drill from Bento into a single card's Lightbox. Computes a
    /// centered, per-kind size for the focused card and merges it into
    /// `archivePositions` / `archiveSizes` so the existing card view
    /// glides from its bento slot to the lightbox center.
    func drillToCard(_ id: UUID) {
        guard let node = nodeByID[id] else { return }
        let viewport = viewportSize.width > 0
            ? viewportSize
            : CGSize(width: 1200, height: 800)
        let (positions, sizes) = ArchiveEngine.lightboxLayout(
            for: node,
            renderedHeight: renderedHeight(of: node),
            viewportSize: viewport
        )
        withAnimation(Motion.structure) {
            archiveLevel = .card(id)
            // Replace overrides with just the focused card's layout —
            // the rest of the day's cards aren't rendered in lightbox.
            archivePositions = positions
            archiveSizes = sizes
        }
    }

    /// Lightbox keyboard nav. `←/→` walk cards chronologically (within
    /// day, then across days at the boundaries). `↑/↓` jump to the
    /// next non-empty day's first card — skipping past empty days so
    /// the user never iterates through a calendar void.
    enum LightboxNav { case previousCard, nextCard, previousDay, nextDay }

    func lightboxNavigate(_ direction: LightboxNav) {
        guard case .card(let currentID) = archiveLevel else { return }
        // O(1) reverse lookup of the current card's day, then read its
        // ordered card list directly.
        guard let currentDay = cardToDay[currentID],
              let cardsInDay = archiveDays[currentDay]
        else { return }
        let currentIdx = cardsInDay.firstIndex(of: currentID) ?? 0

        let target: UUID?
        switch direction {
        case .previousCard:
            if currentIdx > 0 {
                target = cardsInDay[currentIdx - 1]
            } else if let prev = previousNonEmptyDay(from: currentDay) {
                target = archiveDays[prev]?.last
            } else {
                target = nil
            }
        case .nextCard:
            if currentIdx < cardsInDay.count - 1 {
                target = cardsInDay[currentIdx + 1]
            } else if let next = nextNonEmptyDay(from: currentDay) {
                target = archiveDays[next]?.first
            } else {
                target = nil
            }
        case .previousDay:
            target = previousNonEmptyDay(from: currentDay).flatMap { archiveDays[$0]?.first }
        case .nextDay:
            target = nextNonEmptyDay(from: currentDay).flatMap { archiveDays[$0]?.first }
        }

        if let t = target, t != currentID {
            drillToCard(t)
        }
    }

    private func previousNonEmptyDay(from day: Date) -> Date? {
        archiveDays.keys
            .filter { $0 < day && (archiveDays[$0]?.isEmpty == false) }
            .sorted().last
    }

    private func nextNonEmptyDay(from day: Date) -> Date? {
        archiveDays.keys
            .filter { $0 > day && (archiveDays[$0]?.isEmpty == false) }
            .sorted().first
    }

    /// Recompute the per-day cache. Called whenever `nodes` mutates
    /// while in Archive mode (so adding/removing a card refreshes the
    /// calendar heat without leaving the mode).
    func refreshArchiveDays() {
        guard canvasMode == .archive else { return }
        let days = ArchiveEngine.daysWithContent(from: nodes)
        withAnimation(.smooth(duration: 0.3)) { setArchiveDays(days) }
    }

    /// Restore the pre-Archive camera and clear transient state.
    func exitArchive() {
        guard canvasMode == .archive else { return }
        let restored = preArchiveCamera
        withAnimation(Motion.structure) {
            canvasMode = .canvas
            archiveLevel = .calendar
            setArchiveDays([:])
            archivePositions = [:]
            archiveSizes = [:]
            if let cam = restored { camera = cam }
        }
        preArchiveCamera = nil
    }

    /// Camera that frames every bulb in the layout with comfortable
    /// padding. Returns `nil` if there are no bulbs or the viewport
    /// hasn't been measured yet (initial launch races).
    func cameraFraming(bulbs: [ColorBulb]) -> Camera? {
        guard !bulbs.isEmpty, viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        // Frame the seed constellation with a comfortable cream margin
        // around it (matches the reference). `ColorformLayer` clips the
        // Voronoi cells to (seed bbox + 420pt halo); we frame the camera
        // a bit larger again so the cream canvas shows around the cells.
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for b in bulbs {
            minX = min(minX, b.center.x); minY = min(minY, b.center.y)
            maxX = max(maxX, b.center.x); maxY = max(maxY, b.center.y)
        }
        let pad: CGFloat = 620        // cell halo (420) + cream gutter (~200)
        let worldW = max(1, (maxX - minX) + pad * 2)
        let worldH = max(1, (maxY - minY) + pad * 2)
        // Cap at 0.30 so Colorform always opens zoomed-out enough to SEE the
        // colour field (it's fully faded above ~60% zoom). For a small
        // constellation this shows the cells comfortably instead of zooming past
        // the field into the (faded) cards.
        let z = min(
            min(viewportSize.width / worldW, viewportSize.height / worldH),
            0.30
        )
        let zoom = max(Self.minZoom, min(Self.maxZoom, z))
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        return Camera(
            x: viewportSize.width / 2 - centerX * zoom,
            y: viewportSize.height / 2 - centerY * zoom,
            zoom: zoom
        )
    }

    /// Background-extract dominant colors for every node on the active
    /// page. Falls back to a content-derived hue on failure (see
    /// `ColorExtraction.extract`). Served from `colorformColorCache` where
    /// possible — only nodes never extracted this session pay the cost, so
    /// the first Colorform entry does the full pass and re-entries are
    /// near-instant (the "tab uploads again" complaint).
    func refreshDominantColors() async {
        let snapshot = nodes
        var results: [UUID: RGB] = [:]
        var missing: [CanvasNode] = []
        for node in snapshot {
            if let cached = colorformColorCache[node.id] { results[node.id] = cached }
            else { missing.append(node) }
        }
        if !missing.isEmpty {
            await withTaskGroup(of: (UUID, RGB).self) { group in
                for node in missing {
                    group.addTask { (node.id, await ColorExtraction.extract(for: node)) }
                }
                for await pair in group { results[pair.0] = pair.1 }
            }
        }
        // Only adopt results if the user is still in Colorform on the same page.
        guard canvasMode == .colorform else { return }
        for node in missing { if let c = results[node.id] { colorformColorCache[node.id] = c } }
        dominantColors = results
    }
}
