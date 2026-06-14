import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Drop-target glue for `CanvasView`. Accepts:
///   • image / movie file URLs from Finder → routes to `addImage` / `addVideo`
///     (re-using the existing Figma-style size + duration limits).
///   • text URL drops (Safari, Notes, etc.) → `addPostFromURL` (Twitter / IG).
///
/// Drops always reference the cursor's location at drop time (in canvas
/// coordinates), so the new card lands where the user actually let go.
enum CanvasDrop {

    static let supportedTypes: [UTType] = [
        .fileURL,
        .image,
        .movie,
        .url,
        .plainText,
    ]

    /// Called from `.onDrop(of:isTargeted:)` with the cursor position
    /// already converted to world coordinates. Returns `true` if at least
    /// one provider was claimed.
    ///
    /// NOTE: `canLoadObject(ofClass: URL.self)` returns false for Finder
    /// file drags on macOS (an AppKit/SwiftUI gap — it works on iOS), so
    /// file URLs are loaded via `loadItem(forTypeIdentifier:)` and
    /// reconstructed from their data representation.
    @MainActor
    static func handle(providers: [NSItemProvider],
                       at world: CGPoint,
                       state: CanvasState) -> Bool {
        var claimed = false

        for provider in providers {
            // 1. File URLs (Finder, Desktop, Photos exports…).
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                claimed = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier,
                                  options: nil) { item, _ in
                    guard let url = Self.url(from: item) else { return }
                    Task { @MainActor in handleURL(url, at: world, state: state) }
                }
                continue
            }
            // 2. Web URLs (Safari address bar, links dragged off pages).
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                claimed = true
                provider.loadItem(forTypeIdentifier: UTType.url.identifier,
                                  options: nil) { item, _ in
                    guard let url = Self.url(from: item) else { return }
                    Task { @MainActor in handleURL(url, at: world, state: state) }
                }
                continue
            }
            // 3. Raw image data (drags from browsers/apps that hand over
            //    bitmap data without any backing file).
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                claimed = true
                provider.loadDataRepresentation(
                    forTypeIdentifier: UTType.image.identifier
                ) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        state.addImage(data: data, filename: "Dropped image", at: world)
                    }
                }
                continue
            }
            // 4. Plain text (URL serialised as a string from Notes, etc.).
            if provider.canLoadObject(ofClass: NSString.self) {
                claimed = true
                _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let s = obj as? String else { return }
                    Task { @MainActor in
                        state.addPostFromURL(s, at: world)
                    }
                }
            }
        }
        return claimed
    }

    /// `loadItem` hands back different shapes depending on the source app:
    /// a URL, its data representation, or a string. Accept all three.
    private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let s = item as? String { return URL(string: s) }
        return nil
    }

    /// Dispatch a single URL — file or web — to the right `CanvasState` add-method.
    @MainActor
    private static func handleURL(_ url: URL,
                                   at world: CGPoint,
                                   state: CanvasState) {
        if url.isFileURL {
            let ext = url.pathExtension.lowercased()
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif",
                                          "gif", "webp", "tiff", "tif", "bmp"]
            let videoExts: Set<String> = ["mp4", "mov", "m4v", "qt"]
            if imageExts.contains(ext) {
                guard let data = try? Data(contentsOf: url) else { return }
                state.addImage(data: data, filename: url.lastPathComponent, at: world)
            } else if videoExts.contains(ext) {
                state.addVideo(fileURL: url, at: world)
            } else {
                // Unknown file type — treat as a URL-paste fallback.
                state.addPostFromURL(url.absoluteString, at: world)
            }
        } else {
            state.addPostFromURL(url.absoluteString, at: world)
        }
    }
}
