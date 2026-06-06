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
    @MainActor
    static func handle(providers: [NSItemProvider],
                       at world: CGPoint,
                       state: CanvasState) -> Bool {

        // Prefer the file-URL representation when present (Finder drops, image
        // and video files dragged from anywhere on disk).
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        if !fileProviders.isEmpty {
            for provider in fileProviders {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        handleURL(url, at: world, state: state)
                    }
                }
            }
            return true
        }

        // Plain text (URL serialised as a string from address bars, Notes, …).
        let textProviders = providers.filter {
            $0.canLoadObject(ofClass: NSString.self)
        }
        if !textProviders.isEmpty {
            for provider in textProviders {
                _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let s = obj as? String else { return }
                    Task { @MainActor in
                        state.addPostFromURL(s, at: world)
                    }
                }
            }
            return true
        }

        return false
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
