import XCTest
@testable import CLIP

/// Exercises CanvasStore's save/load guards in isolation via `rootOverride`.
/// Every test points storage at a fresh temp dir and resets the in-memory
/// memo/flag state — never touches the real Application Support folder.
final class PersistenceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIPTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        CanvasStore.rootOverride = tempDir
        CanvasStore.resetForTesting()
    }

    override func tearDown() {
        CanvasStore.rootOverride = nil
        CanvasStore.resetForTesting()
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func snapshot(pageName: String) -> CanvasSnapshot {
        let page = Page(name: pageName)
        return CanvasSnapshot(pages: [page], activePageID: page.id)
    }

    // MARK: - Identical-snapshot save skip

    func testIdenticalSnapshotSaveIsSkipped() throws {
        let snap = snapshot(pageName: "A")
        try CanvasStore.save(snap)

        // Mutate the file's mtime to a distinguishable marker so a later
        // no-op save is provable: if save() re-writes the file, the mtime
        // moves forward from this marker.
        let marker = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: marker], ofItemAtPath: CanvasStore.fileURL.path)

        try CanvasStore.save(snap) // identical snapshot — should be a no-op

        let attrs = try FileManager.default.attributesOfItem(atPath: CanvasStore.fileURL.path)
        XCTAssertEqual(attrs[.modificationDate] as? Date, marker,
                        "save() with an unchanged snapshot must not touch the file")
    }

    // MARK: - Zero-page snapshot refusal

    func testZeroPageSnapshotIsRefusedWhenNoFileExists() throws {
        let empty = CanvasSnapshot(pages: [], activePageID: UUID())
        try CanvasStore.save(empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CanvasStore.fileURL.path),
                        "a zero-page snapshot must never be written to disk")
    }

    func testZeroPageSnapshotDoesNotClobberExistingGoodData() throws {
        let good = snapshot(pageName: "good")
        try CanvasStore.save(good)
        let before = try Data(contentsOf: CanvasStore.fileURL)

        let empty = CanvasSnapshot(pages: [], activePageID: UUID())
        try CanvasStore.save(empty) // different from lastSaved, so passes the identical-guard...

        let after = try Data(contentsOf: CanvasStore.fileURL)
        XCTAssertEqual(before, after, "refusing a zero-page snapshot must leave prior good data intact")
    }

    // MARK: - Corrupt-JSON load

    func testCorruptJSONLoadReturnsNilAndLeavesBackup() throws {
        try FileManager.default.createDirectory(
            at: CanvasStore.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not valid json".utf8).write(to: CanvasStore.fileURL)

        let loaded = CanvasStore.load()
        XCTAssertNil(loaded)

        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: CanvasStore.fileURL.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("canvas.json.corrupt-") },
                      "a corrupt file must be preserved next to the original")
    }

    // MARK: - Legacy-media pre-migration backup (created exactly once)

    func testLegacyMediaFlagCreatesPreMigrationBackupExactlyOnce() throws {
        let snapA = snapshot(pageName: "A")
        try CanvasStore.save(snapA)

        CanvasStore.noteLegacyEmbeddedMedia()
        let snapB = snapshot(pageName: "B")
        try CanvasStore.save(snapB) // flag armed: should back up A's bytes first

        let backupURL = CanvasStore.fileURL.appendingPathExtension("pre-media-backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        let backedUp = try JSONDecoder().decode(CanvasSnapshot.self, from: Data(contentsOf: backupURL))
        XCTAssertEqual(backedUp.pages.first?.name, "A", "backup must hold the pre-migration document")

        // Flag is one-shot: a later save must not touch (or re-create) the backup.
        let snapC = snapshot(pageName: "C")
        try CanvasStore.save(snapC)
        let stillBackedUp = try JSONDecoder().decode(CanvasSnapshot.self, from: Data(contentsOf: backupURL))
        XCTAssertEqual(stillBackedUp.pages.first?.name, "A",
                       "the one-time backup must not be overwritten by subsequent saves")
    }
}
