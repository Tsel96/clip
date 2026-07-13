# CLIP — Session Memory / Handoff

A continuity doc so work can resume after `/clear` or a fresh container.
CLIP is a native macOS SwiftUI infinite-canvas moodboard (`Sources/CLIP/`,
~108 files, single SwiftPM executable target, macOS 13+, **Apple Silicon**,
uses the macOS 26 Liquid Glass API so it needs the Xcode 26 / macOS 26 SDK
to build). `Tests/CLIPTests/` has a test target too.

**Working branch:** `claude/code-audit-performance-o0u336` (PR #2 was the
original perf pass; subsequent work continues on this branch).
**Build (the only working command):**
`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build`
— this dev env IS macOS and compiles locally; plain `swift build`/`swift run`
fails against the default Command Line Tools (no macOS 26 SDK). Bundle via
`CONFIG=release BUILD=<n> Scripts/make-app.sh` (DMG=1 ZIP=1) — currently
deployed build 9044. The GH Actions workflow (`.github/workflows/release.yml`,
`macos-26` runner) is a separate auto-release path triggered by every push
(throttled to once/4h) that publishes to GitHub Releases; it's been green and
shipping (through v1.0.489) as of this writing, but re-verify before relying
on it — it has gone billing-blocked before. Local `make-app.sh` is the path
to trust for the kiosk/exhibition build.

## Shipped & green (committed + pushed)
- **Perf audit pass** (merged via PR #2): off-main JSON autosave, corrupt-
  file backup, os.Logger, cached regexes + network timeouts + tweet retry,
  undo/redo + drag micro-opts, `CLIP · dev` window title for debug builds.
- **UX/HIG fixes:** page-deletion undo + confirm; persistent (non-hover)
  video controls; monospaced zoom digits; bigger Fitts targets; clearer
  connector/video-preview icons; active-tool chip; trim undoable; lenient
  URL routing; group/ungroup/delete toasts.
- **Archive redesign:** replaced calendar→bento→lightbox with a
  chronological **ArchiveListView** (day groups, timestamps, thumbnails,
  click-to-reveal). Old `ArchiveCalendarLayer/Breadcrumb/LightboxLayer`
  deleted; drill state in CanvasState left dormant.
- **Liquid-glass minimap** (`LiquidGlassMinimap.swift`): bottom-right glass
  dome, tick dial that rotates with zoom, inward needle, soft viewport
  indicator, zoom pill. Uses real `glassEffect` on macOS 26.
- **Fluid motion system** (`Motion.swift`): camera GLIDE engine in
  CanvasState (zoom buttons/fit/%/minimap/reveal animate the camera value
  via a 60Hz spring; interruptible — any gesture cancels; Reduce-Motion =
  instant). Named spring tokens.
- **Crash fixes (macOS 26/27 beta AppKit layout-recursion, EXC_BREAKPOINT
  in `_layoutSubtreeWithOldSize`):** (1) Archive pinned-material headers
  removed; (2) lightbox re-entrant hero on reopen (lightboxGeneration);
  (3) **height-probe**: `reportMeasuredHeight` now buffers into
  `pendingHeights` and flushes on the next main-actor turn so the
  measure→mutate→re-measure cycle can't recurse in one layout pass.
- **Search-all + Outline** (planned feature #1): ⌘K searches every page +
  name/note/tags with page badges and cross-page jump
  (`CanvasState.jumpToNode(_:onPage:)`); new Pages/Outline sidebar switcher
  (`OutlinePanel.swift`); shared helpers in `NodeSearch.swift`.

## Web Clips (planned feature #2) — SHIPPED
`.webclip(url)` Kind is a rendered card for any http(s) URL (replaces the old
"unsupported URL" alert; arbitrary iPhone-shared links also land). All the
exhaustive `switch node.kind` sites (`StackVisualView`, `StackFocusEngine`,
`ArchiveListView`, etc.) have `.webclip` arms, and `WebClipCardView.swift` /
`WebClipSnapshotStore.swift` exist and compile. No longer WIP.

## Not started (planned features #3, #4)
- **Notes + Markdown export** — new `.note(markdown:)` Kind; block-level
  Markdown render (AttributedString full syntax, per-block) + raw TextEditor;
  `Export Note…`/`Export All Notes…` via NSSavePanel. Same ~13-switch sweep
  as Web Clips.
- **Quick-capture hotkey** — global ⌥Space (Carbon `RegisterEventHotKey`,
  no Accessibility perm) → floating `.nonactivatingPanel` → routes to the
  pinned inbox page; Settings scene (⌘,) to toggle/rebind. Highest platform
  risk; build last.

Full design lives in the plan file:
`/root/.claude/plans/audit-code-to-make-dynamic-clarke.md` (not in repo).

## Architecture notes (reuse these)
- `CanvasNode.Kind` is a **manually-Codable enum** with a `type` string
  discriminator (`Models.swift` ~570). New cases are additive/migration-safe
  (old saves never contain them). EVERY exhaustive `switch node.kind` must
  get the new arm — there is no `default` in most.
- Web cards: clone `InstagramCardView.swift` (semantic-zoom `isLive` gate;
  shared WKProcessPool; poster fallback).
- Page-targeted append precedent: `ingestSharedURL` + `ensureIncomingPageIndex`.
- Persistence: one JSON, base64 image bytes embedded → never put big
  derived blobs (web snapshots) in it.

## Website (separate from the app)
- `site/` — landing + `install.html` + `manual.html`, ONY Semimono, brand
  yellow `#F0EC00` / green `#3DA726`, built from the user's brand kit
  (coin alphabet `assets/letters/`, badges, puffy mark, marquee) in a
  light editorial (get-spatial.com-style) layout. transitions.dev recipes
  applied (texts-reveal hero, avatar-group comb-hover on use-cases).
- **Live:** https://clip-umprum.vercel.app (Vercel project `clip-umprum`,
  team `isergei96-1872s-projects`). Deploy: `cd site && npx vercel --prod`.
- Download button → install page → `releases/latest/download/CLIP.dmg`.

## Open follow-ups / decisions
- Repo is now **PUBLIC** (`Tsel96/clip`) — release-asset download URLs and
  the raw appcast work for the public. (Was private; done.)
- `site/index.html`'s iPhone-Shortcut link is filled in — no
  `SHORTCUT_URL_HERE` placeholder left (grep confirms). (Done.)
- **Delete the Vercel token** `clip-deploy` at vercel.com/account/tokens
  (it was used from chat to deploy; unverified whether still active —
  check before assuming).
- Hero product shot is a composed scene; swap a real screenshot into
  `site/assets/` when available.
- In-app setup-guide URL points at `clip-umprum.vercel.app` (good).

## Exhibition loop video (requested, not built)
16s, 4K/60fps, **seamless loop** (frame 0 = last frame: same wide canvas at
same zoom), reads MUTED. Beats: 0–2 brand (coin C·L·I·P on yellow) → 2–5
canvas fills with real cards (a video plays) → 5–7.5 fluid zoom/glide +
glass minimap dial → 7.5–10 Colorform color clouds → 10–12 Archive list →
12–14 iPhone→canvas drop → 14–16 pull back to opening wide shot. One idea
per ~2.5s; ONY Semimono labels ≤4 words. Record the real app at 60fps.

## Future ideas (from Spatial/GatherOS comparison)
PDF/document cards (PDFKit), iCloud sync (big), distraction-free writing
mode, broader page/board export. GatherOS detail-inspector already adopted
(CardLightboxLayer). Spatial's Scratch Pad = the quick-capture hotkey above.
