# CLIP — Agent Handoff (object hover + selection states)

You are picking up native macOS canvas app **CLIP** (Swift / SwiftUI / AppKit, SwiftPM).
Working dir: `/Users/sergei/clip`. Built 1:1 from a Figma file (key `CaFO3DBaQGOXBOB3Nkp0sZ`) and Spatial.app.

## 0. Get the RIGHT build first (do this before anything)
- Toolchain: plain `swift build` FAILS (broken Command Line Tools). You MUST use Xcode-beta:
  ```bash
  cd /Users/sergei/clip
  DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" swift build
  ```
- Deploy + launch:
  ```bash
  CONFIG=debug Scripts/make-app.sh /Applications
  killall -9 CLIP; open /Applications/CLIP.app
  ```
- Current deployed build is at `.build/debug/CLIP` and `/Applications/CLIP.app` (already running).
  Branch `claude/code-audit-performance-o0u336`. NOTE: an auto-snapshot commit lands every ~5 min, so HEAD moves on its own — that's expected, not someone else editing.
- Confirm green before you change anything. SourceKit diagnostics in this repo are SPURIOUS
  ("StateMacro could not be found", "self is immutable", "$x not in scope", cross-worktree "Cannot find X").
  Trust `swift build`, NOT the editor squiggles.

## 1. HARD RULES (these cost real credits/time when broken)
- **Do NOT puppeteer the app** with `/tmp/clicker` + `screencapture`. It hits the WRONG window
  (the dark "CLIP Visual Tool" web app keeps coming forward) and wastes credits. Instead:
  add file-logging to `/tmp/clip_diag.txt`, and give the USER exact "click here / screenshot this"
  steps. Let the user produce the pixels.
- **Do NOT copy files from any `.claude/worktrees/agent-*` worktree over the main tree.**
  The last object-states agent branched from an OLD HEAD; copying its files wholesale REGRESSED
  newer code (broke `isConnectMode`, `onZoomChange`, `editingConnectorID`). Work DIRECTLY in the
  current working tree, edit in place, build after each step, keep it green.
- Pull exact specs from Figma with the Figma MCP (`get_screenshot`, `get_design_context`,
  `get_metadata`) — don't eyeball.

## 2. PRIMARY TASK — object hover + selection states (canvas)
Implement the three Figma states for canvas objects, smoothly and quickly:
- Rest:     `…/?node-id=88-329`
- Hover:    `…/?node-id=88-330`
- Selected: `…/?node-id=88-336`
(file key `CaFO3DBaQGOXBOB3Nkp0sZ`; node ids also as `88:329` / `88:330` / `88:336` in the API)

Exact spec (user's words, hold to these):
- **Cards are NOT rounded — square corners.** They're currently rounded:
  `NativeCardContent.swift:520` `CardChrome.cornerRadius = 19.375` (applied at `:354`, `:404`, `:422`,
  plus `shadowCornerRadius` in `CollectionCanvas.swift`). Set the card body square.
- **Hover/selected OUTLINE:** sits **8px offset AWAY** from the card edge (8px gap), is **4px thick
  ALWAYS** (constant on-screen thickness — divide by the scroll magnification so zoom doesn't change
  it), and HAS a corner radius (~8px) even though the card itself is square. It must adapt to ANY card
  size perfectly — consistent gap + thickness at every size and zoom. (Resizing previously made the
  outlines look broken; that's the thing to nail.)
- **Hover scale:** card scales up slightly, **proportional (percentage)** so it reads the same on
  small and large cards — NOT a fixed point delta.
- **Shadows:** match each state (rest / hover / selected) carefully from Figma.
- **Transitions:** smooth + quick.
- **Folders are DIFFERENT — their outline is CURVED** (traces the folder silhouette, not the square
  8px-radius rectangle). Folder chrome is in `FolderCardView.swift` (it already has `outlineView`
  tracing the silhouette + a 4-layer `shadowViews`; selection there is currently just a 1.04 scale at
  `:190`). Give folders the curved offset outline + the hover scale, consistent with the card states.

Where it lives (AppKit, NOT SwiftUI gestures — see memory `native-canvas-interaction`):
- Selection chrome class is in `CollectionCanvas.swift` (~line 720+: "float shadow, the section
  outline, and the selection ring + corner handles"), refreshed by `updateChrome` (~line 437).
- Selection set: `selectedNodeIDs` / live `state.selectedNodeIDs` (`CollectionCanvas.swift:177-188`).
- Hover currently has no source — add mouse-tracking (NSTrackingArea on the item view, or via
  `CanvasInputView.swift`) to drive the hover state.
- STRONGLY consider memory `spatial-unified-item-system`: one base (CanvasItemView + an animator +
  a `highlightStyle` of `.selected/.hover/.click/.none`) so select/hover/drag transforms stop
  colliding. Read that memory before designing.

## 3. TO-DO (ordered)
1. **[primary]** Object hover + selection states (section 2).
2. **Folder shadow visibility** — the visible-shadow fix was reverted; folder shadow is currently the
   "not visible" `shadowViews` version. Figma 4-layer spec: alpha 0.09/0.07/0.04/0.01,
   radius 6/11/14/17, offsets 3/11/24/43 (authored on 953×818). Make the folder drop-shadow actually
   show, scaled to the live folder size.
3. **Verify toolbar Round 2** (was in progress, code is in place — just needs runtime confirmation
   via USER screenshots, NOT puppeteering): clicking "+" turns it dark-green
   (`#2B751B→#358923`, `CanvasToolPalette.swift:737`); an "INSERT LINK HERE" pill floats CENTERED
   above the "+" (`LinkInputBar.swift`, mounted by CanvasView as its own bottom overlay). Give the
   user the click/screenshot steps and confirm against Figma `72:36784`.

## 4. DO NOT BREAK (intact, verified-good — leave alone unless the task needs them)
- Color picker `RadialColorPicker.swift` (Spatial-matched flower; pick is handled inside the global
  `outsideMonitor` mouse-down, not the overlay's own mouseDown — keep that).
- Sidebar `PagesSidebar.swift` + `ContentView.swift` HStack restructure (sidebar `zIndex(1)`, real
  shadow spilling onto canvas, green-wash row states, uppercase rename via uppercasing Binding,
  rename-commits-on-click-out).
- Canvas bg `#EDF0F1`; top segmented control `CanvasTopSegmentedControl.swift` (top-center, 18px);
  `CardDetailView` toolbar-pill top-rim; forced light mode in `ClipApp.swift`.

## 5. Reverted context (so you're not confused)
The previous object-states agent's work was fully reverted: `CardStateChrome.swift` was DELETED, and
`CollectionCanvas.swift` / `CanvasInputView.swift` / `FolderCardView.swift` / `NativeCardContent.swift`
were restored to commit `36ddb87`. The agent worktree `agent-aa0083686f9d194b5` still exists but is
DIVERGENT — do NOT pull from it. Re-implement cleanly on the current tree.

Also read the user's auto-memory index at
`/Users/sergei/.claude/projects/-Users-sergei/memory/MEMORY.md` — especially
`clip-runtime-debug-via-user`, `native-canvas-interaction`, `spatial-unified-item-system`,
`spatial-canvas-architecture`.
