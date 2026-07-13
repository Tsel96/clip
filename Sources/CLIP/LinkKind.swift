import Foundation

/// The ONE URL-kind detector. Every ingestion path — paste/drop
/// (`addPostFromURL`), the iPhone-Shortcut inbox (`ingestSharedURL`), and
/// the add-sheet badge/validation (`ContentView`) — routes through here so
/// the paths can't drift. They did: the inbox required isLikely AND a
/// parsed id while paste accepted either, so URL shapes the app happily
/// pasted were silently dropped when shared from the phone.
enum LinkKind {
    case tweet, instagram, youtube

    /// Permissive on purpose (the historical paste behavior): a parsed id
    /// OR a likely-URL shape counts. The services' own loaders surface
    /// failures as a visible error card, which beats a silent drop.
    static func detect(_ s: String) -> LinkKind? {
        if TweetService.extractTweetID(from: s) != nil
            || TweetService.isLikelyTweetURL(s) { return .tweet }
        if InstagramService.parse(s) != nil
            || InstagramService.isLikelyInstagramURL(s) { return .instagram }
        if YouTubeService.videoID(from: s) != nil
            || YouTubeService.isLikelyYouTubeURL(s) { return .youtube }
        return nil
    }
}
