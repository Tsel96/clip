import Foundation
import AppKit

/// Off-canvas PNG snapshot cache for web clips. Persists screenshots at
/// `~/Library/Application Support/CLIP/webclips/<nodeID>.png` so the card
/// can show a static image when below the live-playback breakpoint,
/// without re-rendering the WKWebView.
///
/// Writes happen off-main to avoid blocking the render loop.
actor WebClipSnapshotStore {
    static let shared = WebClipSnapshotStore()

    private let cacheDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        self.cacheDirectory = appSupport.appendingPathComponent("CLIP/webclips")
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Retrieve a cached snapshot, or nil if not found / not readable.
    func image(for nodeID: UUID) async -> NSImage? {
        let url = cacheDirectory.appendingPathComponent("\(nodeID).png")
        return await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let img = NSImage(data: data) else {
                return nil
            }
            return img
        }.value
    }

    /// Save a snapshot asynchronously. Silently fails if write cannot complete.
    func save(_ image: NSImage, for nodeID: UUID) async {
        let url = cacheDirectory.appendingPathComponent("\(nodeID).png")
        await Task.detached(priority: .userInitiated) {
            guard let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?
                    .representation(using: .png, properties: [:]) else {
                return
            }
            try? png.write(to: url)
        }.value
    }

    /// Remove a snapshot. Silently fails if not found.
    func remove(for nodeID: UUID) async {
        let url = cacheDirectory.appendingPathComponent("\(nodeID).png")
        await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }
}
