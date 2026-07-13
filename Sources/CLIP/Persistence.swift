import Foundation
import os

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

    /// Test seam: when set, canvas.json lives under this directory instead
    /// of the real Application Support folder. Never set in production.
    static var rootOverride: URL?

    static var fileURL: URL {
        (rootOverride ?? supportDir.appendingPathComponent(folderName, isDirectory: true))
            .appendingPathComponent(fileName)
    }

    /// Test seam: clear the skip-if-identical memo and the one-time
    /// migration flag so test cases don't leak state into each other.
    static func resetForTesting() {
        saveQueue.sync { lastSaved = nil }
        legacyEmbeddedMediaSeen = false
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
            return try JSONDecoder().decode(CanvasSnapshot.self, from: data)
        } catch {
            // Don't crash on a schema change between versions — start
            // fresh, but keep the old file around and leave a trace.
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let backup = url.appendingPathExtension(
                "corrupt-\(fmt.string(from: Date()))")
            try? FileManager.default.copyItem(at: url, to: backup)
            Log.persistence.error("Canvas load failed, starting fresh (original kept at \(backup.lastPathComponent, privacy: .public)): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Serial queue for background writes: keeps saves ordered while the
    /// (potentially large — image bytes are embedded) JSON encode stays
    /// off the main thread.
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

    /// The last snapshot successfully written. Both entry points run on
    /// `saveQueue`, so access is serialized without a lock.
    private static var lastSaved: CanvasSnapshot?

    /// Set during decode when legacy base64-embedded image bytes were seen
    /// (R10 migration): the next save rewrites the document in the
    /// externalized-media format, so it backs up canvas.json first, once.
    /// (Written on the load path at launch, read later on `saveQueue`.)
    private static var legacyEmbeddedMediaSeen = false
    static func noteLegacyEmbeddedMedia() { legacyEmbeddedMediaSeen = true }

    /// Atomically write the snapshot to disk, creating the support
    /// directory if it doesn't exist yet. Auto-save goes through
    /// `saveAsync`; the at-quit flush through `saveSync`.
    static func save(_ snapshot: CanvasSnapshot) throws {
        // Skip identical writes: the ~15 s crash-flush and the camera
        // throttle re-save unchanged documents — the disk already has
        // these bytes, and the compare is cheaper than encode + write.
        guard snapshot != lastSaved else { return }
        // The model invariant is ≥1 page; a zero-page snapshot is corruption,
        // never a real document. Refuse to write it so a transient bad state
        // can't clobber the user's canvas (the on-disk `.empty-backup` shows
        // this has happened). A page with zero NODES is still legitimate
        // (a fresh / cleared canvas) and is allowed through.
        guard !snapshot.pages.isEmpty else {
            Log.persistence.error("Refusing to persist a zero-page snapshot (would clobber good data)")
            return
        }
        let url = fileURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        // One-time R10 migration backup: this save externalizes the legacy
        // embedded image bytes, so keep the pre-migration document around.
        if legacyEmbeddedMediaSeen {
            legacyEmbeddedMediaSeen = false
            let backup = url.appendingPathExtension("pre-media-backup")
            if FileManager.default.fileExists(atPath: url.path),
               !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: url, to: backup)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        lastSaved = snapshot
    }
}
