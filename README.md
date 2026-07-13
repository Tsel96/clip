# CLIP

A native macOS spatial-canvas app (AppKit + SwiftUI, single SwiftPM
executable target). Drop in links, images, videos, and drawings and arrange
them freely on an infinite, pannable/zoomable canvas — cards, folders,
connectors, stickies, an archive view, and a colorform mode.

## Build

```bash
DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer" swift build
```

This is the **only** working build command. Plain `swift build` / `swift run`
with the default Command Line Tools **fails** — several views (e.g.
`LiquidGlassMinimap.swift`, `VideoTrimOverlay.swift`) use `glassEffect`,
which only exists in the macOS 26 SDK. Xcode-beta supplies that SDK; the
default CLT doesn't.

Run tests the same way: `DEVELOPER_DIR=... swift build` above, or `swift test`.

To build and package a release `.app` (what's actually shipped/deployed):

```bash
CONFIG=release BUILD=<n> Scripts/make-app.sh /Applications
```

See `DISTRIBUTION.md` for the full release/exhibition runbook and
`AGENT_HANDOFF.md` for current in-progress work.

## Use

Menu shortcuts live in `ClipApp.swift` (`.commands { … }`) — that's the
source of truth. Highlights:

| Action                     | Shortcut |
| -------------------------- | -------- |
| Add a post by URL          | **⌘N**   |
| New folder                 | **⇧⌘N**  |
| Paste onto the canvas      | **⌘V**   |
| Find                       | **⌘K**   |
| Delete selection           | **Delete** |
| Canvas / Colorform / Archive mode | **⌘1 / ⌘2 / ⌘3** |
| Zoom in / out / actual size | **⌘+ / ⌘− / ⌘0** |

## Code layout

`Sources/CLIP/` (~108 files, single executable target — see `Package.swift`).
No itemized file list here; it goes stale immediately. Entry points to start
from:

* `ClipApp.swift` – `@main` scene, menu commands
* `CanvasState.swift` (+ `CanvasState+*.swift` extensions) – the canvas model
* `CollectionCanvas.swift` / `CanvasView.swift` – the AppKit-backed canvas view
* `Models.swift` – `CanvasNode` / `CanvasNode.Kind` and friends

`Tests/CLIPTests/` holds the test target (`swift test`, same `DEVELOPER_DIR`
requirement as above).
