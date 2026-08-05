import AppKit
import SwiftData
import XCTest
@testable import QuickNote

@MainActor
final class NotePersistenceTests: XCTestCase {
    func testRTFDRoundTripPreservesText() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = NoteDocumentStore(root: root)
        let id = UUID()
        try store.save(NSAttributedString(string: "快速记录"), id: id)
        XCTAssertEqual(try store.load(id: id).string, "快速记录")
    }

    func testRTFDRoundTripPreservesImageAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = NoteDocumentStore(root: root)
        let id = UUID()
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let attachment = NSTextAttachment()
        attachment.image = image
        let document = NSMutableAttributedString(string: "图：")
        document.append(NSAttributedString(attachment: attachment))
        try store.save(document, id: id)
        let loaded = try store.load(id: id)
        var count = 0
        loaded.enumerateAttribute(.attachment, in: NSRange(location: 0, length: loaded.length)) { value, _, _ in
            if value is NSTextAttachment { count += 1 }
        }
        XCTAssertEqual(count, 1)
    }

    func testSessionFlushesDocumentMetadataAndCursor() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let documents = NoteDocumentStore(root: root)
        let session = NoteSession(repository: repository, documents: documents)

        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        session.update(document: NSAttributedString(string: "\n  标题  \n正文"), cursorLocation: 4)
        try session.flush()

        XCTAssertEqual(note.title, "标题")
        XCTAssertEqual(note.plainText, "\n  标题  \n正文")
        XCTAssertEqual(note.cursorLocation, 4)
        XCTAssertEqual(try documents.load(id: note.id).string, "\n  标题  \n正文")
    }

    func testSessionDebouncesAutosaveToLatestDocument() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let documents = NoteDocumentStore(root: root)
        let session = NoteSession(repository: repository, documents: documents)
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        var saveCount = 0
        session.onSaved = { saveCount += 1 }

        session.update(document: NSAttributedString(string: "旧内容"), cursorLocation: 1)
        session.update(document: NSAttributedString(string: "最新内容"), cursorLocation: 4)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(note.plainText, "最新内容")
        XCTAssertEqual(note.cursorLocation, 4)
        XCTAssertEqual(try documents.load(id: note.id).string, "最新内容")
    }
}
