import SwiftUI
import AppKit
import AVFoundation
import Combine

// Split out of CanvasState.swift (god-object refactor): tweet creation + local file imports (image/video/web).
extension CanvasState {


    // MARK: - Tweet creation

    func addTweet(url: String, at worldPoint: CGPoint? = nil,
                  origin: CanvasNode.Origin = .local) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // The regex is the validator — it tolerates tracking params,
        // /statuses/ paths, and other human-real URL shapes that the
        // cruder substring check would reject.
        guard TweetService.extractTweetID(from: trimmed) != nil else {
            alert = AlertContent(
                title: "Not an X / Twitter URL",
                message: "Paste a link that points at a single tweet, e.g. https://x.com/user/status/123…"
            )
            return
        }

        let cardWidth: CGFloat = 360
        let centre = worldPoint ?? screenToWorld(point: viewportCentre)
        let jitter: CGFloat = worldPoint == nil ? CGFloat.random(in: -40...40) : 0
        let position = CGPoint(
            x: centre.x - cardWidth / 2 + jitter,
            y: centre.y - 120 + jitter
        )

        var node = CanvasNode.tweet(url: trimmed, position: position, width: cardWidth)
        node.origin = origin
        withUndoable { nodes.append(node) }
        pendingRevealNodeIDs.insert(node.id)
    }

    func pasteFromClipboard() {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            alert = AlertContent(title: "Clipboard is empty",
                                  message: "Copy a post link first, then press ⌘V.")
            return
        }
        addPostFromURL(text)
    }

    /// Decides whether the pasted URL is a tweet, an Instagram post, or
    /// something we can't handle yet, and routes accordingly.
    func addPostFromURL(_ url: String, at worldPoint: CGPoint? = nil,
                        origin: CanvasNode.Origin = .local) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // Route by what the real parsers can extract, not by substring
        // sniffing — the machine sweats so a /statuses/ path or a link
        // full of tracking params still lands as a card.
        if TweetService.extractTweetID(from: trimmed) != nil
            || TweetService.isLikelyTweetURL(trimmed) {
            addTweet(url: trimmed, at: worldPoint, origin: origin)
        } else if InstagramService.parse(trimmed) != nil
            || InstagramService.isLikelyInstagramURL(trimmed) {
            addInstagram(url: trimmed, at: worldPoint, origin: origin)
        } else if YouTubeService.videoID(from: trimmed) != nil
            || YouTubeService.isLikelyYouTubeURL(trimmed) {
            addYouTube(url: trimmed, at: worldPoint, origin: origin)
        } else {
            // Any other http(s) link becomes a rendered web-clip card
            // instead of a dead-end alert.
            addWebClip(url: trimmed, at: worldPoint, origin: origin)
        }
    }

    /// Add a web-clip card for an arbitrary http(s) URL. Non-web strings
    /// (no scheme) get a gentle alert rather than a broken card.
    func addWebClip(url: String, at worldPoint: CGPoint? = nil,
                    origin: CanvasNode.Origin = .local) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            alert = AlertContent(
                title: "Not a link",
                message: "Paste a web address (starting with http:// or https://), an X / Instagram / YouTube post, or drop a file."
            )
            return
        }
        let cardWidth: CGFloat = 480, cardHeight: CGFloat = 320
        let centre = worldPoint ?? screenToWorld(point: viewportCentre)
        let jitter: CGFloat = worldPoint == nil ? CGFloat.random(in: -40...40) : 0
        let position = CGPoint(x: centre.x - cardWidth / 2 + jitter,
                               y: centre.y - cardHeight / 2 + jitter)
        var node = CanvasNode.webclip(url: trimmed, position: position,
                                      width: cardWidth, height: cardHeight)
        node.origin = origin
        withUndoable { nodes.append(node) }
        pendingRevealNodeIDs.insert(node.id)
    }

    // MARK: - Local file imports
    //
    // Limits intentionally mirror Figma's:
    //   • Images:   ≤ 4 MB                and ≤ 4096 × 4096 px
    //   • Videos:   ≤ 100 MB, ≤ 4 minutes, and ≤ 4096 × 4096 px

    static let maxImageBytes: Int64 = 4 * 1024 * 1024
    static let maxImagePixelDim: Int = 4096

    static let maxVideoBytes: Int64 = 100 * 1024 * 1024
    static let maxVideoDurationSeconds: Double = 240
    static let maxVideoPixelDim: CGFloat = 4096

    enum LocalImportError: LocalizedError {
        case unsupportedType
        case readFailed
        case oversizedImage(Int64)
        case oversizedVideo(Int64)
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .unsupportedType:
                return "Only images (PNG, JPEG, HEIC, GIF, WebP, TIFF) and videos (MP4, MOV, M4V) are supported."
            case .readFailed:
                return "Couldn't read the file."
            case .oversizedImage(let limit):
                return "Image is too large. Maximum is \(byteString(limit))."
            case .oversizedVideo(let limit):
                return "Video is too large. Maximum is \(byteString(limit))."
            case .invalidImage:
                return "That file isn't a valid image."
            }
        }

        private func byteString(_ b: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
        }
    }

    /// Add an image from local disk.
    ///   • Rejects files larger than `maxImageBytes` (4 MB).
    ///   • Rejects images whose intrinsic pixel dimensions exceed
    ///     `maxImagePixelDim` (4096 px) on either axis.
    /// Caps the on-canvas width/height at 600pt while preserving aspect ratio.
    func addImage(data: Data, filename: String, at worldPoint: CGPoint? = nil) {
        guard data.count <= Self.maxImageBytes else {
            alert = AlertContent(
                title: "Image too large",
                message: "Images can be up to \(byteString(Self.maxImageBytes))."
            )
            return
        }
        guard let image = NSImage(data: data),
              image.size.width > 0,
              image.size.height > 0 else {
            alert = AlertContent(title: "Invalid image",
                                  message: LocalImportError.invalidImage.errorDescription ?? "")
            return
        }

        // Pixel-dimension check uses the underlying bitmap, not the
        // point-based `image.size` (which can be scaled for HiDPI).
        let pixelsWide = image.representations.first?.pixelsWide ?? Int(image.size.width)
        let pixelsHigh = image.representations.first?.pixelsHigh ?? Int(image.size.height)
        if pixelsWide > Self.maxImagePixelDim || pixelsHigh > Self.maxImagePixelDim {
            alert = AlertContent(
                title: "Image too large",
                message: "Images can be up to \(Self.maxImagePixelDim) × \(Self.maxImagePixelDim) px."
            )
            return
        }

        let cardSize = Self.fitInto(maxDim: 600, naturalSize: image.size)
        let centre = worldPoint ?? screenToWorld(point: viewportCentre)
        let position = CGPoint(
            x: centre.x - cardSize.width  / 2,
            y: centre.y - cardSize.height / 2
        )
        let node = CanvasNode.image(data: data, filename: filename,
                                    position: position, size: cardSize)
        withUndoable {
            nodes.append(node)
        }
        // Mark it so its view plays the wavefront reveal once on appear.
        pendingRevealNodeIDs.insert(node.id)
    }

    /// Add a local video by URL. Lets AVPlayer stream from disk (no decode
    /// into memory). Enforces Figma-style limits:
    ///   • file size ≤ `maxVideoBytes` (100 MB)
    ///   • duration  ≤ `maxVideoDurationSeconds` (4 minutes)
    ///   • each axis ≤ `maxVideoPixelDim` (4096 px)
    func addVideo(fileURL: URL, at worldPoint: CGPoint? = nil) {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= Self.maxVideoBytes else {
            alert = AlertContent(
                title: "Video too large",
                message: "Videos can be up to \(byteString(Self.maxVideoBytes))."
            )
            return
        }

        // R16: metadata loads are ASYNC — the old sync `.duration`/`.tracks`
        // reads parsed the whole moov atom on the main thread (beachball on a
        // big drop). The card is sized from the video's natural aspect (fit
        // into 600 pt) instead of a hardcoded 480×270. Page + drop point are
        // pinned NOW — the user may switch pages/pan before the parse ends.
        let asset = AVURLAsset(url: fileURL)
        let pageID = activePageID
        let centre = worldPoint ?? screenToWorld(point: viewportCentre)
        Task { [weak self] in
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            var cardSize = CGSize(width: 480, height: 270)
            var tooBig = false
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let props = try? await track.load(.naturalSize, .preferredTransform) {
                let raw = props.0.applying(props.1)
                let w = abs(raw.width), h = abs(raw.height)
                if w > Self.maxVideoPixelDim || h > Self.maxVideoPixelDim {
                    tooBig = true
                } else if w > 0, h > 0 {
                    cardSize = Self.fitInto(maxDim: 600, naturalSize: CGSize(width: w, height: h))
                }
            }
            guard let self else { return }
            if duration.isFinite, duration > Self.maxVideoDurationSeconds {
                self.alert = AlertContent(
                    title: "Video too long",
                    message: "Videos can be up to \(Int(Self.maxVideoDurationSeconds / 60)) minutes."
                )
                return
            }
            if tooBig {
                self.alert = AlertContent(
                    title: "Video resolution too high",
                    message: "Videos can be up to \(Int(Self.maxVideoPixelDim)) × \(Int(Self.maxVideoPixelDim)) px."
                )
                return
            }
            let position = CGPoint(
                x: centre.x - cardSize.width  / 2,
                y: centre.y - cardSize.height / 2
            )
            self.appendNode(.video(fileURL: fileURL,
                                   filename: fileURL.lastPathComponent,
                                   position: position,
                                   size: cardSize),
                            toPage: pageID)
        }
    }

    private func byteString(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private static func fitInto(maxDim: CGFloat, naturalSize: CGSize) -> CGSize {
        let w = naturalSize.width, h = naturalSize.height
        let scale = min(1, min(maxDim / w, maxDim / h))
        return CGSize(width: w * scale, height: h * scale)
    }

    /// Reset every content card to its native (add-time) size, preserving aspect
    /// and keeping the card centred. Cards can balloon (manual resize / import) to
    /// thousands of points wide, which rasterises to enormous bitmaps — bloating
    /// memory, off-screen reveal renders, and especially zoom FPS. This snaps each
    /// back to the per-kind default width. Structural cards (text / sticky /
    /// section / folder / drawing) keep their own sizing.
    func resetAllNodesToNativeSize() {
        withUndoable {
            for i in nodes.indices {
                let old = nodes[i]
                guard let native = nativeSize(for: old) else { continue }
                let cx = old.position.x + old.width / 2
                let cy = old.position.y + (old.height ?? old.width) / 2
                nodes[i].width = native.width
                nodes[i].height = native.height
                let newH = native.height ?? native.width
                nodes[i].position = CGPoint(x: cx - native.width / 2, y: cy - newH / 2)
            }
        }
        resetWorldBoundsCache()
    }

    /// Per-kind native (width, optional height). Aspect-driven kinds scale their
    /// height from the CURRENT aspect (intact in the bloated size — no re-decode);
    /// fixed-embed kinds use their service default. `nil` → leave the node alone.
    private func nativeSize(for node: CanvasNode) -> (width: CGFloat, height: CGFloat?)? {
        let curW = node.width
        let curH = node.height ?? node.width
        let aspect = curW > 0 ? curH / curW : 1
        switch node.kind {
        case .tweet:              return (360, node.height.map { _ in 360 * aspect })
        case .webclip:            return (480, 320)
        case .instagram(let url): return (360, InstagramService.defaultCardHeight(for: url))
        case .youtube:            return (360, YouTubeService.defaultCardHeight(forWidth: 360))
        case .image:
            let s = Self.fitInto(maxDim: 600, naturalSize: CGSize(width: curW, height: curH))
            return (s.width, s.height)
        case .video:              return (480, 480 * aspect)
        case .folder:             return (437, node.height.map { _ in 437 * aspect })
        default:                  return nil
        }
    }

    /// Add an Instagram post / reel / TV node to the canvas.
    func addInstagram(url: String, at worldPoint: CGPoint? = nil,
                      origin: CanvasNode.Origin = .local) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard InstagramService.isLikelyInstagramURL(trimmed),
              InstagramService.parse(trimmed) != nil else {
            alert = AlertContent(
                title: "Not an Instagram URL",
                message: "Paste a link that points at a post or reel, " +
                         "e.g. https://www.instagram.com/p/ABC123/"
            )
            return
        }

        let cardWidth: CGFloat = 360
        let cardHeight = InstagramService.defaultCardHeight(for: trimmed)
        let centre = worldPoint ?? screenToWorld(point: viewportCentre)
        let jitter: CGFloat = worldPoint == nil ? CGFloat.random(in: -40...40) : 0
        let position = CGPoint(
            x: centre.x - cardWidth / 2 + jitter,
            y: centre.y - cardHeight / 2 + jitter
        )

        var node = CanvasNode.instagram(url: trimmed,
                                        position: position,
                                        width: cardWidth,
                                        height: cardHeight)
        node.origin = origin
        withUndoable { nodes.append(node) }
        pendingRevealNodeIDs.insert(node.id)
    }

    func addYouTube(url: String, at worldPoint: CGPoint? = nil,
                    origin: CanvasNode.Origin = .local) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard YouTubeService.isLikelyYouTubeURL(trimmed),
              YouTubeService.videoID(from: trimmed) != nil else {
            alert = AlertContent(
                title: "Not a YouTube URL",
                message: "Paste a link to a YouTube video, e.g. " +
                         "https://youtube.com/watch?v=… or https://youtu.be/…"
            )
            return
        }

        let cardWidth: CGFloat = 360
        let cardHeight = YouTubeService.defaultCardHeight(forWidth: cardWidth)
        let centre = worldPoint ?? screenToWorld(point: viewportCentre)
        let jitter: CGFloat = worldPoint == nil ? CGFloat.random(in: -40...40) : 0
        let position = CGPoint(
            x: centre.x - cardWidth / 2 + jitter,
            y: centre.y - cardHeight / 2 + jitter
        )

        let node = CanvasNode(position: position, width: cardWidth,
                              height: cardHeight, kind: .youtube(url: trimmed),
                              origin: origin)
        withUndoable { nodes.append(node) }
        pendingRevealNodeIDs.insert(node.id)
    }
}
