import Foundation

/// On-disk snapshot of everything that should survive a quit: every page
/// (which already carries its own nodes / connectors / camera) plus the
/// active-page id so the user reopens on the same page.
struct CanvasSnapshot: Codable, Equatable {
    var pages: [Page]
    var activePageID: UUID
}

/// Atomic JSON read/write for `CanvasSnapshot`. Storage lives at
/// `~/Library/Application Support/CLIP/canvas.json`.
/// There is intentionally no Save / Open UI — `CanvasState` auto-saves on
/// every change (debounced) and loads on launch.
enum CanvasStore {

    private static let folderName       = "CLIP"
    /// Pre-rename folder ("Embedded Video Canvas"); migrated on first launch.
    private static let legacyFolderName = "EmbeddedVideoCanvas"
    private static let fileName         = "canvas.json"

    private static var supportDir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    static var fileURL: URL {
        supportDir
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// One-time move of the pre-rename data folder to the new `CLIP` folder,
    /// so an existing canvas survives the app rename. No-op once migrated.
    private static func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        let newURL = fileURL
        guard !fm.fileExists(atPath: newURL.path) else { return }
        let legacyURL = supportDir
            .appendingPathComponent(legacyFolderName, isDirectory: true)
            .appendingPathComponent(fileName)
        guard fm.fileExists(atPath: legacyURL.path) else { return }
        try? fm.createDirectory(at: newURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        try? fm.copyItem(at: legacyURL, to: newURL)
    }

    /// Attempt to read the on-disk snapshot. Returns nil for any reason
    /// (file missing, corrupt, schema mismatch) — the caller bootstraps a
    /// fresh default state in that case.
    static func load() -> CanvasSnapshot? {
        migrateLegacyIfNeeded()
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CanvasSnapshot.self, from: data)
        } catch {
            // Silently swallow — better to start fresh than crash on a
            // schema change between versions.
            return nil
        }
    }

    /// Atomically write the snapshot to disk, creating the support
    /// directory if it doesn't exist yet.
    static func save(_ snapshot: CanvasSnapshot) throws {
        let url = fileURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}
