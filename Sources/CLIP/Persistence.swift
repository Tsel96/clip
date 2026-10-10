import Foundation
import os

/// On-disk snapshot of everything that should survive a quit: every page
/// (which already carries its own nodes / connectors / camera) plus the
/// active-page id so the user reopens on the same page.
struct CanvasSnapshot: Codable, Equatable {
    var pages: [Page]
    var activePageID: UUID

    init(pages: [Page], activePageID: UUID) {
        self.pages = pages
        self.activePageID = activePageID
    }

    private enum CodingKeys: String, CodingKey { case pages, activePageID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pages = try c.decode([LossyElement<Page>].self, forKey: .pages).compactMap(\.value)
        activePageID = try c.decodeIfPresent(UUID.self, forKey: .activePageID)
            ?? pages.first?.id ?? UUID()
    }
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
    /// fresh default state in that case. An unreadable file is preserved
    /// next to the original as `canvas.json.corrupt-<timestamp>` so the
    /// user's data is recoverable instead of silently discarded.
    static func load() -> CanvasSnapshot? {
        migrateLegacyIfNeeded()
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            LossyDecodeCounter.dropped = 0
            let snapshot = try JSONDecoder().decode(CanvasSnapshot.self, from: data)
            if LossyDecodeCounter.dropped > 0 {
                // Partial load: keep the untouched original before the next
                // autosave rewrites the file without the skipped entries.
                let backup = backupCopy(of: url, tag: "partial")
                Log.persistence.error("Canvas loaded with \(LossyDecodeCounter.dropped) unreadable entries skipped (original kept at \(backup, privacy: .public))")
            }
            return snapshot
        } catch {
            // Don't crash on a schema change between versions — start
            // fresh, but keep the old file around and leave a trace.
            let backup = backupCopy(of: url, tag: "corrupt")
            Log.persistence.error("Canvas load failed, starting fresh (original kept at \(backup, privacy: .public)): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Copy `url` to `<name>.<tag>-<timestamp>` and return the new file name.
    private static func backupCopy(of url: URL, tag: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let backup = url.appendingPathExtension("\(tag)-\(fmt.string(from: Date()))")
        try? FileManager.default.copyItem(at: url, to: backup)
        return backup.lastPathComponent
    }

    /// Serial queue for background writes: keeps saves ordered while the
    /// JSON encode + image-blob hashing stays off the main thread.
    private static let saveQueue = DispatchQueue(label: "clip.canvas.save", qos: .utility)

    /// Encode + write on the background save queue. Used by the debounced
    /// auto-save pipeline so a large document never hitches the UI.
    /// Failures are logged, never surfaced — persistence is best-effort.
    static func saveAsync(_ snapshot: CanvasSnapshot) {
        saveQueue.async {
            do {
                try save(snapshot)
            } catch {
                Log.persistence.error("Canvas save failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Blocking write for the at-quit flush. Runs on the same serial
    /// queue as `saveAsync`, so it lands strictly after any in-flight
    /// background save (an older snapshot can never clobber this one)
    /// and returns only once the file is on disk.
    static func saveSync(_ snapshot: CanvasSnapshot) {
        saveQueue.sync {
            do {
                try save(snapshot)
            } catch {
                Log.persistence.error("Canvas flush at quit failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Atomically write the snapshot to disk, creating the support
    /// directory if it doesn't exist yet. Auto-save goes through
    /// `saveAsync`; the at-quit flush through `saveSync`.
    static func save(_ snapshot: CanvasSnapshot) throws {
        let url = fileURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        // Image bytes go to content-addressed blobs (written before the JSON
        // that references them); the JSON itself stays small.
        let blobs = try ImageBlobWriter()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.userInfo[ImageBlobStore.userInfoKey] = blobs
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        blobs.removeUnreferenced()
    }
}
