import SwiftUI
import WebKit
import AppKit

/// Instagram post / reel / IGTV card.
///
/// Uses `WKWebView` pointed at IG's `/embed/captioned` URL — which is the
/// closest public counterpart to Twitter's syndication JSON. WKWebView is a
/// real WebKit renderer, so it captures its own mouse events; we therefore
/// expose a small "Instagram" title bar at the top that the parent
/// `DraggableNode`'s `DragGesture` can grab.
///
/// **Semantic-zoom lifecycle.** A WKWebView holds a full WebKit content
/// process (~150 MB+ on macOS 14). When the card is below the live-
/// playback breakpoint or off-screen, this view falls back to a static
/// poster and tears the web view down — five Instagram cards on a 10%-
/// zoomed-out canvas should *not* spawn five WebKit workers. Mirrors the
/// semantic-zoom mechanic that `TweetCardView` / `VideoNodeView` use.
struct InstagramCardView: View {
    let url: String
    /// Same flag the video paths consume: live iff the card intersects the
    /// viewport AND is projected at ≥ `livePlaybackMinScreenSide`. Default
    /// true keeps preview/test sites that don't pass the prop unaffected.
    var isLive: Bool = true

    @State private var hovering = false
    @State private var isLoading = true
    @State private var didFail = false

    var body: some View {
        ZStack {
            if let embedURL = InstagramService.embedURL(from: url) {
                if isLive {
                    InstagramWebView(
                        url: embedURL,
                        isLoading: $isLoading,
                        didFail: $didFail
                    )
                    // Make the WebView non-interactive so the entire card
                    // surface drags via DraggableNode's DragGesture (otherwise
                    // WKWebView eats every mouse event). Video still autoplays
                    // muted via the JS shim injected into the embed.
                    .allowsHitTesting(false)

                    if isLoading && !didFail {
                        ProgressView().controlSize(.small)
                    }

                    if didFail {
                        VStack(spacing: 6) {
                            Image(systemName: "exclamationmark.bubble")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            Text("Couldn't load post")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                } else {
                    // Static poster when below the live breakpoint /
                    // off-screen. The WKWebView is unmounted by SwiftUI's
                    // tree diff, triggering `dismantleNSView` to release
                    // the WebKit process. When the user zooms back in,
                    // the web view re-mounts onto the shared process pool.
                    posterFallback
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "link.badge.plus")
                        .font(.title3).foregroundStyle(.secondary)
                    Text("Invalid Instagram URL")
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

    /// Resting state for a card that's not currently "live". Static,
    /// allocation-free — no WKWebView in the tree.
    @ViewBuilder
    private var posterFallback: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("Instagram")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - WebKit bridge

struct InstagramWebView: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var didFail: Bool

    /// One WebKit content-process pool shared across every Instagram card
    /// on the canvas. Without this, each `WKWebView` spawns its own
    /// `com.apple.WebKit.WebContent` worker (~150 MB+ on macOS 14); five
    /// cards = five workers. With the pool, all cards share one worker
    /// when WebKit can coalesce, which it does for same-origin loads.
    private static let sharedProcessPool = WKProcessPool()

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.processPool = Self.sharedProcessPool
        cfg.allowsAirPlayForMediaPlayback = true
        // Browser-level permission: don't require a user click for media.
        cfg.mediaTypesRequiringUserActionForPlayback = []
        // Inject the autoplay shim BEFORE Instagram's own embed JS runs the
        // "click-to-play" gate. The shim watches the DOM and forces .play()
        // on whatever <video> IG drops in.
        cfg.userContentController.addUserScript(WKUserScript(
            source: Self.autoplayShim,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false   // also runs inside IG's nested iframe
        ))

        let webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = context.coordinator
        webView.layer?.masksToBounds = true
        webView.load(URLRequest(url: url))
        return webView
    }

    /// When SwiftUI removes this representable from the tree (page switch,
    /// card deletion, semantic-zoom poster fallback), release every
    /// WebKit-side resource we own: stop network, blank the DOM (drops
    /// cached JS + <video> decoders), and break the navigation delegate
    /// retain cycle.
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.loadHTMLString("", baseURL: nil)
        nsView.navigationDelegate = nil
    }

    /// JS shim that forces autoplay on any <video> Instagram's embed renders.
    /// Strategy:
    ///   • Find every <video>, mute + loop it, set playsinline, call play().
    ///   • Run once at document_end, then keep retrying on a short interval
    ///     and via MutationObserver because IG hydrates the player after the
    ///     initial DOM is in place.
    ///   • Muted autoplay is the only flavour WebKit allows without a user
    ///     gesture — matches our Twitter card behaviour (Twitter videos also
    ///     start muted).
    private static let autoplayShim: String = """
    (function() {
        function kick() {
            var vids = document.getElementsByTagName('video');
            var any = false;
            for (var i = 0; i < vids.length; i++) {
                var v = vids[i];
                try {
                    v.muted = true;
                    v.loop = true;
                    v.autoplay = true;
                    v.setAttribute('playsinline', '');
                    v.setAttribute('webkit-playsinline', '');
                    var p = v.play();
                    if (p && typeof p.catch === 'function') { p.catch(function(){}); }
                    any = true;
                } catch (e) {}
            }
            return any;
        }

        // Initial attempt.
        kick();

        // React to DOM additions (IG injects the player late).
        try {
            var obs = new MutationObserver(function() { kick(); });
            var start = function() {
                if (document.body) {
                    obs.observe(document.body, { childList: true, subtree: true });
                }
            };
            if (document.body) start();
            else document.addEventListener('DOMContentLoaded', start);
        } catch (e) {}

        // Belt-and-suspenders retry loop for ~5 s.
        var n = 0;
        var iv = setInterval(function() {
            kick();
            if (++n > 20) clearInterval(iv);
        }, 250);
    })();
    """

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
            DispatchQueue.main.async {
                self.isLoading = true
                self.didFail = false
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.isLoading = false
            }
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
    }
}
