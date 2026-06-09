import Foundation

/// Parses Instagram post / reel / IGTV URLs and builds the public
/// "embed/captioned" URL we feed to `WKWebView`. That endpoint renders
/// without an account and is meant for iframe consumption, which is
/// the closest IG equivalent of Twitter's syndication JSON.
enum InstagramService {

    enum PostKind: Equatable {
        case post     // /p/SHORTCODE/
        case reel     // /reel/SHORTCODE/  or /reels/SHORTCODE/
        case tv       // /tv/SHORTCODE/

        var pathSegment: String {
            switch self {
            case .post: return "p"
            case .reel: return "reel"
            case .tv:   return "tv"
            }
        }

        /// Sensible default height for the embed card (width is fixed at 360).
        var defaultHeight: CGFloat {
            switch self {
            case .post: return 560
            case .reel: return 640
            case .tv:   return 640
            }
        }
    }

    static func isLikelyInstagramURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        guard lower.contains("instagram.com/") else { return false }
        return lower.contains("/p/")
            || lower.contains("/reel/")
            || lower.contains("/reels/")
            || lower.contains("/tv/")
    }

    /// Pulls out (kind, shortcode) from any of:
    ///   • https://www.instagram.com/p/ABC123/
    ///   • https://instagram.com/reel/ABC123/?igsh=...
    ///   • https://www.instagram.com/reels/ABC123/
    ///   • https://www.instagram.com/tv/ABC123/
    private static let postRegex = try! NSRegularExpression(
        pattern: #"instagram\.com\/(p|reel|reels|tv)\/([A-Za-z0-9_-]+)"#,
        options: [.caseInsensitive]
    )

    static func parse(_ urlString: String) -> (kind: PostKind, shortcode: String)? {
        let regex = postRegex
        let range = NSRange(urlString.startIndex..., in: urlString)
        guard let match = regex.firstMatch(in: urlString, options: [], range: range),
              match.numberOfRanges > 2,
              let kindRange = Range(match.range(at: 1), in: urlString),
              let codeRange = Range(match.range(at: 2), in: urlString) else {
            return nil
        }
        let kindStr = urlString[kindRange].lowercased()
        let code = String(urlString[codeRange])
        let kind: PostKind
        switch kindStr {
        case "p":              kind = .post
        case "reel", "reels":  kind = .reel
        case "tv":             kind = .tv
        default:               kind = .post
        }
        return (kind, code)
    }

    /// The captioned-embed page. Slightly richer than `/embed` — includes
    /// the post caption and the "view on Instagram" footer.
    static func embedURL(from urlString: String) -> URL? {
        guard let parsed = parse(urlString) else { return nil }
        return URL(string:
            "https://www.instagram.com/\(parsed.kind.pathSegment)/\(parsed.shortcode)/embed/captioned"
        )
    }

    /// Default card height for a node created from this URL.
    static func defaultCardHeight(for urlString: String) -> CGFloat {
        parse(urlString)?.kind.defaultHeight ?? PostKind.post.defaultHeight
    }
}
