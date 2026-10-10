import XCTest
@testable import CLIP

final class PersistenceTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        // Never let a test read or delete the real Application Support data.
        ImageBlobStore.rootOverride = tempRoot
    }

    override func tearDownWithError() throws {
        ImageBlobStore.rootOverride = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func textNode(_ content: String) -> CanvasNode {
        CanvasNode(position: .zero, width: 200, height: 80,
                   kind: .text(content: content, fontSize: 16))
    }

    private func imageNode(_ bytes: Data) -> CanvasNode {
        CanvasNode(position: .zero, width: 100, height: 100,
                   kind: .image(data: bytes, filename: "a.png"))
    }

    // MARK: - Lossy decoding

    func testUnknownNodeKindIsSkippedNotFatal() throws {
        let page = Page(name: "P", nodes: [textNode("keep"), textNode("drop")])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as! [String: Any]
        var nodes = json["nodes"] as! [[String: Any]]
        var kind = nodes[1]["kind"] as! [String: Any]
        kind["type"] = "kind-from-the-future"
        nodes[1]["kind"] = kind
        json["nodes"] = nodes

        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Page.self, from: data)

        XCTAssertEqual(decoded.nodes.count, 1)
        XCTAssertEqual(decoded.nodes.first?.id, page.nodes[0].id)
    }

    func testBadPageIsSkippedButOthersLoad() throws {
        let good = Page(name: "Good", nodes: [textNode("x")])
        let snapshot = CanvasSnapshot(pages: [good], activePageID: good.id)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        var pages = json["pages"] as! [Any]
        pages.append(["name": "no id or nodes"])           // damaged page entry
        json["pages"] = pages

        let decoded = try JSONDecoder().decode(
            CanvasSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.pages.map(\.id), [good.id])
    }

    // MARK: - Image blobs

    func testCanvasEncodingStoresImagesAsBlobs() throws {
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let page = Page(name: "P", nodes: [imageNode(bytes)])

        let writer = try ImageBlobWriter()
        let encoder = JSONEncoder()
        encoder.userInfo[ImageBlobStore.userInfoKey] = writer
        let json = try encoder.encode(page)
        let text = String(decoding: json, as: UTF8.self)

        XCTAssertTrue(text.contains("\"dataRef\""))
        XCTAssertFalse(text.contains("\"data\""), "image bytes must not be inlined in canvas.json")
        XCTAssertEqual(writer.referenced.count, 1)

        let decoded = try JSONDecoder().decode(Page.self, from: json)
        guard case .image(let roundTripped, _) = decoded.nodes.first?.kind else {
            return XCTFail("expected an image node")
        }
        XCTAssertEqual(roundTripped, bytes)
    }

    func testPlainEncodingStillInlinesImages() throws {
        // Clipboard payloads etc. don't opt in, so they stay self-contained.
        let bytes = Data([1, 2, 3, 4])
        let json = try JSONEncoder().encode(Page(name: "P", nodes: [imageNode(bytes)]))
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains("\"data\""))
        XCTAssertFalse(text.contains("\"dataRef\""))
        let decoded = try JSONDecoder().decode(Page.self, from: json)
        guard case .image(let roundTripped, _) = decoded.nodes.first?.kind else {
            return XCTFail("expected an image node")
        }
        XCTAssertEqual(roundTripped, bytes)
    }

    func testIdenticalImagesShareOneBlob() throws {
        let bytes = Data(repeating: 7, count: 1000)
        let writer = try ImageBlobWriter()
        let a = try writer.store(bytes)
        let b = try writer.store(bytes)
        XCTAssertEqual(a, b)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ImageBlobStore.directory.path).count, 1)
    }

    func testGarbageCollectionKeepsReferencedAndBackedUpBlobs() throws {
        let first = try ImageBlobWriter()
        let orphan = try first.store(Data([9, 9, 9]))
        let backedUp = try first.store(Data([8, 8, 8]))

        // A recovery backup that still points at `backedUp`.
        let backup = tempRoot.appendingPathComponent(CanvasStore.fileURL.lastPathComponent + ".corrupt-test")
        try Data("{\"dataRef\":\"\(backedUp)\"}".utf8).write(to: backup)

        let second = try ImageBlobWriter()
        let live = try second.store(Data([1, 1, 1]))
        second.removeUnreferenced()

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: ImageBlobStore.directory.path))
        XCTAssertTrue(remaining.contains(live))
        XCTAssertTrue(remaining.contains(backedUp))
        XCTAssertFalse(remaining.contains(orphan))
    }

    func testBlobReferencesCannotBePaths() {
        XCTAssertFalse(ImageBlobStore.isValidRef("../../etc/passwd"))
        XCTAssertFalse(ImageBlobStore.isValidRef(String(repeating: "A", count: 64)))
        XCTAssertTrue(ImageBlobStore.isValidRef(String(repeating: "a", count: 64)))
        XCTAssertThrowsError(try ImageBlobStore.load(ref: "../canvas.json"))
    }

    // MARK: - Undo stack

    func testUndoRedoOrder() {
        let s0 = PageSnapshot(nodes: [], connectors: [])
        let s1 = PageSnapshot(nodes: [textNode("one")], connectors: [])
        let s2 = PageSnapshot(nodes: [textNode("two")], connectors: [])
        var stack = UndoStack()
        stack.push(s0)
        stack.push(s1)

        XCTAssertEqual(stack.popUndo(current: s2), s1)
        XCTAssertEqual(stack.popUndo(current: s1), s0)
        XCTAssertNil(stack.popUndo(current: s0))
        XCTAssertEqual(stack.popRedo(current: s0), s1)
        XCTAssertEqual(stack.popRedo(current: s1), s2)
        XCTAssertFalse(stack.canRedo)
    }

    func testNewActionClearsRedo() {
        let a = PageSnapshot(nodes: [], connectors: [])
        let b = PageSnapshot(nodes: [textNode("b")], connectors: [])
        var stack = UndoStack()
        stack.push(a)
        _ = stack.popUndo(current: b)
        XCTAssertTrue(stack.canRedo)
        stack.push(a)
        XCTAssertFalse(stack.canRedo)
    }
}
