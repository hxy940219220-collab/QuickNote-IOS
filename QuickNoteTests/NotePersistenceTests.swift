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
        let controller = RichTextEditorController()
        let editor = RichTextEditor(
            document: session.document,
            cursorLocation: 0,
            controller: controller,
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

    func testEditorToolbarFormatsTextAndInsertsTableAndFile() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "测试")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        textView.setSelectedRange(NSRange(location: 0, length: 2))
        controller.applyTextStyle(.title)
        XCTAssertEqual((document.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 26)

        textView.setSelectedRange(NSRange(location: document.length, length: 0))
        controller.insertTable()
        XCTAssertEqual(document.tableBlockCount, 4)

        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".txt")
        try Data("附件".utf8).write(to: file)
        textView.setSelectedRange(NSRange(location: document.length, length: 0))
        try controller.insertFiles([file])
        XCTAssertEqual(document.attachmentCount, 1)
    }

    func testTableInsertionPlacesCaretInVisibleParagraphBelowTable() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "提示词")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: document.length,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        controller.insertTable()

        let caret = textView.selectedRange()
        XCTAssertLessThan(caret.location, document.length)
        if caret.location < document.length {
            let style = document.attribute(.paragraphStyle, at: caret.location, effectiveRange: nil)
                as? NSParagraphStyle
            XCTAssertTrue(style?.textBlocks.isEmpty ?? true)
        }
    }

    func testDeleteCurrentTableRemovesAllCellsAndPreservesSurroundingText() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "表格前")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: document.length,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        controller.insertTable()
        var firstCellLocation: Int?
        document.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: document.length)) {
            value, range, stop in
            guard (value as? NSParagraphStyle)?.textBlocks.contains(where: { $0 is NSTextTableBlock }) == true else {
                return
            }
            firstCellLocation = range.location
            stop.pointee = true
        }
        textView.setSelectedRange(NSRange(location: try XCTUnwrap(firstCellLocation), length: 0))

        XCTAssertTrue(controller.deleteCurrentTable())
        XCTAssertEqual(document.tableBlockCount, 0)
        XCTAssertTrue(document.string.contains("表格前"))
    }

    func testTagsPersistAndParticipateInSearch() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let documents = NoteDocumentStore(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        )
        let session = NoteSession(repository: repository, documents: documents)
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)

        session.setTags(["工作", "工作", " 灵感 "])

        XCTAssertEqual(session.tags, ["工作", "灵感"])
        XCTAssertEqual(try repository.search("灵感").map(\.id), [note.id])
        let reopened = NoteSession(repository: repository, documents: documents)
        try reopened.open(note)
        XCTAssertEqual(reopened.tags, ["工作", "灵感"])
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

    func testSelectedTextAppendsAndPersistsImmediately() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let documents = NoteDocumentStore(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        )
        let session = NoteSession(repository: repository, documents: documents)
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        session.update(document: NSAttributedString(string: "已有内容"), cursorLocation: 4)

        try session.appendPlainText("  选中文字  ")

        XCTAssertEqual(session.document.string, "已有内容\n\n选中文字")
        XCTAssertEqual(note.cursorLocation, session.document.length)
        XCTAssertEqual(try documents.load(id: note.id).string, "已有内容\n\n选中文字")
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

    func testDeletingCurrentNoteSelectsTheRemainingNote() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let session = NoteSession(
            repository: repository,
            documents: NoteDocumentStore(
                root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            )
        )
        try session.createAndOpen()
        let remaining = try XCTUnwrap(session.currentNote)
        try session.createAndOpen()
        let deleted = try XCTUnwrap(session.currentNote)

        XCTAssertTrue(session.deleteRecovering(deleted))

        XCTAssertEqual(session.currentNote?.id, remaining.id)
        XCTAssertEqual(try repository.allNotes().map(\.id), [remaining.id])
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

    var tableBlockCount: Int {
        var count = 0
        enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: length)) { value, _, _ in
            let style = value as? NSParagraphStyle
            count += style?.textBlocks.compactMap { $0 as? NSTextTableBlock }.count ?? 0
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
