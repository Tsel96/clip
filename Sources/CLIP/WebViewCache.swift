import WebKit

/// Feature flags for experimental paths that default OFF (verify on a running
/// app before enabling).
enum FeatureFlags {
    /// Reuse `WKWebView`s across remounts to kill the "cards blink/reload on
    /// select" bug. Default OFF — verify it stops the blink AND doesn't leak /
    /// play audio in the background, then flip on. Currently wired into
    /// `WebClipWebView` as a proof of concept; extend to YouTube/Instagram once
    /// confirmed.
    static let useWebViewCache = false
}

/// Caches `WKWebView`s by node id so a quick remount (e.g. a selection
/// re-render recreating the representable — the suspected "blink" cause) reuses
/// the live instance instead of recreating + reloading it. On dismantle the
/// teardown is DEFERRED ~1.2 s and cancelled if the node reappears — so a
/// select-remount reuses the warm view, while a genuine removal (scrolled far
/// away / deleted) still tears down, avoiding background playback / leaks.
final class WebViewCache {
    static let shared = WebViewCache()
    private init() {}

    private var views: [UUID: WKWebView] = [:]
    private var teardowns: [UUID: Timer] = [:]

    /// Returns the cached web view for `id`, or builds + stores one. Cancels any
    /// pending teardown (the node came back).
    func webView(for id: UUID, create: () -> WKWebView) -> WKWebView {
        teardowns[id]?.invalidate()
        teardowns[id] = nil
        if let existing = views[id] { return existing }
        let view = create()
        views[id] = view
        return view
    }

    /// Schedule a deferred teardown — cancelled if the node remounts first.
    func scheduleTeardown(for id: UUID) {
        teardowns[id]?.invalidate()
        teardowns[id] = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self else { return }
            if let view = self.views[id] {
                view.stopLoading()
                view.loadHTMLString("", baseURL: nil)
                view.navigationDelegate = nil
            }
            self.views[id] = nil
            self.teardowns[id] = nil
        }
    }

    /// Force-evict (e.g. on node deletion) — tears down immediately.
    func evict(_ id: UUID) {
        teardowns[id]?.invalidate(); teardowns[id] = nil
        if let view = views[id] {
            view.stopLoading()
            view.loadHTMLString("", baseURL: nil)
            view.navigationDelegate = nil
        }
        views[id] = nil
    }
}
