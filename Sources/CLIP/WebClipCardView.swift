import SwiftUI
import WebKit
import AppKit

/// Generic web clip card for any HTTP(S) URL.
///
/// Uses `WKWebView` to render the website. Like `InstagramCardView`, it
/// supports semantic zoom: when below the live-playback breakpoint or
/// off-screen, falls back to a cached snapshot (if available) or a
/// globe+host placeholder, and tears the WKWebView down to save memory.
///
/// On successful navigation, captures a PNG snapshot and saves it to
/// `WebClipSnapshotStore` for use as the resting-state poster.
struct WebClipCardView: View {
    let url: String
    /// Live iff the card intersects the viewport AND is projected at
    /// ≥ `livePlaybackMinScreenSide`. Default true keeps test sites unaffected.
    var isLive: Bool = true
    /// While true (camera zooming), force the cached-snapshot poster instead of
    /// the live `WKWebView`. WebKit is NSView-backed, so it renders black under
    /// SwiftUI's `.scaleEffect` zoom transform (and composites above any SwiftUI
    /// cover) — the snapshot is a plain bitmap that scales cleanly.
    var suppressLive: Bool = false
    let nodeID: UUID

    @State private var hovering = false
    @State private var isLoading = true
    @State private var didFail = false
    @State private var cachedSnapshot: NSImage?
    @State private var hostLabel: String = ""

    var body: some View {
        ZStack {
            if let url = URL(string: url) {
                if isLive && !suppressLive {
                    WebClipWebView(
                        url: url,
                        nodeID: nodeID,
                        isLoading: $isLoading,
                        didFail: $didFail,
                        cachedSnapshot: $cachedSnapshot
                    )
                    .allowsHitTesting(false)

                    if isLoading && !didFail {
                        ProgressView().controlSize(.small)
                    }

                    if didFail {
                        VStack(spacing: 6) {
                            Image(systemName: "exclamationmark.bubble")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Text("Couldn't load page")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                } else {
                    posterFallback
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "link.badge.plus")
                        .font(.title3).foregroundStyle(.secondary)
                    Text("Invalid URL")
                        .font(.callout).bold()
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .figmaCardStyle(isElevated: hovering)
        .onHover { hovering = $0 }
        .onAppear {
            extractHostLabel()
            loadCachedSnapshot()
        }
    }

    @ViewBuilder
    private var posterFallback: some View {
        if let snapshot = cachedSnapshot {
            Image(nsImage: snapshot)
                .resizable()
                .scaledToFill()
                .clipped()
        } else {
            VStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                if !hostLabel.isEmpty {
                    Text(hostLabel)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func extractHostLabel() {
        if let url = URL(string: url),
           let host = url.host {
            hostLabel = host.replacingOccurrences(of: "www.", with: "")
        }
    }

    private func loadCachedSnapshot() {
        Task {
            cachedSnapshot = await WebClipSnapshotStore.shared.image(for: nodeID)
        }
    }
}

// MARK: - WebKit bridge

struct WebClipWebView: NSViewRepresentable {
    let url: URL
    let nodeID: UUID
    @Binding var isLoading: Bool
    @Binding var didFail: Bool
    @Binding var cachedSnapshot: NSImage?

    /// Shared WebKit process pool across all web clip cards.
    private static let sharedProcessPool = WKProcessPool()

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.processPool = Self.sharedProcessPool
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Desktop User-Agent so sites render their full experience
        // (not mobile-optimized).
        cfg.applicationNameForUserAgent = "Version/1.0 Safari (macOS)"

        let webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = context.coordinator
        webView.layer?.masksToBounds = true
        webView.load(URLRequest(url: url))
        return webView
    }

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
        Coordinator(
            nodeID: nodeID,
            isLoading: $isLoading,
            didFail: $didFail,
            cachedSnapshot: $cachedSnapshot
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let nodeID: UUID
        @Binding var isLoading: Bool
        @Binding var didFail: Bool
        @Binding var cachedSnapshot: NSImage?

        init(nodeID: UUID,
             isLoading: Binding<Bool>,
             didFail: Binding<Bool>,
             cachedSnapshot: Binding<NSImage?>) {
            self.nodeID = nodeID
            self._isLoading = isLoading
            self._didFail = didFail
            self._cachedSnapshot = cachedSnapshot
        }

        func webView(_ webView: WKWebView,
                     didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.isLoading = true
                self.didFail = false
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.isLoading = false
            }
            takeSnapshot(of: webView)
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            DispatchQueue.main.async {
                self.isLoading = false
                self.didFail = true
            }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            DispatchQueue.main.async {
                self.isLoading = false
                self.didFail = true
            }
        }

        private func takeSnapshot(of webView: WKWebView) {
            let config = WKSnapshotConfiguration()
            config.rect = webView.bounds
            webView.takeSnapshot(with: config) { image, error in
                guard let image else { return }
                Task {
                    await WebClipSnapshotStore.shared.save(image, for: self.nodeID)
                    DispatchQueue.main.async {
                        self.cachedSnapshot = image
                    }
                }
            }
        }
    }
}
