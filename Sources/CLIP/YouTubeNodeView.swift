import SwiftUI
import WebKit
import AppKit

/// YouTube video card. When "live" it embeds the player via `WKWebView`
/// (muted autoplay, inline) and is non-interactive so the whole card drags
/// through `DraggableNode`'s gesture. Below the live breakpoint, off-screen,
/// or under the videos-as-preview toggle it falls back to the static
/// thumbnail poster and tears the web view down — the same semantic-zoom
/// lifecycle `InstagramCardView` / `VideoNodeView` use.
struct YouTubeNodeView: View {
    let url: String
    /// Live iff the card intersects the viewport AND is projected at a
    /// large-enough size (and the user hasn't forced previews-only).
    var isLive: Bool = true
    /// While true (camera zooming), force the thumbnail poster instead of the
    /// live `WKWebView` — WebKit renders black under SwiftUI's zoom transform.
    var suppressLive: Bool = false

    @State private var hovering = false
    @State private var isLoading = true
    @State private var didFail = false

    var body: some View {
        ZStack {
            if YouTubeService.embedURL(from: url) != nil {
                if isLive && !suppressLive, let embedURL = YouTubeService.embedURL(from: url) {
                    YouTubeWebView(url: embedURL, isLoading: $isLoading, didFail: $didFail)
                        // Non-interactive so the whole card surface drags via
                        // DraggableNode (WKWebView would otherwise eat events).
                        .allowsHitTesting(false)

                    // Keep the poster underneath until the player paints, so
                    // there's never a black flash on (re)mount.
                    if isLoading && !didFail {
                        posterFallback
                        ProgressView().controlSize(.small)
                    }
                    if didFail { posterFallback }
                } else {
                    posterFallback
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "link.badge.plus")
                        .font(.title3).foregroundStyle(.secondary)
                    Text("Invalid YouTube URL")
                        .font(.callout).bold()
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .figmaCardStyle(isElevated: hovering)
        .onHover { hovering = $0 }
    }

    /// Static, allocation-free resting state — the YouTube thumbnail with a
    /// play glyph. No WKWebView in the tree.
    @ViewBuilder
    private var posterFallback: some View {
        ZStack {
            if let poster = YouTubeService.posterURL(from: url) {
                AsyncImage(url: poster) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color(nsColor: .windowBackgroundColor)
                    }
                }
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
            Image(systemName: "play.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

// MARK: - WebKit bridge

struct YouTubeWebView: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var didFail: Bool

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = context.coordinator
        webView.layer?.masksToBounds = true
        webView.load(URLRequest(url: url))
        return webView
    }

    /// Release every WebKit-side resource when SwiftUI removes the view
    /// (page switch, deletion, semantic-zoom poster fallback).
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.loadHTMLString("", baseURL: nil)
        nsView.navigationDelegate = nil
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, didFail: $didFail)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        @Binding var didFail: Bool

        init(isLoading: Binding<Bool>, didFail: Binding<Bool>) {
            self._isLoading = isLoading
            self._didFail = didFail
        }

        func webView(_ webView: WKWebView,
                     didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.isLoading = true; self.didFail = false }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.isLoading = false }
        }
        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.isLoading = false; self.didFail = true }
        }
        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.isLoading = false; self.didFail = true }
        }
    }
}
