import Foundation
import AppKit
import AVFoundation

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
            if let img = NSImage(data: data) {
                let s = img.size
                let w = Int(s.width.rounded()), h = Int(s.height.rounded())
                rows.append(.init(label: "Dimensions", value: "\(w) × \(h)"))
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
            let asset = AVURLAsset(url: fileURL)
            let dur = CMTimeGetSeconds(asset.duration)
            if dur.isFinite, dur > 0 {
                rows.append(.init(label: "Duration", value: formatDuration(dur)))
            }
            return rows

        case .text, .drawing, .section, .stickyNote:
            return []
        }
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
