import Foundation
import AppKit
import AVFoundation
import ImageIO

/// A single auto-derived metadata row to display under a card.
struct CardMetadataRow: Equatable {
    let label: String
    let value: String
}

/// Auto-derived metadata for a canvas node. Surfaced via the "Show details"
/// toggle on each card. text/drawing nodes return [].
///
/// `rows(for:)` is synchronous and returns the lightweight info you can
/// derive from the node alone. `enrichedRows(for:)` is async and performs
/// any necessary network fetch — currently used to pull the tweet's
/// author/text/likes/replies from the Twitter syndication API.
enum NodeMetadata {

    // MARK: - Sync

    static func rows(for node: CanvasNode) -> [CardMetadataRow] {
        switch node.kind {
        case .tweet(let url):
            return [
                .init(label: "Type",   value: "Tweet"),
                .init(label: "Source", value: url),
            ]

        case .youtube(let url):
            return [
                .init(label: "Type",   value: "YouTube"),
                .init(label: "Source", value: url),
            ]

        case .instagram(let url):
            return [
                .init(label: "Type",   value: "Instagram"),
                .init(label: "Source", value: url),
            ]

        case .image(let data, let filename):
            var rows: [CardMetadataRow] = [
                .init(label: "Type", value: "Image"),
                .init(label: "File", value: filename),
                .init(label: "Size", value: byteCount(data.count)),
            ]
            // Read the dimensions from the image header — never decode the
            // pixels (this runs inside a SwiftUI body, on every re-render).
            if let size = pixelSize(of: data) {
                rows.append(.init(label: "Dimensions", value: "\(size.0) × \(size.1)"))
            }
            return rows

        case .video(let fileURL, let filename):
            var rows: [CardMetadataRow] = [
                .init(label: "Type", value: "Video"),
                .init(label: "File", value: filename),
            ]
            if let bytes = try? FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber {
                rows.append(.init(label: "Size", value: byteCount(bytes.intValue)))
            }
            let dur = videoDuration(fileURL)
            if dur.isFinite, dur > 0 {
                rows.append(.init(label: "Duration", value: formatDuration(dur)))
            }
            return rows

        case .folder(_, _, let childIDs):
            return [.init(label: "Type",  value: "Folder"),
                    .init(label: "Items", value: "\(childIDs.count)")]

        case .text, .drawing, .section, .stickyNote, .webclip:
            return []
        }
    }

    /// Pixel size from the image header (no decode).
    static func pixelSize(of data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // EXIF orientations 5–8 are rotated 90°: report width/height as shown.
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (h, w) : (w, h)
    }

    /// Video durations by file, so the header is read once per clip rather
    /// than synchronously on every re-render of the detail panel.
    private static var durationCache: [URL: Double] = [:]
    private static let durationLock = NSLock()

    private static func videoDuration(_ url: URL) -> Double {
        durationLock.lock()
        if let d = durationCache[url] { durationLock.unlock(); return d }
        durationLock.unlock()
        let d = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        durationLock.lock(); durationCache[url] = d; durationLock.unlock()
        return d
    }

    // MARK: - Async-enriched (network fetch)

    /// Fetches richer metadata where available. Falls back to `rows(for:)`
    /// on failure. Currently enriches tweets with author / text / metrics.
    static func enrichedRows(for node: CanvasNode) async -> [CardMetadataRow] {
        switch node.kind {
        case .tweet(let url):
            guard let id = TweetService.extractTweetID(from: url),
                  let data = try? await TweetService.fetch(tweetID: id)
            else { return rows(for: node) }
            return tweetRows(url: url, data: data)
        default:
            return rows(for: node)
        }
    }

    private static func tweetRows(url: String, data: TweetData) -> [CardMetadataRow] {
        var rows: [CardMetadataRow] = [
            .init(label: "Type",   value: "Tweet"),
            .init(label: "Author", value: "\(data.user.name) @\(data.user.screenName)"),
        ]
        if let text = data.text, !text.isEmpty {
            rows.append(.init(label: "Text", value: text))
        }
        if let posted = formatTweetDate(data.createdAt) {
            rows.append(.init(label: "Posted", value: posted))
        }
        if let likes = data.favoriteCount, likes > 0 {
            rows.append(.init(label: "Likes", value: formatCount(likes)))
        }
        if let replies = data.conversationCount, replies > 0 {
            rows.append(.init(label: "Replies", value: formatCount(replies)))
        }
        rows.append(.init(label: "Source", value: url))
        return rows
    }

    // MARK: - Formatters

    private static func byteCount(_ n: Int) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(n))
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private static func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private static func formatTweetDate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Twitter uses both ISO8601 (with fractional seconds) and the
        // legacy "EEE MMM dd HH:mm:ss Z yyyy" format on different endpoints.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) {
            return displayDateFormatter.string(from: d)
        }
        let legacy = DateFormatter()
        legacy.locale = Locale(identifier: "en_US_POSIX")
        legacy.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        if let d = legacy.date(from: raw) {
            return displayDateFormatter.string(from: d)
        }
        return nil
    }
}
