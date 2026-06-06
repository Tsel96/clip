# Embedded Video Canvas (macOS, SwiftUI)

A native macOS port of the React/Figma-Make prototype.
Paste an X.com (Twitter) link and the post — including the autoplaying
video — appears as a card on an infinite, pannable canvas.

## Run

From this folder:

```bash
swift run
```

…or open `Package.swift` in Xcode and press ⌘R.

## Use

| Action                                | How                                          |
| ------------------------------------- | -------------------------------------------- |
| Add a tweet by URL                    | Toolbar **+** button, or **⌘N**              |
| Paste a tweet URL onto the canvas     | **⌘V**                                       |
| Pan the canvas                        | Two-finger trackpad scroll                   |
| Zoom                                  | Pinch on trackpad, or **⌘+ / ⌘− / ⌘0**       |
| Move a card                           | Click + drag                                 |
| Mute / pause a video                  | Hover the video, use the on-card buttons     |
| Delete the selected card              | **Delete**                                   |

## Architecture

* `EmbeddedVideoCanvasApp.swift` – `@main` SwiftUI scene + ⌘ shortcuts
* `ContentView.swift` – native window toolbar + Add-Tweet sheet
* `CanvasView.swift` – infinite canvas, dot grid, drag-to-move
* `ScrollAndMagnifyCapture.swift` – `NSView` that turns trackpad scroll
  + pinch into pan / zoom callbacks (the one bit SwiftUI can’t do alone)
* `TweetCardView.swift` – tweet card UI (avatar, text, video, metrics)
* `TweetVideoPlayer.swift` – `AVPlayerLayer`-backed view, looping + autoplay
* `TweetService.swift` – fetches tweet JSON from Twitter’s syndication
  endpoint, falling back to react-tweet's public proxy
* `Models.swift` – `TweetData`, `TweetNode`, `Camera`

All buttons / fields / menus / pickers are stock AppKit-flavoured SwiftUI
controls — no custom-styled widgets.
