import XCTest
@testable import CLIP

/// Covers MediaStore's two independent hashing paths (buffered `store` vs.
/// streamed `importFile`), the repeat-store no-op, and the path-traversal
/// guard on `url(for:)`. Storage is relocated to a temp dir via
/// `dirOverride` — never touches the real Application Support folder.
final class MediaStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIPTests-media-\(UUID().uuidString)", isDirectory: true)
        MediaStore.dirOverride = tempDir
    }

    override func tearDown() {
        MediaStore.dirOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - store() and importFile() agree on the hash

    func testStoreAndImportFileProduceSameHashPrefixForIdenticalBytes() throws {
        let data = Data("clip test payload \(UUID())".utf8)

        let srcFile = tempDir.appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try data.write(to: srcFile)

        let importedURL = MediaStore.importFile(srcFile)
        let storedName = try MediaStore.store(data, ext: "png")

        XCTAssertEqual(importedURL.lastPathComponent, storedName,
                       "buffered store() and streamed importFile() must content-address identically")
    }

    // MARK: - Repeat store is a no-op

    func testRepeatStoreDoesNotRewriteExistingFile() throws {
        let data = Data("no-op check \(UUID())".utf8)
        let name = try MediaStore.store(data, ext: "bin")

        // Overwrite the on-disk bytes with a sentinel directly, bypassing
        // MediaStore, so a second store() only leaves them intact if it
        // truly skips the write (content-addressing: same name already exists).
        let sentinel = Data("sentinel".utf8)
        try sentinel.write(to: MediaStore.url(for: name))

        let name2 = try MediaStore.store(data, ext: "bin")
        XCTAssertEqual(name, name2)
        XCTAssertEqual(try Data(contentsOf: MediaStore.url(for: name)), sentinel,
                       "repeat store() with identical bytes must not rewrite the existing file")
    }

    // MARK: - Path-traversal names resolve inside the store dir

    func testURLForRejectsPathLikeNames() {
        let traversal = MediaStore.url(for: "../../etc/passwd")
        XCTAssertEqual(traversal.deletingLastPathComponent().standardizedFileURL,
                       tempDir.standardizedFileURL)
        XCTAssertEqual(traversal.lastPathComponent, "invalid-media-name")

        let slash = MediaStore.url(for: "/etc/passwd")
        XCTAssertEqual(slash.lastPathComponent, "invalid-media-name")

        let tilde = MediaStore.url(for: "~/secrets")
        XCTAssertEqual(tilde.lastPathComponent, "invalid-media-name")

        // A legitimate content-addressed name resolves normally, inside the store dir.
        let ok = MediaStore.url(for: "abcd1234.png")
        XCTAssertEqual(ok, tempDir.appendingPathComponent("abcd1234.png"))
    }
}
