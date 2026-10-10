# CLIP — Session Memory / Handoff

A continuity doc so work can resume after `/clear` or a fresh container.
CLIP is a native macOS SwiftUI infinite-canvas moodboard (`Sources/CLIP/`,
~65 files, SwiftPM, macOS 13+, **Apple Silicon**, uses the macOS 26 Liquid
Glass API so it needs the Xcode 26 / macOS 26 SDK to build).

**Branches:** `main` publishes releases (installed copies auto-update);
work happens on `claude/*` branches, which CI only builds + tests.
**Build:** `swift build`; bundle via `Scripts/make-app.sh` (DMG=1 ZIP=1).
This dev env is **Linux — cannot compile AppKit**; the macOS-26 GitHub
Actions workflow (`.github/workflows/release.yml`) is the compile gate and
publishes releases.

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

## Web Clips (planned feature #2) — shipped
`.webclip(url)` cards for any http(s) link; `WebClipCardView` +
`WebClipSnapshotStore` (PNG cache in Application Support/CLIP/webclips,
removed with the card). Loads http(s) only (`WebClipURLPolicy`).

## Hardening pass (Oct 2026, branch `claude/sleepy-fermi-3xh28d`)
- **Save format:** images live in `Application Support/CLIP/images/<sha256>`
  (`ImageBlobStore`); `canvas.json` stores `dataRef`. Inline `data` still
  decodes (old saves, clipboard). Nodes/pages decode per element
  (`LossyElement`) — a bad entry is skipped + the file backed up.
- **Updater:** optional Ed25519 signature (`CLIPUpdatePublicKey`,
  `Scripts/sign-update.swift`, secret `UPDATE_SIGNING_KEY`), https only,
  size/time limits, rollback-safe swap.
- **CI:** `swift test` runs `Tests/CLIPTests`; only main / `v*` tags /
  manual runs publish.
- **Perf:** pan/zoom ticks reuse memoized display nodes (`pagesVersion`);
  boards > 150 cards cull far-off-screen items; Tidy Up uses a sparse
  incremental solver off the main actor.
- **A11y:** palette/segmented control/colour picker expose VoiceOver roles;
  `Motion` tokens honour Reduce Motion.

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
- **Set `UPDATE_SIGNING_KEY`** (repo secret) to turn on update signing.
- **Repo is PRIVATE** → release-asset download URLs 404 for the public.
  User chose **"make repo public"** (Settings → Danger Zone → Change
  visibility) — once done, website download + in-app self-updater work
  with no code change. NOT yet done.
- **Delete the Vercel token** `clip-deploy` at vercel.com/account/tokens
  (it was used from chat to deploy; still active).
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
