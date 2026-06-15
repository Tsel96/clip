import Foundation
import CoreGraphics

/// Parses YouTube URLs (watch / youtu.be / shorts / embed) and builds the
/// privacy-friendly embed URL we feed to `WKWebView`, plus the thumbnail
/// poster URL used for the static (non-live) card. The YouTube counterpart
/// of `TweetService` / `InstagramService`.
enum YouTubeService {

    static func isLikelyYouTubeURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        guard lower.contains("youtube.com") || lower.contains("youtu.be/") else { return false }
        return lower.contains("watch?v=")
            || lower.contains("youtu.be/")
            || lower.contains("/shorts/")
            || lower.contains("/embed/")
            || lower.contains("/v/")
    }

    /// Extract the 11-char video id from any common YouTube URL shape:
    ///   • https://www.youtube.com/watch?v=ID&t=10s
    ///   • https://youtu.be/ID?si=...
    ///   • https://www.youtube.com/shorts/ID
    ///   • https://www.youtube.com/embed/ID
    private static let videoIDRegex = try! NSRegularExpression(
        pattern: #"(?:youtu\.be/|youtube\.com/(?:watch\?v=|shorts/|embed/|v/))([A-Za-z0-9_-]{11})"#,
        options: [.caseInsensitive]
    )

    static func videoID(from urlString: String) -> String? {
        let regex = videoIDRegex
        let range = NSRange(urlString.startIndex..., in: urlString)
        guard let match = regex.firstMatch(in: urlString, options: [], range: range),
              match.numberOfRanges > 1,
              let idRange = Range(match.range(at: 1), in: urlString) else {
            return nil
        }
        return String(urlString[idRange])
    }

    /// Inline embed. Autoplay is OFF (`autoplay=0`): an autoplaying embed
    /// keeps a video decoding inside the window's display-cycle, which on
    /// the macOS 26/27 beta seed re-enters AppKit constraint layout and
    /// trips the depth-16 recursion guard. The user presses play in the
    /// embed to start it. `rel=0`/`modestbranding=1` keep it tidy; the
    /// nocookie host avoids tracking cookies.
    static func embedURL(from urlString: String) -> URL? {
        guard let id = videoID(from: urlString) else { return nil }
        return URL(string:
            "https://www.youtube-nocookie.com/embed/\(id)?playsinline=1&autoplay=0&mute=1&rel=0&modestbranding=1")
    }

    /// Thumbnail used by the static (non-live) poster card.
    static func posterURL(from urlString: String) -> URL? {
        guard let id = videoID(from: urlString) else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(id)/hqdefault.jpg")
    }

    /// 16:9 card height for a given card width.
    static func defaultCardHeight(forWidth width: CGFloat) -> CGFloat {
        (width * 9.0 / 16.0).rounded()
    }
}
