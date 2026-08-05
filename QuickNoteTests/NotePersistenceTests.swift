import AppKit
import SwiftData
import SwiftUI
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
        let attachment = NSTextAttachment()
        attachment.image = testImage()
        let document = NSMutableAttributedString(string: "图：")
        document.append(NSAttributedString(attachment: attachment))
        try store.save(document, id: id)
        let loaded = try store.load(id: id)
        XCTAssertEqual(loaded.attachmentCount, 1)
    }

    func testPastedImageAutosavesAndReopensThroughEditor() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let documents = NoteDocumentStore(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        )
        let session = NoteSession(repository: repository, documents: documents)
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        let editor = RichTextEditor(
            document: session.document,
            cursorLocation: 0,
            onChange: session.update,
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([testImage()]))

        XCTAssertTrue(textView.readSelection(from: pasteboard))
        try await Task.sleep(for: .milliseconds(400))

        let reopened = NoteSession(repository: repository, documents: documents)
        try reopened.open(note)
        XCTAssertEqual(reopened.document.attachmentCount, 1)
        let attachment = try XCTUnwrap(
            reopened.document.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        )
        let imageData = try XCTUnwrap(attachment.fileWrapper?.regularFileContents)
        XCTAssertNotNil(NSImage(data: imageData))
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

    func testAutosaveFailurePreservesDirtyDocumentAndCanRetry() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: root)
        let documents = NoteDocumentStore(root: root)
        let session = NoteSession(repository: repository, documents: documents)
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)

        session.update(document: NSAttributedString(string: "不能丢的内容"), cursorLocation: 6)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(session.isDirty)
        XCTAssertNotNil(session.saveError)
        XCTAssertEqual(session.document.string, "不能丢的内容")
        XCTAssertEqual(note.plainText, "")

        try FileManager.default.removeItem(at: root)
        session.retrySave()

        XCTAssertFalse(session.isDirty)
        XCTAssertNil(session.saveError)
        XCTAssertEqual(try documents.load(id: note.id).string, "不能丢的内容")
    }

    func testCreateAndOpenDoesNotCreateNoteWhenOutgoingFlushFails() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: root)
        let session = NoteSession(repository: repository, documents: NoteDocumentStore(root: root))
        try session.createAndOpen()
        session.update(document: NSAttributedString(string: "待保存"), cursorLocation: 3)

        XCTAssertThrowsError(try session.createAndOpen())

        XCTAssertEqual(try repository.allNotes().count, 1)
        XCTAssertEqual(session.document.string, "待保存")
        XCTAssertTrue(session.isDirty)
        XCTAssertNotNil(session.saveError)
    }

    func testFailedPinPublishesErrorAndRetryPersistsIntendedValueOnce() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        var saveAttempt = 0
        var failingAttempt: Int?
        let session = NoteSession(
            repository: repository,
            documents: NoteDocumentStore(root: root),
            saveRepository: {
                saveAttempt += 1
                if saveAttempt == failingAttempt { throw TestError.saveFailed }
                try repository.save()
            }
        )
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        var notificationCount = 0
        session.onSaved = { notificationCount += 1 }
        failingAttempt = 3

        XCTAssertFalse(session.togglePinnedRecovering(note))
        XCTAssertTrue(note.isPinned)
        XCTAssertNotNil(session.saveError)
        XCTAssertEqual(notificationCount, 0)

        session.retrySave()

        XCTAssertTrue(note.isPinned)
        XCTAssertNil(session.saveError)
        XCTAssertEqual(notificationCount, 1)
    }

    func testFailedCreatePublishesErrorAndRetryReusesPendingNote() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        var shouldFail = true
        let session = NoteSession(
            repository: repository,
            documents: NoteDocumentStore(root: root),
            saveRepository: {
                if shouldFail {
                    shouldFail = false
                    throw TestError.saveFailed
                }
                try repository.save()
            }
        )
        var notificationCount = 0
        session.onSaved = { notificationCount += 1 }

        XCTAssertFalse(session.createAndOpenRecovering())
        let pendingNote = try XCTUnwrap(repository.allNotes().first)
        XCTAssertNil(session.currentNote)
        XCTAssertNotNil(session.saveError)
        XCTAssertEqual(try repository.allNotes().count, 1)
        XCTAssertEqual(notificationCount, 0)

        XCTAssertFalse(session.createAndOpenRecovering())
        XCTAssertNil(session.currentNote)
        XCTAssertNotNil(session.saveError)
        XCTAssertEqual(try repository.allNotes().count, 1)
        XCTAssertEqual(notificationCount, 0)

        session.retrySave()

        XCTAssertEqual(session.currentNote?.id, pendingNote.id)
        XCTAssertNil(session.saveError)
        XCTAssertEqual(try repository.allNotes().count, 1)
        XCTAssertEqual(notificationCount, 1)
    }
}

private enum TestError: Error {
    case saveFailed
}

private extension NSView {
    func descendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        return subviews.lazy.compactMap { $0.descendant(ofType: type) }.first
    }
}

private extension NSAttributedString {
    var attachmentCount: Int {
        var count = 0
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, _, _ in
            if value is NSTextAttachment { count += 1 }
        }
        return count
    }
}

private func testImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 2, height: 2).fill()
    image.unlockFocus()
    return image
}
