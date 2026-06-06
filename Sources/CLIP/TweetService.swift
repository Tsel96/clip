import Foundation

enum TweetServiceError: LocalizedError {
    case invalidURL
    case notFound
    case decoding
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:    return "Not a valid X.com or Twitter URL."
        case .notFound:      return "Tweet not found."
        case .decoding:      return "Could not parse the tweet response."
        case .network(let m): return "Network error: \(m)"
        }
    }
}

enum TweetService {
    /// Pulls the numeric status ID out of an X/Twitter URL.
    static func extractTweetID(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?:twitter|x)\.com\/[^\/]+\/status(?:es)?\/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        return String(trimmed[r])
    }

    /// True if a URL plausibly points at an X/Twitter post.
    static func isLikelyTweetURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        return (lower.contains("x.com/") || lower.contains("twitter.com/")) && lower.contains("/status/")
    }

    /// Fetch tweet data from Twitter's public syndication endpoint.
    /// Falls back to the react-tweet proxy if the syndication call fails.
    static func fetch(tweetID: String) async throws -> TweetData {
        do {
            return try await fetchSyndication(tweetID: tweetID)
        } catch {
            return try await fetchReactTweet(tweetID: tweetID)
        }
    }

    // MARK: - Syndication endpoint

    private static func fetchSyndication(tweetID: String) async throws -> TweetData {
        let token = SyndicationToken.compute(for: tweetID)
        var components = URLComponents(string: "https://cdn.syndication.twimg.com/tweet-result")!
        components.queryItems = [
            URLQueryItem(name: "id", value: tweetID),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "lang", value: "en")
        ]
        guard let url = components.url else { throw TweetServiceError.invalidURL }

        var request = URLRequest(url: url)
        // Twitter's syndication CDN can be picky about User-Agent.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TweetServiceError.network("No HTTP response")
        }
        if http.statusCode == 404 { throw TweetServiceError.notFound }
        guard (200..<300).contains(http.statusCode) else {
            throw TweetServiceError.network("HTTP \(http.statusCode)")
        }

        do {
            return try JSONDecoder().decode(TweetData.self, from: data)
        } catch {
            throw TweetServiceError.decoding
        }
    }

    // MARK: - react-tweet proxy fallback

    private struct ReactTweetResponse: Decodable {
        let data: TweetData?
    }

    private static func fetchReactTweet(tweetID: String) async throws -> TweetData {
        guard let url = URL(string: "https://react-tweet.vercel.app/api/tweet/\(tweetID)") else {
            throw TweetServiceError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw TweetServiceError.network("No HTTP response")
        }
        if http.statusCode == 404 { throw TweetServiceError.notFound }
        guard (200..<300).contains(http.statusCode) else {
            throw TweetServiceError.network("HTTP \(http.statusCode)")
        }
        do {
            let wrapper = try JSONDecoder().decode(ReactTweetResponse.self, from: data)
            guard let tweet = wrapper.data else { throw TweetServiceError.notFound }
            return tweet
        } catch let e as TweetServiceError {
            throw e
        } catch {
            throw TweetServiceError.decoding
        }
    }
}

/// Replicates the JS token used by react-tweet:
/// `((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '')`
enum SyndicationToken {
    static func compute(for tweetID: String) -> String {
        guard let idNum = Double(tweetID) else { return "" }
        let value = (idNum / 1e15) * .pi
        let base36 = base36String(value)
        return base36.filter { $0 != "0" && $0 != "." }
    }

    private static let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")

    private static func base36String(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-infinity" : "infinity" }

        let negative = value < 0
        let absValue = Swift.abs(value)
        let intPart = floor(absValue)
        var fracPart = absValue - intPart

        // Integer portion.
        var intStr = ""
        if intPart == 0 {
            intStr = "0"
        } else {
            var n = intPart
            while n > 0 {
                let digit = Int(n.truncatingRemainder(dividingBy: 36))
                intStr = String(digits[digit]) + intStr
                n = floor(n / 36)
            }
        }

        // Fractional portion. JavaScript's Number.prototype.toString stops once
        // additional digits would not round-trip; ~30 digits is more than enough.
        var fracStr = ""
        if fracPart > 0 {
            for _ in 0..<30 {
                fracPart *= 36
                let digit = Int(floor(fracPart))
                fracStr.append(digits[digit])
                fracPart -= Double(digit)
                if fracPart == 0 { break }
            }
        }

        let body = fracStr.isEmpty ? intStr : "\(intStr).\(fracStr)"
        return negative ? "-\(body)" : body
    }
}
