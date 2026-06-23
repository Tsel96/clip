import SwiftUI
import AppKit
import AVFoundation
import Combine

@MainActor
final class CanvasState: ObservableObject {

    // MARK: - Pages  (per-page state lives inside each Page)

    @Published var pages: [Page]
    @Published var activePageID: UUID { didSet { if activePageID != oldValue { cachedWorldBounds = nil } } }

    /// iPhone → canvas share inbox: watches a user-chosen iCloud Drive
    /// folder for links dropped by the "Add to Canvas" Shortcut.
    let sharedInbox = SharedLinkInbox()
    /// The folder currently being watched (nil until the user picks one),
    /// surfaced for the sidebar status line.
    @Published private(set) var sharedInboxFolderURL: URL?

    /// Transient in-app toast (e.g. "Added a YouTube link from iPhone").
    /// Rendered by `CanvasView`; auto-dismissed by `showToast`.
    @Published var toast: ToastContent?
    private var toastDismissWork: DispatchWorkItem?

    /// The live pan/zoom camera lives on its own `CameraStore` (see that
    /// type) so a pan tick invalidates only the camera-transformed views,
    /// never the node views. `camera` below is a pass-through to it, so
    /// existing `state.camera` call sites are unchanged. Per-page camera
    /// is still persisted: the auto-save pipeline syncs `camera` back into
    /// `pages[activePageIndex].camera`, and `switchTo(pageID:)` swaps it.
    let cameraStore = CameraStore()
    /// Stack-focus mode: when set, holds the `groupID` of the stack
    /// the user double-clicked. Members of that group are temporarily
    /// un-hidden and rendered at `focusPositions[id]` / `focusSizes[id]`
    /// instead of being filtered out by `isHiddenByStack`. Esc /
    /// click-out clears this and the cards spring back into the stack.
    @Published var focusedStackID: UUID? = nil
    /// The unfolded folder, if any. While set, the canvas shows ONLY that
    /// folder's children (`canvasDisplayNodes`) under its own fitted camera;
    /// Esc / the back affordance clears it and restores the prior camera.
    @Published var focusedFolderID: UUID? = nil
    /// Per-member target world position while in focus mode. Empty
    /// outside focus mode; populated by `enterStackFocus`. Read by
    /// `effectivePosition` to override the node's stored position.
    @Published var focusPositions: [UUID: CGPoint] = [:]
    /// Per-member target world size while in focus mode. Same
    /// semantics as `focusPositions`. Read by `effectiveSize`.
    @Published var focusSizes: [UUID: CGSize] = [:]
    /// Camera state captured at the moment the user entered focus
    /// mode, so `exitStackFocus` can restore the pan + zoom they had
    /// before. Focus mode resets the live camera to `(0, 0, 1)` so
    /// the grid uses the viewport's natural coords.
    var focusOriginCamera: Camera? = nil

    /// Figma-style Smart Selection state machine. Owned here so it shares
    /// the canvas lifetime; published as an environment object so the
    /// chrome layer + key monitor can reach it. Lazily wired post-`init`
    /// so the controller can hold an `unowned` reference back here.
    var smartSelection: SmartSelectionController!
    var camera: Camera {
        get { cameraStore.camera }
        set {
            let zoomChanged = abs(newValue.zoom - cameraStore.camera.zoom) > 0.0001
            cameraStore.camera = newValue
            markCameraInteracting()
            if zoomChanged { markZoomInteracting() }
        }
    }

    /// True while the camera is actively moving (pan / zoom / glide). While
    /// set, `isLive` drops every NSView-backed media card (WKWebView /
    /// AVPlayer) to its static SwiftUI poster, so none of those views is
    /// transformed inside the hosting hierarchy — that transform-during-
    /// layout is what re-enters AppKit's constraint engine and trips the
    /// depth-16 recursion guard on macOS 26/27 (EXC_BREAKPOINT in
    /// -[NSView _layoutSubtreeWithOldSize:]). Flips once at gesture start
    /// and once ~0.15 s after it ends — not per pan tick.
    @Published private(set) var isCameraInteracting = false
    private var cameraSettleTimer: Timer?

    /// Nodes currently being DRAGGED (or option-drag copies) — their heavy web
    /// content renders as a cheap poster for the duration so the drag stays smooth.
    @Published var draggingNodeIDs: Set<UUID> = []

    /// Mark the camera as moving and (re)arm the settle timer. Default
    /// runloop mode is deliberate: the timer cannot fire during
    /// `.eventTracking`, so the flag stays true for the whole gesture and
    /// clears only once the runloop returns to `.default` (gesture ended).
    private func markCameraInteracting() {
        if !isCameraInteracting { isCameraInteracting = true }
        cameraSettleTimer?.invalidate()
        cameraSettleTimer = Timer.scheduledTimer(
            withTimeInterval: 0.15, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.isCameraInteracting = false }
        }
    }

    /// True only while the *zoom* is actively changing (not pan). Drives
    /// dropping `AVPlayerLayer`-backed video cards to their poster *during a
    /// zoom*: SwiftUI's `.scaleEffect` renders the live player black, and an
    /// NSView-backed player composites above any SwiftUI cover, so the only
    /// reliable fix is to unmount it for the duration of the zoom. Scoped to
    /// zoom (pan leaves video live, as the team intends). Same `.default`-mode
    /// settle-timer trick as `isCameraInteracting`.
    @Published private(set) var isZoomInteracting = false
    private var zoomSettleTimer: Timer?

    private func markZoomInteracting() {
        if !isZoomInteracting { isZoomInteracting = true }
        zoomSettleTimer?.invalidate()
        zoomSettleTimer = Timer.scheduledTimer(
            withTimeInterval: 0.2, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.isZoomInteracting = false }
        }
    }

    /// Bumped whenever `camera.zoom` changes (never on pan). Node views
    /// observe `CanvasState`, so this is how their semantic-zoom gate
    /// (`isLive`) re-evaluates on zoom without re-rendering on every pan
    /// tick. Maintained by the `cameraStore` subscription (`setupZoomWatch`).
    @Published var zoomEpoch: Int = 0
    private var lastObservedZoom: CGFloat = 1
    private var cameraCancellable: AnyCancellable?

    /// O(1) lookup index over `nodes`. Maintained as a side-effect of the
    /// `nodes` setter so callers can read `state.nodeByID[id]` instead of
    /// `state.nodes.first(where: { $0.id == id })`. Not `@Published` —
    /// it's a derived cache, so it doesn't fire its own observer storm;
    /// reactive views still re-render because the underlying `nodes`
    /// mutation already publishes `$pages`.
    // internal setter so split-out extensions can patch the index after the god-object split.
    var nodeByID: [UUID: CanvasNode] = [:]

    init() {
        // Restore from disk, falling back to a single empty "Page 1".
        if let snapshot = CanvasStore.load(), !snapshot.pages.isEmpty {
            // Sections are being retired in favour of folders — drop any that
            // were saved so they disappear from the canvas (the cards they
            // visually contained stay, since containment was spatial).
            self.pages = snapshot.pages.map { page in
                var p = page
                p.nodes = p.nodes.filter { if case .section = $0.kind { return false }; return true }
                return p
            }
            self.activePageID =
                snapshot.pages.contains(where: { $0.id == snapshot.activePageID })
                ? snapshot.activePageID
                : snapshot.pages[0].id
        } else {
            let firstPage = Page(name: "Page 1")
            self.pages = [firstPage]
            self.activePageID = firstPage.id
        }
        // Migrate any nodes loaded from a pre-`addedAt` snapshot (their
        // decoded value is `Date.distantPast`). We rewrite to synthetic
        // ascending dates so chronology is preserved — newer array index
        // = newer timestamp, anchored just before "now."
        Self.migrateAddedAtSentinels(in: &self.pages)
        // Rename/pin the iPhone inbox page if it was created under an older
        // name, and float pinned pages to the top.
        Self.migrateIncomingPage(in: &self.pages)
        // Hydrate the live camera + index from the just-loaded active page.
        let activeIdx = self.pages.firstIndex(where: { $0.id == self.activePageID }) ?? 0
        self.camera = self.pages[activeIdx].camera
        self.nodeByID = Dictionary(
            uniqueKeysWithValues: self.pages[activeIdx].nodes.map { ($0.id, $0) }
        )
        // Restore user prefs (last view mode).
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.k_lastViewMode),
           let mode = CanvasMode(rawValue: raw),
           mode.isViewMode, mode != .colorform {
            self.lastViewMode = mode
        }
        // Restore the *exact* mode the user was in at quit (Canvas is
        // the default if nothing saved; Colorform / Archive
        // are re-entered after the viewport has measured itself — see
        // `CanvasView.restoreLastViewModeIfNeeded`).
        if let raw = defaults.string(forKey: Self.k_canvasMode),
           let mode = CanvasMode(rawValue: raw) {
            self.pendingRestoredMode = mode
        }
        setupAutoSave()
        setupPrefsAutoSave()
        setupZoomWatch()
        setupTerminationFlush()
        // Wire the Smart Selection controller after everything else so
        // its Combine subscriptions on `$selectedNodeIDs` / `$pages` /
        // `$canvasMode` see the fully-hydrated state.
        self.smartSelection = SmartSelectionController(state: self)
        // Pre-warm every video card's first-frame poster into the
        // process-wide `VideoPosterStore` cache so subsequent off-viewport
        // uses (card-stack ghosts, semantic-zoom resting state) render
        // their thumbnails instantly with no flash of the black fallback.
        // Decode is utility priority + cached, so this never blocks UI.
        prewarmVideoPosters()
        // iPhone → canvas share inbox: route arrivals to the Incoming page,
        // then resume watching the previously-chosen folder (if any).
        sharedInbox.onURL = { [weak self] url in self?.ingestSharedURL(url) }
        restoreSharedInboxFolder()
    }

    /// Async-decode every local video node's first-frame poster on
    /// launch. The `VideoPosterStore` cache makes this idempotent —
    /// subsequent groupings, semantic-zoom transitions, and Smart
    /// Selection ghost views all hit the warm cache and paint covers
    /// in the same frame they appear.
    private func prewarmVideoPosters() {
        var urls: Set<URL> = []
        for page in pages {
            for node in page.nodes {
                if case .video(let url, _) = node.kind {
                    urls.insert(url)
                }
            }
        }
        for url in urls {
            Task { @MainActor in
                await GhostThumbnailStore.shared.preload(videoAt: url)
            }
        }
    }

    /// Set on launch from the persisted `k_canvasMode`. Read once by
    /// `CanvasView` after the GeometryReader has measured the viewport
    /// (modes that re-layout need a real size), then cleared.
    var pendingRestoredMode: CanvasMode? = nil

    private static let k_lastViewMode         = "view.lastMode"
    /// The exact `canvasMode` the user was in at quit time — including
    /// Canvas itself, unlike `lastViewMode` which only tracked view modes
    /// for cross-mode "exit back to" purposes.
    private static let k_canvasMode           = "view.canvasMode"

    /// Walk every loaded node; for any whose `addedAt` is the sentinel
    /// `Date.distantPast` (meaning the snapshot pre-dated the field),
    /// rewrite to a synthetic timestamp keyed off the node's array
    /// position. Older index = older timestamp; the newest pre-existing
    /// node lands ~1 ms before `Date.now`.
    private static func migrateAddedAtSentinels(in pages: inout [Page]) {
        let now = Date()
        for pIdx in pages.indices {
            let count = pages[pIdx].nodes.count
            for nIdx in pages[pIdx].nodes.indices {
                guard pages[pIdx].nodes[nIdx].addedAt == .distantPast else { continue }
                let offset = TimeInterval(count - nIdx - 1) * -0.001
                pages[pIdx].nodes[nIdx].addedAt = now.addingTimeInterval(offset)
            }
        }
    }

    /// Persist `lastViewMode` to `UserDefaults` whenever it changes.
    /// Cheap (just a string write), no debounce.
    private var prefsCancellables: Set<AnyCancellable> = []
    private func setupPrefsAutoSave() {
        $lastViewMode
            .dropFirst()
            .sink { mode in
                if let raw = mode?.rawValue {
                    UserDefaults.standard.set(raw, forKey: Self.k_lastViewMode)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.k_lastViewMode)
                }
            }
            .store(in: &prefsCancellables)
        // Persist the *actual* current mode so the next launch reopens
        // the user exactly where they left off (Canvas / Archive
        // / Colorform). Colorform is allowed here — the launch-time
        // restoration in `CanvasView.restoreLastViewModeIfNeeded` does
        // the async re-entry.
        $canvasMode
            .dropFirst()
            .sink { mode in
                UserDefaults.standard.set(mode.rawValue, forKey: Self.k_canvasMode)
            }
            .store(in: &prefsCancellables)
    }

    // MARK: - Auto-persistence

    private var autoSaveCancellable: AnyCancellable?

    /// Combine pipeline: any mutation to `pages`, `activePageID`, or the
    /// live `camera` schedules a debounced (~0.5 s) atomic write to
    /// `~/Library/Application Support`. Silent, no Save dialog — the
    /// canvas is restored on the next launch.
    private func setupAutoSave() {
        autoSaveCancellable = Publishers
            .CombineLatest3($pages, $activePageID, cameraStore.$camera)
            .dropFirst()                              // skip the initial value
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.saveToDisk() }
            }
    }

    /// Watch the camera store; bump `zoomEpoch` only when the *zoom*
    /// changes (panning leaves it untouched), so node views re-evaluate
    /// `isLive` on zoom without re-rendering on every pan tick.
    /// When true (native NSCollectionView canvas active), don't bump
    /// `zoomEpoch` on zoom: the native cards are always-live and positioned by
    /// the collection layout, so a zoom must NOT re-render them (that re-render
    /// — swapping poster↔live — is the card-blink at gesture boundaries). The
    /// minimap / zoom readout still update because they observe `cameraStore`
    /// directly, not `zoomEpoch`.
    var suppressZoomEpoch = false

    private func setupZoomWatch() {
        lastObservedZoom = cameraStore.camera.zoom
        cameraCancellable = cameraStore.$camera
            .sink { [weak self] cam in
                guard let self, cam.zoom != self.lastObservedZoom else { return }
                self.lastObservedZoom = cam.zoom
                if !self.suppressZoomEpoch { self.zoomEpoch &+= 1 }
            }
    }

    /// The native NSCollectionView canvas can't drive `isZoomInteracting` through
    /// the `camera` setter (its scroll writes `cameraStore` directly), so the
    /// scroll-view's magnify callback drives it through these. Toggling the
    /// `@Published` flag re-renders every card once at the zoom's start and end,
    /// which is exactly when `isLive` needs to flip media to/from its poster.
    func nativeZoomBegan() { if !isZoomInteracting { isZoomInteracting = true } }
    func nativeZoomEnded() { if isZoomInteracting { isZoomInteracting = false } }

    /// The full document as it should hit disk: the live camera is flushed
    /// into a LOCAL copy of `pages` — mutating `self.pages` here would fire
    /// `$pages` and re-trigger the debounced save in an infinite loop.
    private var snapshotForDisk: CanvasSnapshot {
        var pagesForDisk = pages
        if let activeIdx = pagesForDisk.firstIndex(where: { $0.id == activePageID }) {
            pagesForDisk[activeIdx].camera = camera
        }
        return CanvasSnapshot(pages: pagesForDisk, activePageID: activePageID)
    }

    @MainActor
    private func saveToDisk() {
        // Snapshot construction is a cheap copy-on-write value copy; the
        // expensive part (JSON encode of every page, including embedded
        // image bytes, plus the disk write) happens on `CanvasStore`'s
        // background queue so it can never hitch an interaction.
        CanvasStore.saveAsync(snapshotForDisk)
    }

    /// Last-chance synchronous write at quit. The auto-save is debounced
    /// (0.5 s) and encodes on a background queue, so without this a
    /// mutation made just before ⌘Q could miss the disk.
    private func setupTerminationFlush() {
        terminationCancellable = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                CanvasStore.saveSync(self.snapshotForDisk)
            }
    }

    private var terminationCancellable: AnyCancellable?

    /// Index of the currently active page in `pages`. Falls back to 0 if the
    /// active id has somehow gone stale (shouldn't happen, but defensive).
    var activePageIndex: Int {
        pages.firstIndex(where: { $0.id == activePageID }) ?? 0
    }

    /// The current page, useful for places that want everything at once.
    var activePage: Page {
        get { pages[activePageIndex] }
        set { pages[activePageIndex] = newValue }
    }

    /// Computed forwards into the active page so all existing call sites
    /// (`state.nodes.append(...)`, `state.connectors`) keep working unchanged.
    /// Mutating these triggers `$pages` because Swift performs a
    /// get-mutate-set cycle on the array element, which counts as a
    /// mutation of `pages` itself.
    ///
    /// The `nodes` setter also rebuilds `nodeByID` so connector routing
    /// and hit-testing get O(1) lookups for free.
    var nodes: [CanvasNode] {
        get {
            guard pages.indices.contains(activePageIndex) else { return [] }
            return pages[activePageIndex].nodes
        }
        set {
            guard pages.indices.contains(activePageIndex) else { return }
            pages[activePageIndex].nodes = newValue
            nodeByID = Dictionary(uniqueKeysWithValues: newValue.map { ($0.id, $0) })
            // Keep Archive's per-day cache fresh whenever the doc
            // mutates while the user is viewing the calendar.
            if canvasMode == .archive {
                setArchiveDays(ArchiveEngine.daysWithContent(from: newValue))
            }
        }
    }

    var connectors: [Connector] {
        get {
            guard pages.indices.contains(activePageIndex) else { return [] }
            return pages[activePageIndex].connectors
        }
        set {
            guard pages.indices.contains(activePageIndex) else { return }
            pages[activePageIndex].connectors = newValue
        }
    }

    // MARK: - Page management

    /// Append a new page named "Page N" and switch to it.
    func addPage() {
        let new = Page(name: "Page \(pages.count + 1)")
        pages.append(new)
        switchTo(pageID: new.id)
    }

    func renamePage(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[idx].name = trimmed
    }

    /// Page whose deletion is awaiting user confirmation (sidebar shows a
    /// confirmation dialog while non-nil). Deleting a page destroys every
    /// card on it, so it must never be a single silent click.
    @Published var pageAwaitingDeletion: Page? = nil

    /// One-shot backup of the most recently deleted page so ⌘Z can bring
    /// it back. Cleared as soon as any other undoable mutation lands —
    /// page restoration is only offered while it is the latest action.
    private var deletedPageBackup: (page: Page, index: Int)? = nil

    /// First step of page deletion: validate, then ask. The actual removal
    /// happens in `confirmDeletePage()` once the user confirms.
    func requestDeletePage(_ id: UUID) {
        guard pages.count > 1 else {
            alert = AlertContent(
                title: "Can't delete the last page",
                message: "A document must always have at least one page."
            )
            return
        }
        guard let page = pages.first(where: { $0.id == id }) else { return }
        pageAwaitingDeletion = page
    }

    /// Second step: actually remove the page, keeping a backup so the
    /// deletion is undoable (⌘Z restores the page and its cards).
    func confirmDeletePage() {
        guard let page = pageAwaitingDeletion else { return }
        pageAwaitingDeletion = nil
        guard pages.count > 1,
              let idx = pages.firstIndex(where: { $0.id == page.id }) else { return }
        deletedPageBackup = (pages[idx], idx)
        let wasActive = (page.id == activePageID)
        pages.remove(at: idx)
        if wasActive {
            // Prefer the page that was previously above it; fall back to first.
            let newIdx = max(0, idx - 1)
            switchTo(pageID: pages[newIdx].id)
        }
        showToast("Deleted “\(page.name)” — ⌘Z to undo", systemImage: "trash")
    }

    /// Restore the most recently deleted page. Returns false when there is
    /// nothing to restore (the caller falls through to normal page undo).
    private func restoreDeletedPageIfPending() -> Bool {
        guard let backup = deletedPageBackup else { return false }
        deletedPageBackup = nil
        pages.insert(backup.page, at: min(backup.index, pages.count))
        switchTo(pageID: backup.page.id)
        return true
    }

    /// Switch the active page. Clears selection because the previously
    /// selected ids belong to a different page's node set. Also exits
    /// Colorform mode since clusters / bulbs are per-page. The outgoing
    /// page's live camera is flushed into its `Page.camera` so it's
    /// restored when the user comes back.
    func switchTo(pageID: UUID) {
        guard pages.contains(where: { $0.id == pageID }) else { return }
        if canvasMode == .colorform { exitColorform() }
        // Persist outgoing page's live camera (if the page still exists —
        // `deletePage` calls switchTo after removing the page, so we look
        // it up explicitly by id rather than via `activePageIndex`).
        if let outIdx = pages.firstIndex(where: { $0.id == activePageID }) {
            pages[outIdx].camera = camera
        }
        activePageID = pageID
        // Hydrate the live camera + node index from the incoming page.
        if let inIdx = pages.firstIndex(where: { $0.id == pageID }) {
            camera = pages[inIdx].camera
            nodeByID = Dictionary(
                uniqueKeysWithValues: pages[inIdx].nodes.map { ($0.id, $0) }
            )
        }
        selectedNodeIDs = []
        selectedConnectorIDs = []
        pendingFocusNodeID = nil
        pendingConnector = nil
        rubberBandScreenRect = nil
    }

    // MARK: - Undo / redo

    /// One stack per page so switching pages preserves history.
    @Published private(set) var undoStacks: [UUID: UndoStack] = [:]

    var canUndo: Bool {
        deletedPageBackup != nil || (undoStacks[activePageID]?.canUndo ?? false)
    }
    var canRedo: Bool { undoStacks[activePageID]?.canRedo ?? false }

    private var currentSnapshot: PageSnapshot {
        PageSnapshot(nodes: nodes, connectors: connectors)
    }

    /// Re-entrancy guard. While > 0, nested `withUndoable` calls just run
    /// the mutation without pushing — so e.g. `deleteSelected` (which calls
    /// `delete(id:)` per node) yields exactly one undo entry, not N.
    private var undoDepth = 0

    /// Wrap any state mutation that should be undoable. Snapshots the page
    /// *before* the mutation; if the mutation actually changed something,
    /// pushes that snapshot onto the active page's undo stack.
    func withUndoable(_ mutation: () -> Void) {
        if undoDepth > 0 { mutation(); return }
        undoDepth += 1
        let before = currentSnapshot
        mutation()
        let after = currentSnapshot
        undoDepth -= 1
        guard before != after else { return }
        deletedPageBackup = nil
        undoStacks[activePageID, default: UndoStack()].push(before)
    }

    /// Explicit snapshot for multi-tick interactions (e.g. drag): capture
    /// the page at gesture-start, run the gesture without `withUndoable`,
    /// then on gesture-end call `commitUndoable(from:)` with that snapshot.
    func snapshotForUndo() -> PageSnapshot { currentSnapshot }

    /// Commit an explicit snapshot — used by drag-style gestures so that
    /// 60 tick-by-tick position updates collapse into one undo entry.
    func commitUndoable(from before: PageSnapshot) {
        let after = currentSnapshot
        guard before != after else { return }
        deletedPageBackup = nil
        undoStacks[activePageID, default: UndoStack()].push(before)
    }

    func undo() {
        // A just-deleted page is the most recent action — restore it first.
        if restoreDeletedPageIfPending() { return }
        var stack = undoStacks[activePageID] ?? UndoStack()
        guard let restored = stack.popUndo(current: currentSnapshot) else { return }
        applySnapshot(restored)
        undoStacks[activePageID] = stack
        // Reset transient interaction state that might reference vanished nodes.
        selectedNodeIDs.formIntersection(Set(nodes.map(\.id)))
        selectedConnectorIDs.formIntersection(Set(connectors.map(\.id)))
        pendingConnector = nil
    }

    func redo() {
        var stack = undoStacks[activePageID] ?? UndoStack()
        guard let restored = stack.popRedo(current: currentSnapshot) else { return }
        applySnapshot(restored)
        undoStacks[activePageID] = stack
        selectedNodeIDs.formIntersection(Set(nodes.map(\.id)))
        selectedConnectorIDs.formIntersection(Set(connectors.map(\.id)))
        pendingConnector = nil
    }

    private func applySnapshot(_ s: PageSnapshot) {
        guard pages.indices.contains(activePageIndex) else { return }
        pages[activePageIndex].nodes = s.nodes
        pages[activePageIndex].connectors = s.connectors
        // Keep the lookup index in sync with the restored snapshot —
        // direct-write bypasses our `nodes` setter.
        nodeByID = Dictionary(uniqueKeysWithValues: s.nodes.map { ($0.id, $0) })
    }

    // MARK: - Document-global state

    /// Multi-selection. Singular `selectedNodeID` / `selectedConnectorID`
    /// computed properties return one element of these for code paths that
    /// don't care about multi-select semantics yet.
    @Published var selectedNodeIDs: Set<UUID> = []
    @Published var selectedConnectorIDs: Set<UUID> = []
    @Published var viewportSize: CGSize = .zero

    /// App appearance (light / dark / follow-system). Persisted across launches.
    /// Drives `preferredColorScheme` + the resolved `ClipTheme` injected at the
    /// root, so the whole UI flips with a single toggle.
    // Forced to .light: the dark theme is unfinished, so every launch starts light
    // regardless of any previously-persisted value. (Toggling still works in-session.)
    @Published var themeMode: ThemeMode = .light {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: "clip.themeMode") }
    }

    var selectedNodeID: UUID? { selectedNodeIDs.first }
    var selectedConnectorID: UUID? { selectedConnectorIDs.first }
    var hasSelection: Bool { !selectedNodeIDs.isEmpty || !selectedConnectorIDs.isEmpty }

    /// In-flight rubber-band rectangle (in canvas/screen coordinates).
    @Published var rubberBandScreenRect: CGRect? = nil

    /// Live alignment guides while a node is being dragged. Rendered by
    /// `CanvasView` as 1pt red lines over the canvas.
    @Published var activeAlignmentGuides: [AlignmentGuide] = []
    /// Pink equal-gap measurement segments shown while dragging.
    @Published var activeSpacingIndicators: [SpacingIndicator] = []

    /// Snapshot of the resized node's frame at drag-start. Lives on
    /// `CanvasState` (rather than `@State` inside `ResizeHandles`) because
    /// any of 8 handle views could be the one driving the drag, and the
    /// state needs to outlive their per-handle scope.
    var activeResizeStart: CGRect? = nil
    /// Page snapshot taken at resize-start so the whole resize collapses
    /// to one undo entry on `commitUndoable(from:)`.
    var activeResizeUndoSnapshot: PageSnapshot? = nil

    /// Whether the minimap has been popped out into its own NSPanel.
    @Published var isMinimapDetached: Bool = false {
        didSet {
            // Sync the floating window with the flag. If something else flips
            // the bool back (e.g. NSWindowDelegate.windowWillClose), the
            // controller hides itself first, then we just set the flag — so
            // calling `hide()` again is a no-op.
            if isMinimapDetached {
                minimapWindowController.show(state: self)
            } else {
                minimapWindowController.hide()
            }
        }
    }
    private lazy var minimapWindowController = MinimapWindowController()

    func detachMinimap() { isMinimapDetached = true }
    func attachMinimap() { isMinimapDetached = false }

    @Published var toolMode: ToolMode = .select
    @Published var drawColor: StrokeColor = .blue
    @Published var drawWidth: CGFloat = 3
    @Published var drawOpacity: CGFloat = 1   // < 1 = highlighter (marker)

    // MARK: - Colorform mode (transient — not persisted)

    /// `.canvas` = normal infinite canvas. `.colorform` = cards regrouped
    /// by dominant color into spatial clusters, with soft "color bulbs"
    /// fading in at low zoom. Never written to disk: the app always opens
    /// in `.canvas`.
    @Published var canvasMode: CanvasMode = .canvas
    /// Dominant color per node, populated asynchronously when entering
    /// Colorform. Empty in `.canvas` mode.
    @Published var dominantColors: [UUID: RGB] = [:]
    /// Spatial override applied to nodes in `.colorform` mode — keys missing
    /// fall through to the node's persisted `position`. Cleared on exit,
    /// so the underlying canvas layout is never touched.
    @Published var colorformPositions: [UUID: CGPoint] = [:]
    /// Bulbs rendered by `ColorformLayer`. Sized to enclose their cluster.
    @Published var colorBulbs: [ColorBulb] = []
    /// True while `enterColorform()` is fetching colors (so the UI can
    /// show a subtle activity indicator if it wants to).
    @Published var isComputingColorform: Bool = false
    /// Camera snapshot taken at the moment we entered Colorform, so we
    /// can restore the user's exact viewport on exit. Per-page (Colorform
    /// is page-scoped).
    var preColorformCamera: Camera? = nil

    /// Last *view* mode (Archive — never Colorform, which is too expensive
    /// to recompute on cold launch). Restored after the snapshot loads so
    /// the user re-opens in the view they left in. Persisted (UserDefaults).
    @Published var lastViewMode: CanvasMode? = nil

    // MARK: - Archive mode state

    /// Sub-level within Archive: Calendar → (drill) → Day → (drill) → Card.
    @Published var archiveLevel: ArchiveLevel = .calendar
    /// Local-time day → ids of nodes added that day. Computed lazily
    /// when needed (on enter + when `nodes` mutates while in Archive).
    @Published var archiveDays: [Date: [UUID]] = [:]
    /// Reverse of `archiveDays`: node id → the day it lives in. Used by
    /// `popArchiveLevel`, `lightboxNavigate`, and the breadcrumb so
    /// they can look up the parent day in O(1) instead of walking the
    /// archiveDays dictionary on every navigation event.
    var cardToDay: [UUID: Date] = [:]
    /// Per-card position override active in the Bento level. Keyed by
    /// node id; populated by `bentoLayout`. Cleared on level pop.
    @Published var archivePositions: [UUID: CGPoint] = [:]
    /// Per-card size override active in the Bento level. Same lifecycle
    /// as `archivePositions`.
    @Published var archiveSizes: [UUID: CGSize] = [:]
    /// Camera snapshot taken on entry so `exitArchive` can restore the
    /// user's exact viewport from the canvas they left.
    var preArchiveCamera: Camera? = nil

    /// Whether the left pages sidebar is shown (toggled by the floating
    /// sidebar-toggle button, Figma 74:25877 open / 74:13420 closed).
    @Published var showSidebar: Bool = true
    /// Whether the connectors layer is rendered. Toggled from the
    /// bottom-right floating control bar.
    @Published var showConnectors: Bool = true
    /// Whether the dot grid is rendered.
    @Published var showGrid: Bool = true
    /// When true, every video-bearing card (local video, video tweets,
    /// Instagram) is forced to its static preview frame and its player
    /// torn down. Toggled from the bottom-right floating control bar.
    @Published var videosShowPreviewOnly: Bool = false

    /// id of a freshly placed editable node (text or sticky) that should
    /// auto-focus its editor on appear. Cleared once consumed.
    @Published var pendingFocusNodeID: UUID? = nil

    /// id of the text node currently in inline edit. While set, that one card's
    /// hosted content stays hit-testable so its TextField receives keys/caret
    /// clicks; the canvas input layer (CanvasInputView) steps aside for it.
    @Published var editingTextNodeID: UUID? = nil

    /// ids of freshly added image nodes that should play the wavefront
    /// reveal once when they appear. Cleared by the node view once consumed.
    @Published var pendingRevealNodeIDs: Set<UUID> = []

    /// In-flight drag-to-connect (live preview line).
    @Published var pendingConnector: PendingConnector? = nil

    /// id of the node currently being dragged (representative node of
    /// a multi-drag, set when the gesture begins). Lets every other
    /// node react — connected nodes tug toward it, future polish can
    /// add focus dimming / shadow casting. Nil when no drag in flight.
    @Published var activeDragID: UUID? = nil
    /// Set of node ids connected to `activeDragID` via a connector.
    /// Recomputed when `activeDragID` is set so per-card tug math is
    /// O(1) instead of scanning every connector per render.
    @Published var activeDragConnectedIDs: Set<UUID> = []

    /// Cached rendered heights, keyed by node id, reported by the node views.
    /// Used so connectors can hit the correct edge of an auto-sized card.
    @Published var measuredHeights: [UUID: CGFloat] = [:]
    /// Staging for height-probe reports. `reportMeasuredHeight` is called
    /// from inside a SwiftUI layout pass (a GeometryReader background);
    /// writing the @Published `measuredHeights` there *synchronously* can
    /// re-enter layout and, on macOS 26/27, trip AppKit's recursion trap
    /// (EXC_BREAKPOINT in `_layoutSubtreeWithOldSize` — seen when exiting
    /// Archive/Colorform, where many auto-height cards re-measure at once
    /// during the transition). Reports are buffered and flushed once on the
    /// next main-actor turn, outside the current layout pass.
    var pendingHeights: [UUID: CGFloat] = [:]
    var heightFlushScheduled = false

    @Published var isAddSheetPresented = false
    /// The inline "Insert link here" field above the toolbar "+" (Figma
    /// 72:36784). Toggled by the candy "+" button; drives its green selected
    /// skin. The richer Link / From-Computer sheet stays on ⌘N.
    @Published var isLinkInputPresented = false
    @Published var isSearchPresented = false

    /// Which sidebar tab is showing: the page list or the flat Outline of
    /// every card across pages.
    enum SidebarTab: Hashable { case pages, outline }
    @Published var sidebarTab: SidebarTab = .pages
    @Published var alert: AlertContent? = nil

    // Figma-equivalent range: ~2% to 1600%. Lets you frame a large board
    // at a glance (2%) and inspect pixel-level detail (1600%).
    static let minZoom: CGFloat = 0.02
    static let maxZoom: CGFloat = 16.0

    struct AlertContent: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    // MARK: - iPhone share inbox

    static let incomingPageName = "from my iPhone"
    /// Earlier names this page shipped under — migrated to `incomingPageName`
    /// on load so existing documents pick up the rename + pin.
    static let legacyIncomingPageNames: Set<String> = ["📥 Incoming", "Incoming"]

    /// True when the iPhone inbox page is the active page and still has no
    /// cards — drives the "Send references from your iPhone" empty state.
    var isInboxEmpty: Bool {
        activePage.name == Self.incomingPageName && activePage.nodes.isEmpty
    }
    /// Presents the "set up iPhone sharing" how-to guide sheet.
    @Published var isInboxGuidePresented = false
    private static let k_inboxBookmark = "share.inboxFolderBookmark"

    /// Point the inbox at an iCloud Drive folder (chosen via the folder
    /// picker). Persisted as a bookmark so it survives relaunches.
    func setSharedInboxFolder(_ url: URL) {
        if let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: Self.k_inboxBookmark)
        }
        sharedInboxFolderURL = url
        sharedInbox.start(folderURL: url)
    }

    /// Resolve a previously-chosen inbox folder on launch and start watching.
    private func restoreSharedInboxFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.k_inboxBookmark) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 bookmarkDataIsStale: &stale) else { return }
        sharedInboxFolderURL = url
        sharedInbox.start(folderURL: url)
    }

    /// Sweep the inbox folder once — call on app foreground / launch so
    /// links that arrived while the app was closed get drained.
    func sweepSharedInbox() { sharedInbox.sweepNow() }

    /// Ingest one shared URL from the phone as a card on the "Incoming"
    /// page, badged `.phone`. Unsupported URLs are silently ignored.
    func ingestSharedURL(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardWidth: CGFloat = 360
        var made: CanvasNode?
        if TweetService.isLikelyTweetURL(trimmed), TweetService.extractTweetID(from: trimmed) != nil {
            made = CanvasNode.tweet(url: trimmed, position: .zero, width: cardWidth)
        } else if InstagramService.isLikelyInstagramURL(trimmed), InstagramService.parse(trimmed) != nil {
            made = CanvasNode.instagram(url: trimmed, position: .zero, width: cardWidth,
                                        height: InstagramService.defaultCardHeight(for: trimmed))
        } else if YouTubeService.isLikelyYouTubeURL(trimmed), YouTubeService.videoID(from: trimmed) != nil {
            made = CanvasNode(position: .zero, width: cardWidth,
                              height: YouTubeService.defaultCardHeight(forWidth: cardWidth),
                              kind: .youtube(url: trimmed))
        } else if let u = URL(string: trimmed),
                  let scheme = u.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" {
            // Any other shared link lands as a web-clip card.
            made = CanvasNode.webclip(url: trimmed, position: .zero, width: cardWidth, height: 320)
        }
        guard var node = made else { return }
        node.origin = .phone

        let idx = ensureIncomingPageIndex()
        let slot = pages[idx].nodes.count
        node.position = Self.inboxTilePosition(slot: slot, cardWidth: cardWidth)
        pages[idx].nodes.append(node)
        // Keep the live node index in sync if Incoming is the active page.
        if pages[idx].id == activePageID { nodeByID[node.id] = node }

        let label: String
        switch node.kind {
        case .youtube:   label = "Added a YouTube link from iPhone"
        case .tweet:     label = "Added an X post from iPhone"
        case .instagram: label = "Added an Instagram post from iPhone"
        default:         label = "Added a link from iPhone"
        }
        showToast(label, systemImage: "iphone")
    }

    /// Show a transient toast that auto-dismisses after a few seconds.
    /// A new toast cancels the previous one's dismissal timer.
    func showToast(_ text: String, systemImage: String) {
        toastDismissWork?.cancel()
        withAnimation(.spring(response: 0.40, dampingFraction: 0.82)) {
            toast = ToastContent(text: text, systemImage: systemImage)
        }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: work)
    }

    /// Jump to the Incoming page (from the share toast). No-op if it doesn't
    /// exist yet.
    func goToIncomingPage() {
        toastDismissWork?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = nil }
        if let p = pages.first(where: { $0.name == Self.incomingPageName }) {
            switchTo(pageID: p.id)
        }
    }

    private func ensureIncomingPageIndex() -> Int {
        if let i = pages.firstIndex(where: { $0.name == Self.incomingPageName }) { return i }
        // Create the iPhone inbox pinned so it sits at the top of the sidebar.
        pages.insert(Page(name: Self.incomingPageName, pinned: true), at: 0)
        return 0
    }

    /// One-time migration: an inbox page created under an older name gets
    /// renamed to `incomingPageName`, pinned, and floated to the top. Static
    /// so it can run during `init` before `self` is fully formed.
    private static func migrateIncomingPage(in pages: inout [Page]) {
        if let i = pages.firstIndex(where: { legacyIncomingPageNames.contains($0.name) }) {
            pages[i].name = incomingPageName
            pages[i].pinned = true
        }
        pages = pinnedFirst(pages)
    }

    /// Stable order that floats pinned pages to the top while preserving the
    /// relative order within each group.
    private static func pinnedFirst(_ pages: [Page]) -> [Page] {
        pages.enumerated().sorted { a, b in
            if a.element.pinned != b.element.pinned { return a.element.pinned }
            return a.offset < b.offset
        }.map { $0.element }
    }

    /// Re-float pinned pages to the top (after a pin toggle or rename).
    func sortPagesByPinned() {
        let ordered = Self.pinnedFirst(pages)
        if !ordered.elementsEqual(pages, by: { $0.id == $1.id }) { pages = ordered }
    }

    /// Toggle a page's pinned state and re-float. The active page is tracked
    /// by id, so reordering never loses the user's place.
    func togglePin(_ id: UUID) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[i].pinned.toggle()
        sortPagesByPinned()
    }

    /// Drag-reorder: move `dragged` to just before `target` in the page list,
    /// then keep pinned pages grouped on top (stable sort preserves the new order
    /// within each group).
    func movePage(_ dragged: UUID, before target: UUID) {
        guard dragged != target,
              let from = pages.firstIndex(where: { $0.id == dragged }) else { return }
        let page = pages.remove(at: from)
        let idx = pages.firstIndex(where: { $0.id == target }) ?? pages.count
        pages.insert(page, at: idx)
        sortPagesByPinned()
    }

    /// Simple 3-column grid so a burst of shares doesn't pile on one spot.
    private static func inboxTilePosition(slot: Int, cardWidth: CGFloat) -> CGPoint {
        let columns = 3
        let gap: CGFloat = 32
        let col = slot % columns
        let row = slot / columns
        return CGPoint(x: 80 + CGFloat(col) * (cardWidth + gap),
                       y: 80 + CGFloat(row) * (420 + gap))
    }

    // MARK: - Keyboard card navigation (N / ⇧N) + open source

    /// Select and frame the next (or previous) card, Figma-style. Cards are
    /// visited in spatial reading order — top-to-bottom, then left-to-right
    /// — and the camera animates to frame each via `zoomToSelection`. Wraps
    /// around at the ends. Sections are skipped (they're containers, not
    /// cards). Canvas-mode only.
    func selectNextNode(reverse: Bool = false) {
        guard canvasMode == .canvas else { return }
        let ordered = activePage.nodes
            .filter { !$0.isSection }
            .sorted { a, b in
                if abs(a.position.y - b.position.y) > 1 { return a.position.y < b.position.y }
                return a.position.x < b.position.x
            }
        guard !ordered.isEmpty else { return }

        let currentID = selectedNodeIDs.count == 1 ? selectedNodeIDs.first : nil
        let currentIdx = currentID.flatMap { id in ordered.firstIndex(where: { $0.id == id }) }
        let nextIdx: Int
        if let i = currentIdx {
            nextIdx = reverse ? (i - 1 + ordered.count) % ordered.count
                              : (i + 1) % ordered.count
        } else {
            nextIdx = reverse ? ordered.count - 1 : 0
        }
        select(ordered[nextIdx].id)
        zoomToSelection()
    }

    /// Open the source URL(s) of the selected card(s) — tweet / Instagram /
    /// YouTube — in the default browser. Toasts if the selection has no link.
    func openSelectedSource() {
        let urls: [URL] = selectedNodeIDs.compactMap { id -> URL? in
            guard let node = nodeByID[id] else { return nil }
            let s: String?
            switch node.kind {
            case .tweet(let u), .instagram(let u), .youtube(let u): s = u
            default: s = nil
            }
            return s.flatMap { URL(string: $0) }
        }
        guard !urls.isEmpty else {
            showToast("No source link on the selected card", systemImage: "link.slash")
            return
        }
        for url in urls.prefix(12) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Card lightbox (double-click theater view + details inspector)

    /// Set for the WHOLE lightbox session — from open, through the close
    /// animation, until it fully finishes. The on-canvas card hides exactly
    /// while this == its id, so the source is hidden the entire time the hero
    /// is on screen (Apple Photos: the thumbnail reappears only when the
    /// dismiss completes — never a duplicate mid-flight).
    @Published var lightboxCardID: UUID?

    /// True while the lightbox is animating CLOSED (still mounted). The view
    /// watches this to run the shrink, then calls `finalizeLightboxClose`.
    @Published var lightboxClosing = false

    /// The video card currently in inline trim mode (exclusive). While set,
    /// `DraggableNode` suppresses that card's drag so the timeline handles can
    /// be dragged without moving the card.
    @Published var trimmingCardID: UUID?

    /// Resolved direct-MP4 URL per node, populated by the cards (local `.video`
    /// = its file URL; tweet/web = the async-resolved stream). The TOP-LEVEL trim
    /// widget (mounted in `CanvasView`, above the input layer so it's actually
    /// clickable) reads this so it can open below the card without re-resolving.
    @Published var trimVideoURLs: [UUID: URL] = [:]

    /// The on-screen (window-global) rect of the card the lightbox was opened
    /// from — origin/destination of the grow/shrink. matchedGeometryEffect
    /// can't animate across the split-view→overlay boundary here, so we measure
    /// the rect ourselves and drive an explicit transform. Plain stored values
    /// (read during layout, not observed) so they never trigger re-renders.
    var lightboxSourceRect: CGRect?
    /// Window-global frame of the canvas camera container (the ZStack the
    /// camera offset is relative to); written by `CanvasView`.
    var canvasViewFrame: CGRect = .zero

    /// Window-global rect of a node as it currently appears on the canvas,
    /// accounting for the live camera (pan + zoom).
    func screenRect(of node: CanvasNode) -> CGRect? {
        guard canvasViewFrame != .zero else { return nil }
        let z = camera.zoom
        let p = effectivePosition(of: node)
        return CGRect(x: canvasViewFrame.minX + p.x * z + camera.x,
                      y: canvasViewFrame.minY + p.y * z + camera.y,
                      width: node.width * z,
                      height: renderedHeight(of: node) * z)
    }

    /// Single spring the view uses to drive the grow/shrink progress. Smooth,
    /// barely-damped (Photos-like, minimal bounce). Quick fade under Reduce
    /// Motion. `lightboxCloseDuration` must cover its visual settle.
    private var lightboxReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    var lightboxHeroAnimation: Animation {
        lightboxReduceMotion ? .easeOut(duration: 0.16)
                             : .spring(response: 0.40, dampingFraction: 0.9)
    }
    /// How long to keep the layer mounted after a close is requested, before
    /// finalizing (≈ the spring's visual settle). Kept short under Reduce Motion.
    var lightboxCloseDuration: TimeInterval { lightboxReduceMotion ? 0.18 : 0.5 }

    /// Active-page cards in spatial reading order — drives lightbox ← →
    /// navigation and the "i / N" counter. Sections are excluded.
    var lightboxOrder: [UUID] {
        activePage.nodes
            .filter { !$0.isSection }
            .sorted { a, b in
                if abs(a.position.y - b.position.y) > 1 { return a.position.y < b.position.y }
                return a.position.x < b.position.x
            }
            .map(\.id)
    }

    /// Bumped on every open so the hero view re-drives its grow animation
    /// even when the layer never unmounted — reopening during the closing
    /// shrink used to leave the hero with stale progress/landed state
    /// (and on macOS 27 the re-entrant hero could trip AppKit's
    /// layout-recursion trap).
    @Published private(set) var lightboxGeneration = 0

    func openLightbox(_ id: UUID) {
        guard let node = nodeByID[id] else { return }
        // The hero grows out of the card's measured on-screen rect — stop
        // any camera coast/glide so the measurement (and the later shrink
        // target) stays truthful while the hero animates.
        cancelPanInertia()
        // Measure the card's on-screen rect now; the hero grows out of it.
        // The grow itself is animated by the view (progress 0→1).
        lightboxSourceRect = screenRect(of: node)
        lightboxClosing = false
        lightboxCardID = id
        lightboxGeneration &+= 1
    }

    /// Begin the close. The card stays mounted (and the on-canvas original
    /// stays hidden) while the view shrinks it; `finalizeLightboxClose` then
    /// unmounts it — so the original reappears exactly as the hero vanishes.
    func closeLightbox() {
        guard lightboxCardID != nil, !lightboxClosing else { return }
        lightboxClosing = true
    }

    /// Called by the view once the shrink animation has run its course.
    func finalizeLightboxClose() {
        guard lightboxClosing else { return }   // a reopen during close cancels it
        lightboxCardID = nil
        lightboxClosing = false
    }

    /// Step prev (-1) / next (+1) through `lightboxOrder`, wrapping around.
    func lightboxStep(_ delta: Int) {
        let order = lightboxOrder
        guard !order.isEmpty, let cur = lightboxCardID,
              let i = order.firstIndex(of: cur) else { return }
        let n = order.count
        lightboxCardID = order[((i + delta) % n + n) % n]
    }

    /// 1-based index + total for the lightbox counter ("2 / 7").
    var lightboxPosition: (index: Int, total: Int)? {
        let order = lightboxOrder
        guard let cur = lightboxCardID, let i = order.firstIndex(of: cur) else { return nil }
        return (i + 1, order.count)
    }

    // Inspector field edits — mutate the node in place; `$pages` autosaves.
    func setNodeName(_ id: UUID, _ value: String) {
        updateNode(id) { $0.name = value.isEmpty ? nil : value }
    }
    func setNodeNote(_ id: UUID, _ value: String) {
        updateNode(id) { $0.note = value.isEmpty ? nil : value }
    }
    func setNodeLinkURL(_ id: UUID, _ value: String) {
        updateNode(id) { $0.linkURL = value.isEmpty ? nil : value }
    }

    // MARK: - Video trim (non-destructive)

    /// Set the loop range (seconds) for a video card; the player loops only
    /// `[start, end]`. Autosaves via `$pages`. Undoable — ⌘Z restores the
    /// previous range like every other card mutation.
    func setTrim(_ id: UUID, start: Double, end: Double) {
        withUndoable {
            updateNode(id) { $0.trimStart = start; $0.trimEnd = end }
        }
    }
    /// Clear the trim — the card loops the full clip again. Undoable.
    func clearTrim(_ id: UUID) {
        withUndoable {
            updateNode(id) { $0.trimStart = nil; $0.trimEnd = nil }
        }
    }

    private func updateNode(_ id: UUID, _ mutate: (inout CanvasNode) -> Void) {
        guard let idx = activePage.nodes.firstIndex(where: { $0.id == id }) else { return }
        var n = activePage.nodes[idx]
        mutate(&n)
        pages[activePageIndex].nodes[idx] = n
        nodeByID[id] = n
    }

    // MARK: - Lightbox inspector: source URL, page, tags, prompt

    /// Effective source link for a node — the embedded post URL, or the
    /// manually-entered `linkURL`.
    func sourceURL(of node: CanvasNode) -> String? {
        switch node.kind {
        case .tweet(let u), .instagram(let u), .youtube(let u): return u
        default: return node.linkURL
        }
    }

    /// Name of the page that contains this card (cards live on one page).
    func pageName(forCard id: UUID) -> String? {
        pages.first(where: { $0.nodes.contains(where: { $0.id == id }) })?.name
    }

    func setNodeImagePrompt(_ id: UUID, _ value: String) {
        updateNode(id) { $0.imagePrompt = value.isEmpty ? nil : value }
    }

    func addTag(_ id: UUID, _ raw: String) {
        let t = Self.normalizeTag(raw)
        guard !t.isEmpty else { return }
        updateNode(id) { if !$0.tags.contains(t) { $0.tags.append(t) } }
    }

    func removeTag(_ id: UUID, _ tag: String) {
        updateNode(id) { $0.tags.removeAll { $0 == tag } }
    }

    /// Heuristic auto-tagger (no AI): derives tags from kind, source
    /// domain, dominant color, and aspect; dedup-merges into `node.tags`.
    func autoTag(_ id: UUID) {
        guard let node = nodeByID[id] else { return }
        var derived: [String] = []
        switch node.kind {
        case .image:      derived.append("image")
        case .video:      derived.append("video")
        case .tweet:      derived += ["tweet", "x"]
        case .instagram:  derived.append("instagram")
        case .youtube:    derived += ["youtube", "video"]
        case .webclip:    derived += ["web", "link"]
        case .text:       derived.append("text")
        case .stickyNote: derived.append("note")
        case .drawing:    derived.append("drawing")
        case .section:    break
        case .folder:     derived.append("folder")
        }
        if let host = sourceURL(of: node).flatMap({ URL(string: $0)?.host })?
            .replacingOccurrences(of: "www.", with: ""),
           !["x.com", "twitter.com", "youtube.com", "youtu.be", "instagram.com"].contains(host) {
            derived.append(String(host.split(separator: ".").first ?? Substring(host)))
        }
        if case .image = node.kind,
           let c = PaletteExtractor.colors(for: node, count: 4).first {
            derived.append(PaletteExtractor.colorName(c))
        }
        let h = renderedHeight(of: node)
        if node.width > 1, h > 1 {
            let r = node.width / h
            derived.append(r > 1.2 ? "landscape" : (r < 0.83 ? "portrait" : "square"))
        }
        updateNode(id) { n in
            for t in derived.map(Self.normalizeTag) where !t.isEmpty && !n.tags.contains(t) {
                n.tags.append(t)
            }
        }
    }

    private static func normalizeTag(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Heuristic image-prompt synthesis (no AI) from kind + colors +
    /// orientation + source/name/text.
    func generatePrompt(for node: CanvasNode) -> String {
        let aspect: String = {
            let h = renderedHeight(of: node)
            guard node.width > 1, h > 1 else { return "square" }
            let r = node.width / h
            return r > 1.2 ? "landscape" : (r < 0.83 ? "portrait" : "square")
        }()
        switch node.kind {
        case .image:
            let names = uniqueOrdered(PaletteExtractor.colors(for: node, count: 4)
                                        .map(PaletteExtractor.colorName))
            let palette = names.isEmpty ? "" : " in \(listPhrase(names)) tones"
            let subject = (node.name?.isEmpty == false) ? node.name! : "an abstract composition"
            return "A \(aspect) image of \(subject)\(palette), high detail, soft natural light."
        case .tweet(let u):
            let handle = URL(string: u)?.path.split(separator: "/").first
                .map { "@\($0)" } ?? "a user"
            return "Screenshot of an X post by \(handle), clean UI, crisp legible typography."
        case .instagram:
            return "An Instagram post, square crop, vibrant social-media aesthetic."
        case .youtube:
            return "A YouTube thumbnail, bold focal subject, high contrast, punchy color."
        case .webclip:
            return "A web page screenshot, clean readable layout, informative content."
        case .video:
            return "A \(aspect) video still, cinematic lighting, gentle natural motion."
        case .text(let content, _):
            return "Editorial typographic layout featuring: \u{201C}\(content.prefix(60))\u{201D}."
        case .stickyNote(let content, _):
            return "A handwritten sticky note reading: \u{201C}\(content.prefix(60))\u{201D}."
        case .drawing:
            return "A loose freehand ink sketch, minimal expressive line art."
        case .section:
            return "A labeled grouping frame."
        case .folder:
            return "A folder holding a set of saved items."
        }
    }

    private func uniqueOrdered(_ arr: [String]) -> [String] {
        var seen = Set<String>(); return arr.filter { seen.insert($0).inserted }
    }
    private func listPhrase(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }

    // MARK: - Folder contents & focus

    /// Every node id currently tucked inside some folder — hidden from the main
    /// canvas, shown only when that folder is unfolded.
    var allFolderChildIDs: Set<UUID> {
        var ids = Set<UUID>()
        for n in nodes {
            if case .folder(_, _, let childIDs) = n.kind { ids.formUnion(childIDs) }
        }
        return ids
    }

    /// The folder node that contains `nodeID`, if any.
    func folderContaining(_ nodeID: UUID) -> UUID? {
        for n in nodes {
            if case .folder(_, _, let childIDs) = n.kind, childIDs.contains(nodeID) { return n.id }
        }
        return nil
    }

    /// Nodes the canvas should render: a folder's children while it's unfolded,
    /// otherwise every node NOT tucked inside a folder. Drives the native canvas
    /// so folder children truly disappear from the main board until opened.
    var canvasDisplayNodes: [CanvasNode] {
        let base: [CanvasNode]
        if let fid = focusedFolderID,
           case .folder(_, _, let childIDs)? = nodeByID[fid]?.kind {
            let set = Set(childIDs)
            base = nodes.filter { set.contains($0.id) }
        } else {
            let hidden = allFolderChildIDs
            base = hidden.isEmpty ? nodes : nodes.filter { !hidden.contains($0.id) }
        }
        // Colorform re-lays the cards into colour clusters (each cluster's cards
        // sit on a grid centred on its bulb), so zooming into a colour lands on
        // its cards. The native canvas positions by `node.position`, so swap in
        // the computed colorform position here. Non-destructive (the model
        // positions are untouched; restored on exit).
        guard canvasMode == .colorform, !colorformPositions.isEmpty else { return base }
        return base.map { node in
            guard let p = colorformPositions[node.id] else { return node }
            var n = node
            n.position = p
            return n
        }
    }

    /// Open a folder → the SOLID-BG GRID view (FolderGridView) takes over; the
    /// canvas camera is left untouched (the grid overlay covers it), so closing
    /// returns to exactly where the board was.
    func enterFolderFocus(folderID: UUID) {
        guard case .folder = nodeByID[folderID]?.kind else { return }
        cancelPanInertia()
        deselectAll()
        withAnimation(.easeInOut(duration: 0.2)) { focusedFolderID = folderID }
        Haptics.tap()
    }

    /// Close the folder grid → back to the board (camera unchanged).
    func exitFolderFocus() {
        guard focusedFolderID != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) { focusedFolderID = nil }
    }

    /// Drop cards INTO a folder: add them to its `childIDs` so they leave the
    /// main canvas. Skips the folder itself and cards already inside a folder.
    func addToFolder(_ folderID: UUID, nodeIDs: Set<UUID>) {
        guard case .folder(let title, let icon, let existing)? = nodeByID[folderID]?.kind else { return }
        let toAdd = nodeIDs.filter { $0 != folderID && folderContaining($0) == nil }
        guard !toAdd.isEmpty else { return }
        withUndoable {
            guard let idx = nodes.firstIndex(where: { $0.id == folderID }) else { return }
            nodes[idx].kind = .folder(title: title, icon: icon, childIDs: existing + Array(toAdd))
        }
        selectedNodeIDs.subtract(toAdd)
        Haptics.tap()
    }

    /// After a drag, if the dragged cards landed on a folder, tuck them in. Uses
    /// the primary dragged card's centre to pick the folder; ignores dragged
    /// folders and drops made while a folder is already unfolded.
    func handleDropOntoFolder(draggedIDs: Set<UUID>) {
        guard focusedFolderID == nil, !draggedIDs.isEmpty else { return }
        let cards = draggedIDs.filter { id in
            if case .folder = nodeByID[id]?.kind { return false }
            return true
        }
        // The dragged cards' bounding rect (positions already committed by onMove).
        guard !cards.isEmpty, let dragRect = boundingRect(of: Set(cards)) else { return }
        // File into the folder the cards overlap MOST. Center-in-frame missed big
        // cards (taller than the 223 px folder, their center sits off it), so use
        // overlap area with a meaningful threshold (≥25% of the folder) — covering
        // the folder files it; merely brushing past it does not.
        var best: (id: UUID, area: CGFloat)?
        let dragArea = max(dragRect.width * dragRect.height, 1)
        for f in nodes {
            guard case .folder = f.kind, !draggedIDs.contains(f.id) else { continue }
            let fr = CGRect(x: f.position.x, y: f.position.y,
                            width: f.width, height: renderedHeight(of: f))
            let inter = fr.intersection(dragRect)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            // Require the overlap to be ≥25% of the SMALLER of the folder / dragged
            // cards — so a small card files into a large folder (and vice-versa).
            // (The old "25% of the folder" rule meant a normal card could never
            // cover enough of an over-sized folder, so filing silently failed.)
            let threshold = min(fr.width * fr.height, dragArea) * 0.25
            guard area >= threshold else { continue }
            if area > (best?.area ?? 0) { best = (f.id, area) }
        }
        if let best { addToFolder(best.id, nodeIDs: Set(cards)) }
    }

    // MARK: - Sections

    /// Create a section frame covering the given world rect. Returns its
    /// id so callers can put the title field straight into edit mode.
    ///
    /// Sections always render below cards (enforced by `CanvasView`'s
    /// sections-first / cards-second render pass). Within the section
    /// sub-array, normal array order = z-order, so appending puts the
    /// new section on top of older sections — matching Figma's "newest
    /// frame on top" convention.
    @discardableResult
    func addSection(rect: CGRect, title: String = "", color: SectionColor = .slate) -> UUID {
        let node = CanvasNode.section(title: title, color: color, rect: rect)
        withUndoable { nodes.append(node) }
        select(node.id)
        toolMode = .select
        return node.id
    }

    // MARK: - Camera

    func zoomIn()    { glideCamera(to: cameraZooming(by: 1.25, around: viewportCentre)) }
    func zoomOut()   { glideCamera(to: cameraZooming(by: 1 / 1.25, around: viewportCentre)) }
    func resetView() { glideCamera(to: Camera()) }

    /// Pure target computation for a zoom step about a screen anchor —
    /// shared by the instant (pinch) and gliding (buttons/⌘±) paths.
    private func cameraZooming(by factor: CGFloat, around screenPoint: CGPoint) -> Camera {
        let oldZoom = camera.zoom
        let newZoom = max(Self.minZoom, min(Self.maxZoom, oldZoom * factor))
        guard newZoom != oldZoom else { return camera }
        let worldX = (screenPoint.x - camera.x) / oldZoom
        let worldY = (screenPoint.y - camera.y) / oldZoom
        return Camera(
            x: screenPoint.x - worldX * newZoom,
            y: screenPoint.y - worldY * newZoom,
            zoom: newZoom
        )
    }

    func zoom(by factor: CGFloat, around screenPoint: CGPoint) {
        // Direct gesture — it owns the camera now; kill any glide.
        cancelCameraGlide()
        camera = cameraZooming(by: factor, around: screenPoint)
    }

    func pan(deltaX: CGFloat, deltaY: CGFloat) {
        camera.x += deltaX
        camera.y += deltaY
    }

    // MARK: - Camera glide (continuous navigation)
    //
    // Discrete navigation moves (zoom buttons, ⌘0/fit, minimap jumps)
    // animate the camera VALUE with a spring driver instead of snapping —
    // so every observer (node layer, dot grid, minimap, zoom dial) moves
    // in lockstep. Retargeting mid-flight keeps the current velocity
    // (pressing ⌘+ repeatedly chains into one continuous accelerating
    // move), and any direct gesture cancels the glide and takes over —
    // motion never blocks input.

    private var cameraGlideTimer: Timer?
    private var glideTarget: Camera?
    private var glideVelocity: (x: CGFloat, y: CGFloat, zoom: CGFloat) = (0, 0, 0)

    func glideCamera(to target: Camera) {
        // macOS 26/27 beta (26A5353q): the 60 Hz Timer this method used to
        // schedule mutated the @Published `camera` every tick, and that
        // per-tick write re-entered AppKit's constraint-based layout until
        // it tripped the depth-16 recursion guard (EXC_BREAKPOINT in
        // -[NSView _layoutSubtreeWithOldSize:]). Any continuous camera
        // animation is therefore unsafe on this OS, so navigation jumps
        // straight to the target — exactly the pre-motion-system behavior
        // (and what Reduce Motion already did). No autonomous layout loop.
        cancelPanInertia()
        camera = target
    }

    func cancelCameraGlide() {
        cameraGlideTimer?.invalidate()
        cameraGlideTimer = nil
        glideTarget = nil
        glideVelocity = (0, 0, 0)
    }

    // MARK: - Pan-with-inertia (trackpad / mouse-wheel scroll)

    /// Ring buffer of recent (delta, timestamp) tuples used to derive
    /// scroll velocity at end-of-gesture. Entries older than ~100 ms
    /// are pruned on every push so velocity reflects the last burst
    /// of motion, not the whole pan.
    private var recentPanDeltas: [(delta: CGPoint, at: Date)] = []
    private var panIdleTimer: Timer?
    private var panInertiaTimer: Timer?

    /// Apply a pan delta and track velocity for end-of-gesture
    /// inertia. After ~80 ms of no further `panWithInertia` calls (the
    /// user has stopped scrolling, or macOS's natural trackpad
    /// momentum has finished), we synthesise a soft decay so the
    /// camera coasts to a stop instead of stopping dead. For trackpad
    /// momentum (events arrive at ~60 Hz), the idle timer never trips
    /// until momentum is done — so we don't double-apply.
    func panWithInertia(deltaX: CGFloat, deltaY: CGFloat) {
        cancelPanInertia()
        // Apply immediately — the inertia only kicks in *after* idle.
        pan(deltaX: deltaX, deltaY: deltaY)
        // Record + prune.
        let now = Date()
        recentPanDeltas.append((CGPoint(x: deltaX, y: deltaY), now))
        let cutoff = now.addingTimeInterval(-0.10)
        recentPanDeltas.removeAll { $0.at < cutoff }
        // Re-arm the idle timer.
        panIdleTimer?.invalidate()
        panIdleTimer = Timer.scheduledTimer(
            withTimeInterval: 0.08, repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.startPanInertiaIfNeeded() }
        }
    }

    /// Cancel ALL autonomous camera motion — inertia coasting and any
    /// navigation glide. Called whenever a new pan tick arrives or the
    /// user starts a different gesture (zoom, drag, mode switch): direct
    /// input always seizes the camera mid-flight.
    func cancelPanInertia() {
        cancelInertiaOnly()
        cancelCameraGlide()
    }

    /// Inertia/idle teardown without touching a glide — used by
    /// `glideCamera` itself, which replaces coasting but IS the glide.
    private func cancelInertiaOnly() {
        panIdleTimer?.invalidate()
        panIdleTimer = nil
        panInertiaTimer?.invalidate()
        panInertiaTimer = nil
    }

    /// Compute residual velocity from the last ~100 ms of pan deltas;
    /// if it's above a perceptible threshold, kick off a 60 Hz decay
    /// loop. The decay exponent (0.92 / tick) gives a ~250 ms tail-off
    /// — enough to feel inertial without overshooting the user's
    /// intent.
    private func startPanInertiaIfNeeded() {
        // Disabled on macOS 26/27 beta: the inertia decay ran a 60 Hz
        // Timer that mutated the @Published `camera` each tick, the same
        // continuous-layout driver that trips AppKit's depth-16 recursion
        // guard. Scrolling still pans directly (see `panWithInertia`);
        // only the autonomous coast after release is removed.
        if #available(macOS 26.0, *) {
            recentPanDeltas.removeAll(keepingCapacity: true)
            return
        }
        let deltas = recentPanDeltas
        recentPanDeltas.removeAll(keepingCapacity: true)
        guard !deltas.isEmpty else { return }
        // Velocity = average delta per tick over the buffer window.
        let total = deltas.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.delta.x, y: $0.y + $1.delta.y)
        }
        let count = CGFloat(deltas.count)
        var velocity = CGPoint(x: total.x / count, y: total.y / count)
        // Skip if too slow to bother — avoids "stalling" at end of a
        // deliberate slow drag.
        guard hypot(velocity.x, velocity.y) > 1.5 else { return }
        // Tune the kickoff so it feels like a continuation, not an
        // extra shove.
        velocity.x *= 1.6
        velocity.y *= 1.6
        // `.common` mode so the coast keeps ticking during `.eventTracking`
        // (a follow-on trackpad gesture) instead of stalling in `.default`.
        let inertiaTimer = Timer(
            timeInterval: 1.0 / 60.0, repeats: true
        ) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            velocity.x *= 0.92
            velocity.y *= 0.92
            if hypot(velocity.x, velocity.y) < 0.4 {
                timer.invalidate()
                Task { @MainActor in self.panInertiaTimer = nil }
                return
            }
            let vx = velocity.x, vy = velocity.y
            Task { @MainActor in self.pan(deltaX: vx, deltaY: vy) }
        }
        RunLoop.main.add(inertiaTimer, forMode: .common)
        panInertiaTimer = inertiaTimer
    }

    /// Frame all nodes within the viewport. If empty, just resets.
    func zoomToFit() {
        guard !nodes.isEmpty,
              let rect = boundingRect(of: Set(nodes.map(\.id))) else {
            resetView(); return
        }
        frameRect(rect, padding: 80)
    }

    /// Frame the bounding rect of the current selection; falls through to
    /// `zoomToFit` when nothing is selected so the keyboard shortcut never
    /// feels broken.
    func zoomToSelection() {
        guard !selectedNodeIDs.isEmpty,
              let rect = boundingRect(of: selectedNodeIDs) else {
            zoomToFit(); return
        }
        frameRect(rect, padding: 80)
    }

    /// Bounding rectangle of the given node ids in WORLD coordinates.
    /// Returns nil if no matching nodes exist on the active page.
    func boundingRect(of ids: Set<UUID>) -> CGRect? {
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        var found = false
        for n in nodes where ids.contains(n.id) {
            minX = min(minX, n.position.x)
            minY = min(minY, n.position.y)
            maxX = max(maxX, n.position.x + n.width)
            maxY = max(maxY, n.position.y + renderedHeight(of: n))
            found = true
        }
        guard found else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Cache backing `stableWorldBounds` — reset on page switch.
    private var cachedWorldBounds: CGRect?

    /// The scrollable canvas extent. Unlike the raw content bounding box this is
    /// GROWS-ONLY: it never shrinks or shifts while the content still fits inside
    /// it. That is what makes a *select-all* drag visibly move the cards — a
    /// content-following box would shift by the same delta as the nodes, leaving
    /// every node's position RELATIVE to the box unchanged (so nothing appears to
    /// move, even though the model positions did change). It expands only when a
    /// node is dragged/created outside the current margin.
    func stableWorldBounds() -> CGRect {
        let margin: CGFloat = 6000
        guard let content = boundingRect(of: Set(nodes.map(\.id))),
              content.width > 0, content.height > 0 else {
            return cachedWorldBounds ?? CGRect(x: -margin, y: -margin, width: 2 * margin, height: 2 * margin)
        }
        if let cached = cachedWorldBounds, cached.contains(content) { return cached }
        let next = (cachedWorldBounds ?? .null).union(content.insetBy(dx: -margin, dy: -margin))
        cachedWorldBounds = next
        return next
    }

    /// Drop the cached extent (call on page switch so a new page isn't anchored
    /// to the previous page's far-flung bounds).
    func resetWorldBoundsCache() { cachedWorldBounds = nil }

    /// Glide the camera to frame the given world rect with `padding`
    /// extra breathing room on each side. Capped to zoom 1.5× max so a
    /// single small card doesn't get magnified into a blur.
    func frameRect(_ rect: CGRect, padding: CGFloat) {
        let worldW = max(1, rect.width + padding * 2)
        let worldH = max(1, rect.height + padding * 2)
        let raw = min(viewportSize.width / worldW, viewportSize.height / worldH)
        let z = max(Self.minZoom, min(Self.maxZoom, min(raw, 1.5)))
        glideCamera(to: Camera(
            x: viewportSize.width / 2 - rect.midX * z,
            y: viewportSize.height / 2 - rect.midY * z,
            zoom: z
        ))
    }

    /// Glide the camera to an exact zoom value, recentred on the viewport
    /// centre so the user's eye doesn't lose its place.
    func setZoom(_ z: CGFloat) {
        let target = max(Self.minZoom, min(Self.maxZoom, z))
        guard camera.zoom > 0 else { camera.zoom = target; return }
        glideCamera(to: cameraZooming(by: target / camera.zoom, around: viewportCentre))
    }

    /// Glide the camera so the given world point sits at the viewport
    /// centre (current zoom). Click-drag in the minimap retargets this
    /// every tick — the glide's preserved velocity turns that into a
    /// smooth pursuit of the cursor.
    func centerCamera(on worldPoint: CGPoint) {
        glideCamera(to: Camera(
            x: viewportSize.width / 2 - worldPoint.x * camera.zoom,
            y: viewportSize.height / 2 - worldPoint.y * camera.zoom,
            zoom: camera.zoom
        ))
    }

}
