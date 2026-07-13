# CLIP — Agent Handoff

Native macOS canvas app **CLIP** (Swift / SwiftUI / AppKit, SwiftPM) at `/Users/sergei/clip`.
Built 1:1 from Figma (file key `CaFO3DBaQGOXBOB3Nkp0sZ`) and Spatial.app.

## Get the RIGHT build first
Plain `swift build` FAILS (broken Command Line Tools / no macOS 26 SDK) — use Xcode-beta:
```bash
cd /Users/sergei/clip
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" swift build
CONFIG=debug Scripts/make-app.sh /Applications
killall -9 CLIP; open /Applications/CLIP.app
```
SourceKit squiggles in this repo are SPURIOUS — trust `swift build`, not the editor.
Branch `claude/code-audit-performance-o0u336`; an auto-snapshot commit lands every ~5 min (expected).

## Object hover + selection states — COMPLETED
The task this file used to hand off (square 1px card corners, offset outline,
proportional hover/selection scale, folder curved outline) has shipped. Entry
points if you need to touch this again:
- `NativeCardContent.swift` `enum CardChrome` — `cornerRadius` (square, per
  Figma 88:329/330/336) and the outline/shadow constants.
- `CollectionCanvas.swift` — selection chrome, `updateChrome`, `liftScale`,
  `selectedNodeIDs`.
- `FolderCardView.swift` `setState(lifted:selected:mag:)` — folder's curved
  offset outline (`haloView`).
- Read memory `clip-object-states-spec` and `spatial-unified-item-system`
  before changing any of this — they record the exact spec it was built to.

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

Also read `/Users/sergei/.claude/projects/-Users-sergei/memory/MEMORY.md`.
