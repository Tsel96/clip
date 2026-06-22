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

        let cardSize = fitInto(maxDim: 600, naturalSize: image.size)
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

        let asset = AVURLAsset(url: fileURL)
        let duration = CMTimeGetSeconds(asset.duration)
        if duration.isFinite, duration > Self.maxVideoDurationSeconds {
            alert = AlertContent(
                title: "Video too long",
                message: "Videos can be up to \(Int(Self.maxVideoDurationSeconds / 60)) minutes."
            )
            return
        }

        if let track = asset.tracks(withMediaType: .video).first {
            let raw = track.naturalSize.applying(track.preferredTransform)
            let w = abs(raw.width), h = abs(raw.height)
            if w > Self.maxVideoPixelDim || h > Self.maxVideoPixelDim {
                alert = AlertContent(
                    title: "Video resolution too high",
                    message: "Videos can be up to \(Int(Self.maxVideoPixelDim)) × \(Int(Self.maxVideoPixelDim)) px."
                )
                return
            }
        }

        let cardWidth: CGFloat = 480
        let cardHeight: CGFloat = 270
        let centre = worldPoint ?? screenToWorld(point: viewportCentre)
        let position = CGPoint(
            x: centre.x - cardWidth  / 2,
            y: centre.y - cardHeight / 2
        )
        withUndoable {
            nodes.append(.video(fileURL: fileURL,
                                filename: fileURL.lastPathComponent,
                                position: position,
                                size: CGSize(width: cardWidth, height: cardHeight)))
        }
    }

    private func byteString(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }

    private func fitInto(maxDim: CGFloat, naturalSize: CGSize) -> CGSize {
        let w = naturalSize.width, h = naturalSize.height
        let scale = min(1, min(maxDim / w, maxDim / h))
        return CGSize(width: w * scale, height: h * scale)
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
