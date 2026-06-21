# CLIP — Agent Handoff: object HOVER + SELECTION states

Native macOS canvas app **CLIP** (Swift / SwiftUI / AppKit, SwiftPM) at `/Users/sergei/clip`.
Built 1:1 from Figma (file key `CaFO3DBaQGOXBOB3Nkp0sZ`) and Spatial.app.
**Your one job: object hover + selection states on the canvas.**

## Get the RIGHT build first
Plain `swift build` FAILS (broken Command Line Tools) — use Xcode-beta:
```bash
cd /Users/sergei/clip
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" swift build
CONFIG=debug Scripts/make-app.sh /Applications
killall -9 CLIP; open /Applications/CLIP.app
```
Current build is already deployed/running. Confirm it builds green before changing anything.
SourceKit squiggles in this repo are SPURIOUS — trust `swift build`, not the editor.
Branch `claude/code-audit-performance-o0u336`; an auto-snapshot commit lands every ~5 min (expected).

## THE TASK — object hover + selection states
Pull exact specs with the Figma MCP (`get_screenshot` / `get_design_context`), file `CaFO3DBaQGOXBOB3Nkp0sZ`:
- Rest `node-id=88-329`, Hover `node-id=88-330`, Selected `node-id=88-336`
  (ids also `88:329` / `88:330` / `88:336` in the API).

Spec (hold to these exactly):
- **Cards are NOT rounded — square corners.** Currently rounded: `NativeCardContent.swift:520`
  `CardChrome.cornerRadius = 19.375` (applied at `:354`, `:404`, `:422`, plus `shadowCornerRadius`
  in `CollectionCanvas.swift`). Make the card body square.
- **Hover/selected OUTLINE:** **8px offset AWAY** from the card edge (8px gap), **4px thick ALWAYS**
  (constant on-screen — divide by scroll magnification so zoom never changes it), with a **corner
  radius (~8px)** even though the card is square. Must adapt to ANY card size and zoom perfectly —
  identical gap + thickness everywhere. (Resizing previously broke the outlines; that's the part to nail.)
- **Hover scale:** card scales up slightly, **proportional (percentage)** so small and large cards
  read the same — NOT a fixed point delta.
- **Shadows:** match each state (rest / hover / selected) from Figma.
- **Transitions:** smooth + quick.
- **Folders are DIFFERENT — CURVED outline** tracing the folder silhouette (not the square 8px-radius
  rect). Folder chrome is `FolderCardView.swift` (already has `outlineView` + 4-layer `shadowViews`;
  selection there is just a 1.04 scale at `:190`). Give folders the curved offset outline + hover scale.

Where it lives (AppKit, NOT SwiftUI gestures):
- Selection chrome class in `CollectionCanvas.swift` (~line 720+: "float shadow, the section outline,
  and the selection ring + corner handles"), refreshed by `updateChrome` (~line 437).
- Selection set: `selectedNodeIDs` / live `state.selectedNodeIDs` (`CollectionCanvas.swift:177-188`).
- Hover has no source yet — add mouse-tracking (NSTrackingArea on the item view / `CanvasInputView.swift`).
- Read memory `spatial-unified-item-system` first (a unified base with `highlightStyle`
  `.selected/.hover/.click/.none`) and `native-canvas-interaction`.

## HARD RULES
- **Do NOT puppeteer the app** with `/tmp/clicker` + `screencapture` — it hits the wrong window and
  wastes credits. Add `/tmp/clip_diag.txt` file-logs and give the USER exact click/screenshot steps.
- **Do NOT copy files from any `.claude/worktrees/agent-*` worktree over the tree** — that regressed
  code last time (broke `isConnectMode` / `onZoomChange` / `editingConnectorID`). Edit IN PLACE, build
  after each step, keep green.

## Don't break (intact, leave alone)
Color picker `RadialColorPicker.swift`; sidebar `PagesSidebar.swift` + `ContentView.swift` HStack
restructure; canvas bg `#EDF0F1`; top segmented control `CanvasTopSegmentedControl.swift`;
`CardDetailView` top-rim; forced light mode in `ClipApp.swift`.

## Reverted context (don't be confused)
A prior object-states agent's work was fully reverted: `CardStateChrome.swift` DELETED;
`CollectionCanvas.swift` / `CanvasInputView.swift` / `FolderCardView.swift` / `NativeCardContent.swift`
restored to commit `36ddb87`. Worktree `agent-aa0083686f9d194b5` still exists but is DIVERGENT — do
NOT pull from it. Re-implement cleanly in the current tree.
Also read `/Users/sergei/.claude/projects/-Users-sergei/memory/MEMORY.md`.
