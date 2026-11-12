import AppKit
import SwiftData
import XCTest
@testable import QuickNote

// Exact pre-manual-order entity shape, created only in a temporary test database.
private enum SidebarLegacyModels {
    @Model final class NoteRecord {
        @Attribute(.unique) var id: UUID
        var title: String
        var plainText: String
        var documentPath: String
        var createdAt: Date
        var updatedAt: Date
        var isPinned: Bool
        var cursorLocation: Int
        var tagsText: String = ""
        var folderID: UUID? = nil
        var deletedAt: Date? = nil
        init(id: UUID, folderID: UUID) {
            self.id = id; self.folderID = folderID
            title = "迁移示例"; plainText = "保留原来的示例正文"
            documentPath = "\(id.uuidString).rtfd"
            createdAt = Date(timeIntervalSince1970: 1); updatedAt = Date(timeIntervalSince1970: 1)
            isPinned = true; cursorLocation = 2; tagsText = "保留标签"
        }
    }
    @Model final class NoteFolder {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date
        init(id: UUID) { self.id = id; name = "原文件夹"; createdAt = Date(timeIntervalSince1970: 1) }
    }
}

@MainActor
final class NoteRepositoryTests: XCTestCase {
    func testManualNoteAndFolderOrderPersistsWithoutChangingContentOrTimestamps() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "QuickNote-Order-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.store")
        let ids: [UUID], folderIDs: [UUID]
        do {
            let container = try ModelContainer(for: NoteRecord.self, NoteFolder.self,
                configurations: ModelConfiguration(url: url))
            let repository = NoteRepository(context: container.mainContext)
            let folders = try ["项目", "资料", "归档"].map { try repository.createFolder(named: $0) }
            let notes = (0..<3).map { index in
                let note = repository.createNote()
                note.title = "示例 \(index)"; note.plainText = "保持正文"
                note.createdAt = Date(timeIntervalSince1970: Double(index))
                note.updatedAt = note.createdAt
                note.cursorLocation = 2
                note.isPinned = index != 1
                return note
            }
            ids = notes.map(\.id); folderIDs = folders.map(\.id)
            try repository.save()
            XCTAssertTrue(try repository.reorderNote(id: ids[0], relativeTo: ids[2], after: false))
            XCTAssertEqual(try repository.allNotes().map(\.id), [ids[0], ids[2], ids[1]])
            XCTAssertTrue(try repository.reorderNote(id: ids[0], relativeTo: ids[2], after: false, pinned: true))
            XCTAssertTrue(try repository.reorderFolder(id: folderIDs[2], relativeTo: folderIDs[0], after: false))
            XCTAssertEqual(try repository.allFolders().map(\.id), [folderIDs[2], folderIDs[0], folderIDs[1]])
            XCTAssertEqual(notes[0].updatedAt, Date(timeIntervalSince1970: 0))
            XCTAssertEqual(notes[0].plainText, "保持正文")
            XCTAssertEqual(notes[0].cursorLocation, 2)
            notes[1].updatedAt = .now
            try repository.save()
            XCTAssertEqual(try repository.allNotes().map(\.id), [ids[0], ids[2], ids[1]], "编辑正文不能重排手动顺序")
        }
        let reopened = try ModelContainer(for: NoteRecord.self, NoteFolder.self,
            configurations: ModelConfiguration(url: url))
        let repository = NoteRepository(context: reopened.mainContext)
        XCTAssertEqual(try repository.allNotes().map(\.id), [ids[0], ids[2], ids[1]])
        XCTAssertEqual(try repository.allFolders().map(\.id), [folderIDs[2], folderIDs[0], folderIDs[1]])
        XCTAssertEqual(try repository.allNotes().filter(\.isPinned).sorted(by: NoteSidebarOrder.pinnedPrecedes).map(\.id), [ids[0], ids[2]])
    }

    func testOldSidebarSchemaMigratesWithoutLosingNotesFoldersOrDocuments() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "QuickNote-Order-Migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "library.store")
        let documents = NoteDocumentStore(root: directory.appending(path: "Documents"))
        let noteID = UUID(), folderID = UUID()
        do {
            let old = try ModelContainer(for: SidebarLegacyModels.NoteRecord.self, SidebarLegacyModels.NoteFolder.self,
                configurations: ModelConfiguration(url: url))
            XCTAssertEqual(Set(old.schema.entities.map(\.name)), Set(Schema([NoteRecord.self, NoteFolder.self]).entities.map(\.name)))
            let folder = SidebarLegacyModels.NoteFolder(id: folderID)
            let note = SidebarLegacyModels.NoteRecord(id: noteID, folderID: folderID)
            old.mainContext.insert(folder)
            old.mainContext.insert(note)
            try old.mainContext.save()
            try documents.save(NSAttributedString(string: "保留原来的示例正文", attributes: [.font: EditorTextStyle.body.font]), id: noteID)
        }
        let current = try NoteSchemaMigration.makeContainer(configuration: ModelConfiguration(url: url))
        let repository = NoteRepository(context: current.mainContext)
        let note = try XCTUnwrap(repository.allNotes().first)
        XCTAssertEqual(note.id, noteID)
        XCTAssertEqual(note.folderID, folderID)
        XCTAssertEqual(note.title, "迁移示例")
        XCTAssertEqual(note.tags, ["保留标签"])
        XCTAssertEqual(note.cursorLocation, 2)
        XCTAssertTrue(note.isPinned)
        XCTAssertNil(note.manualOrder)
        XCTAssertNil(note.pinnedOrder)
        XCTAssertFalse(note.isSensitive)
        XCTAssertTrue(note.isEligibleForAI)
        let folder = try XCTUnwrap(repository.allFolders().first)
        XCTAssertEqual(folder.id, folderID)
        XCTAssertEqual(folder.name, "原文件夹")
        XCTAssertNil(folder.manualOrder)
        XCTAssertEqual(try documents.load(id: noteID).string, "保留原来的示例正文")
    }

    func testPreSensitiveSchemaMigratesWithFalseAndPreservesExistingMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "QuickNote-Sensitivity-Migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appending(path: "library.store"))
        let documents = NoteDocumentStore(root: directory.appending(path: "Documents"))
        let noteID = UUID(), folderID = UUID()
        let createdAt = Date(timeIntervalSince1970: 1)
        let updatedAt = Date(timeIntervalSince1970: 2)
        let original = NSAttributedString(string: "保留正文", attributes: [.font: EditorTextStyle.body.font])
        do {
            // The shipped store had these fields but no explicit versioned schema.
            let old = try ModelContainer(for: NoteSchemaBeforeSensitivity.NoteRecord.self,
                NoteSchemaBeforeSensitivity.NoteFolder.self, configurations: configuration)
            let folder = NoteSchemaBeforeSensitivity.NoteFolder(id: folderID, name: "资料", now: createdAt)
            folder.manualOrder = 4
            let note = NoteSchemaBeforeSensitivity.NoteRecord(id: noteID, now: createdAt)
            note.title = "迁移示例"
            note.plainText = original.string
            note.folderID = folderID
            note.updatedAt = updatedAt
            note.cursorLocation = 2
            note.tagsText = "保留标签"
            note.isPinned = true
            note.manualOrder = 7
            note.pinnedOrder = 3
            old.mainContext.insert(folder)
            old.mainContext.insert(note)
            try old.mainContext.save()
            try documents.save(original, id: noteID)
        }
        let current = try NoteSchemaMigration.makeContainer(configuration: configuration)
        let repository = NoteRepository(context: current.mainContext)
        let note = try XCTUnwrap(repository.note(withID: noteID))
        XCTAssertFalse(note.isSensitive)
        XCTAssertTrue(note.isEligibleForAI)
        XCTAssertEqual(note.folderID, folderID)
        XCTAssertEqual(note.title, "迁移示例")
        XCTAssertEqual(note.plainText, original.string)
        XCTAssertEqual(note.createdAt, createdAt)
        XCTAssertEqual(note.updatedAt, updatedAt)
        XCTAssertEqual(note.cursorLocation, 2)
        XCTAssertEqual(note.tags, ["保留标签"])
        XCTAssertTrue(note.isPinned)
        XCTAssertEqual(note.manualOrder, 7)
        XCTAssertEqual(note.pinnedOrder, 3)
        XCTAssertEqual(try repository.allFolders().first { $0.id == folderID }?.manualOrder, 4)
        XCTAssertEqual(try documents.load(id: noteID).string, original.string)
    }

    func testAIEligibilityExcludesSensitiveAndDeletedNotes() throws {
        let (container, repository) = try makeFolderRepository()
        let note = repository.createNote()
        try repository.save()
        XCTAssertTrue(note.isEligibleForAI)
        note.isSensitive = true
        XCTAssertFalse(note.isEligibleForAI)
        repository.delete(note)
        try repository.save()
        let deleted = try XCTUnwrap(repository.note(withID: note.id))
        XCTAssertFalse(deleted.isEligibleForAI)
        deleted.isSensitive = false
        XCTAssertFalse(deleted.isEligibleForAI)
        repository.restoreDeleted(deleted)
        XCTAssertTrue(deleted.isEligibleForAI)
        XCTAssertNil(try repository.note(withID: UUID()))
        withExtendedLifetime(container) {}
    }

    func testReorderCanMoveNotesBetweenFoldersButPinnedShortcutOrderDoesNotRefile() throws {
        let (container, repository) = try makeFolderRepository()
        let folder = try repository.createFolder(named: "项目")
        let a = repository.createNote(), b = repository.createNote(), c = repository.createNote()
        a.updatedAt = Date(timeIntervalSince1970: 1)
        b.updatedAt = Date(timeIntervalSince1970: 2)
        c.updatedAt = Date(timeIntervalSince1970: 3)
        a.isPinned = true; c.isPinned = true
        repository.move(b, to: folder)
        try repository.save()
        XCTAssertTrue(try repository.reorderNote(id: a.id, relativeTo: b.id, after: true))
        XCTAssertEqual(a.folderID, folder.id)
        XCTAssertEqual(try repository.allNotes().filter { $0.folderID == folder.id }.map(\.id), [b.id, a.id])
        XCTAssertTrue(try repository.reorderNote(id: a.id, relativeTo: c.id, after: false, pinned: true))
        XCTAssertLessThan(try XCTUnwrap(a.pinnedOrder), try XCTUnwrap(c.pinnedOrder))
        XCTAssertEqual(a.folderID, folder.id, "置顶区仅调整快捷入口，不能改变归档位置")
        XCTAssertFalse(try repository.reorderNote(id: b.id, relativeTo: c.id, after: true, pinned: true))
        XCTAssertFalse(b.isPinned, "拖动不能隐式置顶")
        XCTAssertFalse(try repository.reorderNote(id: a.id, relativeTo: a.id, after: true))
        XCTAssertFalse(try repository.reorderNote(id: UUID(), relativeTo: a.id, after: false))
        repository.delete(c)
        XCTAssertFalse(try repository.reorderNote(id: c.id, relativeTo: a.id, after: false))
        XCTAssertFalse(try repository.reorderFolder(id: folder.id, relativeTo: folder.id, after: false))
        withExtendedLifetime(container) {}
    }
    func testDeleteKeepsMetadataAndRichDocumentForRecoveryButHidesFromQueries() throws {
        let (container, repository) = try makeFolderRepository()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = NoteDocumentStore(root: root)
        let session = NoteSession(repository: repository, documents: documents)
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        try session.appendPlainText("Recover me")

        XCTAssertTrue(session.deleteRecovering(note))

        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<NoteRecord>()).contains { $0.id == note.id })
        XCTAssertEqual(try documents.load(id: note.id).string, "Recover me")
        XCTAssertFalse(try repository.allNotes().contains { $0.id == note.id })
        XCTAssertFalse(try repository.recentNotes().contains { $0.id == note.id })
        XCTAssertTrue(try repository.search("Recover me").isEmpty)
    }

    func testAllNotesKeepPinnedNotesAboveMoreRecentlyEditedNotes() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let pinned = NoteRecord(now: Date(timeIntervalSince1970: 1))
        pinned.isPinned = true
        let recent = NoteRecord(now: Date(timeIntervalSince1970: 2))
        container.mainContext.insert(pinned)
        container.mainContext.insert(recent)
        try repository.save()

        XCTAssertEqual(try repository.allNotes().map(\.id), [pinned.id, recent.id])
    }

    func testRecentNotesAreOrderedOnlyByUpdateTime() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let pinned = NoteRecord(now: Date(timeIntervalSince1970: 1))
        pinned.isPinned = true
        let recent = NoteRecord(now: Date(timeIntervalSince1970: 2))
        container.mainContext.insert(pinned)
        container.mainContext.insert(recent)
        try repository.save()
        XCTAssertEqual(try repository.recentNotes(limit: 2).map(\.id), [recent.id, pinned.id])
    }

    func testCreateAndSearchNoteBody() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let note = repository.createNote()
        note.title = "产品想法"
        note.plainText = "先记录，再整理"
        try repository.save()
        XCTAssertEqual(try repository.search("整理").map(\.id), [note.id])
    }

    func testFolderLifecyclePreservesNotesWhenFolderIsDeleted() throws {
        let (container, repository) = try makeFolderRepository()
        let folder = try repository.createFolder(named: " 工作 ")
        let note = repository.createNote()
        repository.move(note, to: folder)
        try repository.rename(folder, to: "项目")
        try repository.save()

        XCTAssertEqual(try repository.allFolders().map(\.name), ["项目"])
        XCTAssertEqual(note.folderID, folder.id)

        try repository.delete(folder)
        try repository.save()

        XCTAssertTrue(try repository.allFolders().isEmpty)
        XCTAssertEqual(try repository.allNotes().map(\.id), [note.id])
        XCTAssertNil(note.folderID)
        withExtendedLifetime(container) {}
    }

    func testFolderNamesMustBeNonEmptyAndUnique() throws {
        let (container, repository) = try makeFolderRepository()
        _ = try repository.createFolder(named: "Work")

        XCTAssertThrowsError(try repository.createFolder(named: "  ")) {
            XCTAssertEqual($0 as? FolderNameError, .empty)
        }
        XCTAssertThrowsError(try repository.createFolder(named: " work ")) {
            XCTAssertEqual($0 as? FolderNameError, .duplicate)
        }
        withExtendedLifetime(container) {}
    }

    func testFolderRenameValidationPreservesExistingNameAndMembership() throws {
        let (container, repository) = try makeFolderRepository()
        let folder = try repository.createFolder(named: "工作资料")
        _ = try repository.createFolder(named: "会议纪要")
        let note = repository.createNote()
        note.title = "项目记录"
        note.plainText = "不变的示例正文"
        note.isPinned = true
        note.cursorLocation = 3
        repository.move(note, to: folder)
        try repository.save()
        let id = folder.id
        for name in [" \n ", " 会议纪要 "] {
            XCTAssertThrowsError(try repository.rename(folder, to: name))
            XCTAssertEqual(folder.name, "工作资料")
            XCTAssertEqual(note.folderID, id)
        }
        try repository.rename(folder, to: "  项目归档  ")
        try repository.save()
        XCTAssertEqual(folder.name, "项目归档")
        XCTAssertEqual(folder.id, id)
        XCTAssertEqual(note.folderID, id)
        XCTAssertEqual(note.title, "项目记录")
        XCTAssertEqual(note.plainText, "不变的示例正文")
        XCTAssertTrue(note.isPinned)
        XCTAssertEqual(note.cursorLocation, 3)
        withExtendedLifetime(container) {}
    }

    func testDeletingFolderAlsoClearsTrashedNoteFolderBeforeRestore() throws {
        let (container, repository) = try makeFolderRepository()
        let folder = try repository.createFolder(named: "Removed")
        let note = repository.createNote()
        note.folderID = folder.id
        repository.delete(note)
        try repository.delete(folder)
        repository.restoreDeleted(note)
        try repository.save()
        XCTAssertNil(note.folderID)
        XCTAssertEqual(try repository.allNotes().map(\.id), [note.id])
        withExtendedLifetime(container) {}
    }

    private func makeFolderRepository() throws -> (ModelContainer, NoteRepository) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: NoteRecord.self,
            NoteFolder.self,
            configurations: configuration
        )
        return (container, NoteRepository(context: container.mainContext))
    }

    func testTrashRestoresWithoutLosingFolderAndRejectsEditsWhileDeleted() throws {
        try withSession { _, repository, documents, session in
            try session.createAndOpen()
            let note = try XCTUnwrap(session.currentNote)
            let folder = try repository.createFolder(named: "Work")
            repository.move(note, to: folder)
            try session.appendPlainText("Keep me")
            XCTAssertTrue(session.deleteRecovering(note))
            XCTAssertEqual(try session.deletedNotes().map(\.id), [note.id])
            XCTAssertThrowsError(try session.importContent(NSAttributedString(string: "No"), into: note.id, at: .end))
            XCTAssertThrowsError(try session.open(note))
            try session.restoreDeleted(note)
            XCTAssertTrue(try session.deletedNotes().isEmpty)
            XCTAssertEqual(note.folderID, folder.id)
            XCTAssertEqual(try documents.load(id: note.id).string, "Keep me")
        }
    }

    func testVersionsCoalesceOrdinarySavesAndReadsDoNotCreateHistory() throws {
        try withSession { _, _, _, session in
            try session.createAndOpen()
            let note = try XCTUnwrap(session.currentNote)
            XCTAssertTrue(try session.versions(for: note.id).isEmpty)
            try session.open(note)
            try session.flush()
            XCTAssertTrue(try session.versions(for: note.id).isEmpty)
            for value in ["One", "Two", "Three"] {
                session.update(document: NSAttributedString(string: value), cursorLocation: 0)
                try session.flush()
            }
            XCTAssertEqual(session.externalEditRevision, 0)
            XCTAssertEqual(try session.versions(for: note.id).count, 1)
            let count = try session.versions(for: note.id).count
            try session.createAndOpen()
            try session.open(note)
            XCTAssertEqual(try session.versions(for: note.id).count, count)
        }
    }

    func testImportUsesCapturedTargetCursorAndPreservesAttachmentOnVersionRestore() throws {
        try withSession { _, _, documents, session in
            try session.createAndOpen()
            let target = try XCTUnwrap(session.currentNote)
            let original = NSAttributedString(string: "A👩🏽‍💻B", attributes: [.font: EditorTextStyle.body.font])
            session.update(document: original, cursorLocation: 2) // inside a composed UTF-16 character
            let revision = try session.captureImportCursor(for: target.id)
            try session.createAndOpen()
            let frontID = session.currentNote?.id
            let wrapper = FileWrapper(regularFileWithContents: Data("asset bytes".utf8))
            wrapper.preferredFilename = "sample.txt"
            let content = NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
            XCTAssertEqual(try session.importContent(content, into: target.id, at: .cursor,
                expectedRevision: revision), target.id)
            XCTAssertEqual(session.currentNote?.id, frontID)
            XCTAssertEqual(session.externalEditRevision, 0)
            let imported = try documents.load(id: target.id)
            XCTAssertEqual(imported.string, "A\n\u{fffc}\n👩🏽‍💻B")
            let attachment = try XCTUnwrap(imported.attribute(.attachment, at: 2, effectiveRange: nil) as? NSTextAttachment)
            XCTAssertEqual(attachment.fileWrapper?.regularFileContents, Data("asset bytes".utf8))
            let checkpoint = try XCTUnwrap(session.versions(for: target.id).first { $0.reason == "import" })
            let beforeRestore = session.contentRevision(for: target.id)
            try session.restoreVersion(checkpoint, for: target.id)
            XCTAssertEqual(session.currentNote?.id, target.id)
            XCTAssertEqual(session.document.string, original.string)
            XCTAssertEqual(session.contentRevision(for: target.id), beforeRestore + 1)
            let undoRestore = try XCTUnwrap(session.versions(for: target.id).first { $0.reason == "restore" })
            try session.restoreVersion(undoRestore, for: target.id)
            XCTAssertEqual(session.document.string, imported.string)
            XCTAssertEqual(session.externalEditRevision, 1)
        }
    }

    func testImportRefusesStaleOrMissingTargetsAndExplicitNewIsIndependent() throws {
        try withSession { _, repository, _, session in
            try session.createAndOpen()
            let target = try XCTUnwrap(session.currentNote)
            try session.appendPlainText("Before")
            let revision = try session.captureImportCursor(for: target.id)
            session.update(document: NSAttributedString(string: "Changed"), cursorLocation: 2)
            let content = NSAttributedString(string: "Imported")
            XCTAssertThrowsError(try session.importContent(content, into: target.id, at: .cursor, expectedRevision: revision))
            XCTAssertThrowsError(try session.importContent(content, into: UUID(), at: .end))
            XCTAssertThrowsError(try session.importContent(content, into: nil, at: .end))
            let newID = try session.importContent(content, into: nil, at: .newNote)
            XCTAssertNotEqual(newID, target.id)
            XCTAssertEqual(session.document.string, "Imported")
            XCTAssertEqual(try repository.allNotes().count, 2)
        }
    }

    func testAIApplySupportsCurrentAndBackgroundAndKeepsBoundedCheckpoints() throws {
        try withSession { _, repository, documents, session in
            try session.createAndOpen()
            let target = try XCTUnwrap(session.currentNote)
            try session.appendPlainText("Original")
            var source = session.document
            var revision = session.contentRevision(for: target.id)
            let replacement = NSAttributedString(string: source.string, attributes: [.font: EditorTextStyle.heading.font])
            try session.applyAIFormattedDocument(replacement, original: source, expectedRevision: revision, noteID: target.id)
            XCTAssertEqual(session.document.string, "Original")
            XCTAssertEqual(session.externalEditRevision, 1)
            XCTAssertThrowsError(try session.applyAIFormattedDocument(source, original: source, expectedRevision: revision, noteID: target.id))
            try session.createAndOpen()
            let frontID = session.currentNote?.id
            for index in 0..<24 {
                source = try documents.load(id: target.id)
                revision = session.contentRevision(for: target.id)
                try session.applyAIFormattedDocument(NSAttributedString(string: source.string,
                    attributes: [.font: EditorTextStyle.body.font, .kern: index]), original: source,
                    expectedRevision: revision, noteID: target.id)
            }
            XCTAssertEqual(session.currentNote?.id, frontID)
            XCTAssertEqual(session.externalEditRevision, 1)
            XCTAssertEqual(try session.versions(for: target.id).count, 20)
            let reopened = NoteSession(repository: repository, documents: documents)
            XCTAssertEqual(try reopened.versions(for: target.id).count, 20)
        }
    }

    func testBackupRoundTripIncludesTrashFoldersHistoryAndAssetsWithFreshIDs() throws {
        try withSession { _, repository, documents, session in
            try session.createAndOpen()
            let note = try XCTUnwrap(session.currentNote)
            let folder = try repository.createFolder(named: "Projects")
            folder.manualOrder = 4
            note.folderID = folder.id
            note.manualOrder = 7
            note.pinnedOrder = 3
            note.tags = ["重要"]
            note.isPinned = true
            let wrapper = FileWrapper(regularFileWithContents: Data("backup asset".utf8))
            wrapper.preferredFilename = "asset.txt"
            let content = NSMutableAttributedString(string: "Asset\n")
            content.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            _ = try session.importContent(content, into: note.id, at: .end)
            XCTAssertTrue(session.deleteRecovering(note))
            let backup = documents.root.appending(path: "Export")
            try session.exportBackup(to: backup)
            let manifest = try Data(contentsOf: backup.appending(path: "manifest.json"))
            XCTAssertFalse(String(decoding: manifest, as: UTF8.self).contains("apiKey"))
            let oldIDs = Set(try repository.notesIncludingDeleted().map(\.id))
            XCTAssertEqual(try session.importBackup(from: backup), 2)
            let imported = try XCTUnwrap(repository.notesIncludingDeleted().first { !oldIDs.contains($0.id) && $0.deletedAt != nil })
            XCTAssertNotEqual(imported.folderID, folder.id)
            XCTAssertEqual(imported.tags, ["重要"])
            XCTAssertTrue(imported.isPinned)
            XCTAssertEqual(imported.manualOrder, 7)
            XCTAssertEqual(imported.pinnedOrder, 3)
            XCTAssertEqual(try repository.allFolders().first { $0.id == imported.folderID }?.manualOrder, 4)
            XCTAssertEqual(try documents.load(id: imported.id).string, content.string)
            let attachment = try XCTUnwrap(documents.load(id: imported.id).attribute(.attachment, at: 6, effectiveRange: nil) as? NSTextAttachment)
            XCTAssertEqual(attachment.fileWrapper?.regularFileContents, Data("backup asset".utf8))
            XCTAssertFalse(try session.versions(for: imported.id).isEmpty)
            // Older manifests have no ordering fields. They must still import without data loss.
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
            for key in ["notes", "folders"] {
                var entries = try XCTUnwrap(legacy[key] as? [[String: Any]])
                for index in entries.indices {
                    entries[index].removeValue(forKey: "manualOrder")
                    entries[index].removeValue(forKey: "pinnedOrder")
                }
                legacy[key] = entries
            }
            try JSONSerialization.data(withJSONObject: legacy).write(to: backup.appending(path: "manifest.json"))
            let beforeLegacy = Set(try repository.notesIncludingDeleted().map(\.id))
            XCTAssertEqual(try session.importBackup(from: backup), 2)
            let legacyNote = try XCTUnwrap(repository.notesIncludingDeleted().first { !beforeLegacy.contains($0.id) && $0.deletedAt != nil })
            XCTAssertNil(legacyNote.manualOrder)
            XCTAssertNil(legacyNote.pinnedOrder)
            XCTAssertEqual(try documents.load(id: legacyNote.id).string, content.string)
        }
    }

    func testSensitiveBackupPreservesFlagAndLegacyMissingFlagDefaultsFalse() throws {
        try withSession { _, repository, documents, session in
            try session.createAndOpen()
            let source = try XCTUnwrap(session.currentNote)
            try session.appendPlainText("合成敏感便签")
            source.isSensitive = true
            try repository.save()

            let backup = documents.root.appending(path: "Export")
            try session.exportBackup(to: backup)
            let manifestURL = backup.appending(path: "manifest.json")
            let data = try Data(contentsOf: manifestURL)
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var entries = try XCTUnwrap(manifest["notes"] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?["isSensitive"] as? Bool, true)

            XCTAssertEqual(try session.importBackup(from: backup), 1)
            let imported = try XCTUnwrap(repository.allNotes().first { $0.id != source.id })
            XCTAssertTrue(imported.isSensitive)
            XCTAssertFalse(imported.isEligibleForAI)
            XCTAssertEqual(try documents.load(id: imported.id).string, "合成敏感便签")

            for index in entries.indices { entries[index].removeValue(forKey: "isSensitive") }
            manifest["notes"] = entries
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
            let existingIDs = Set(try repository.allNotes().map(\.id))
            XCTAssertEqual(try session.importBackup(from: backup), 1)
            let legacy = try XCTUnwrap(repository.allNotes().first { !existingIDs.contains($0.id) })
            XCTAssertFalse(legacy.isSensitive)
            XCTAssertTrue(legacy.isEligibleForAI)
            XCTAssertEqual(try documents.load(id: legacy.id).string, "合成敏感便签")
        }
    }

    func testBackupRejectsTraversalSymlinksCorruptionAndMissingDocumentsWithoutPartialImport() throws {
        try withSession { _, repository, documents, session in
            try session.createAndOpen()
            let note = try XCTUnwrap(session.currentNote)
            try session.appendPlainText("Do not overwrite")
            let backup = documents.root.appending(path: "Export")
            try session.exportBackup(to: backup)
            let manifestURL = backup.appending(path: "manifest.json")
            let manifest = try Data(contentsOf: manifestURL)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
            var notes = try XCTUnwrap(json["notes"] as? [[String: Any]])
            notes[0]["documentPath"] = "../outside.rtfd"
            json["notes"] = notes
            try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
            XCTAssertThrowsError(try session.importBackup(from: backup))
            try manifest.write(to: manifestURL)
            let link = backup.appending(path: "escape")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: documents.root)
            XCTAssertThrowsError(try session.importBackup(from: backup))
            try FileManager.default.removeItem(at: link)
            let body = backup.appending(path: "Documents/\(note.id.uuidString).rtfd/TXT.rtf")
            try Data("not RTF".utf8).write(to: body)
            XCTAssertThrowsError(try session.importBackup(from: backup))
            XCTAssertEqual(try repository.allNotes().map(\.id), [note.id])
            XCTAssertEqual(try documents.load(id: note.id).string, "Do not overwrite")
            let missing = repository.createNote()
            missing.title = "Missing note"
            try repository.save()
            XCTAssertThrowsError(try session.exportBackup(to: documents.root.appending(path: "BadExport"))) {
                XCTAssertTrue($0.localizedDescription.contains("Missing note"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: documents.root.appending(path: "BadExport").path))
        }
    }

    func testFailedBackupCommitRemovesOnlyNewNotesFoldersAndDocuments() throws {
        try withSession { container, repository, documents, session in
            try session.createAndOpen()
            try session.appendPlainText("Existing")
            let note = try XCTUnwrap(session.currentNote)
            let backup = documents.root.appending(path: "Export")
            try session.exportBackup(to: backup)
            note.tags = ["unsaved unrelated edit"]
            let suite = "QuickNote.P04Failure.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let failing = NoteSession(repository: repository, documents: documents,
                saveRepository: { throw CocoaError(.fileWriteNoPermission) }, defaults: defaults)
            let paths = try FileManager.default.contentsOfDirectory(atPath: documents.root.path).sorted()
            XCTAssertThrowsError(try failing.importBackup(from: backup))
            XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<NoteRecord>()).map(\.id), [note.id])
            XCTAssertEqual(note.tags, ["unsaved unrelated edit"])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: documents.root.path).sorted(), paths)
        }
    }

    func testSavePersistsAnAttachmentMutatedInPlace() throws {
        try withSession { _, _, documents, session in
            try session.createAndOpen()
            let note = try XCTUnwrap(session.currentNote)
            let wrapper = FileWrapper(regularFileWithContents: Data("before".utf8))
            wrapper.preferredFilename = "asset.txt"
            let attachment = NSTextAttachment(fileWrapper: wrapper)
            session.update(document: NSAttributedString(attachment: attachment), cursorLocation: 1)
            try session.flush()
            let changed = FileWrapper(regularFileWithContents: Data("after".utf8))
            changed.preferredFilename = "asset.txt"
            attachment.fileWrapper = changed
            session.update(document: session.document, cursorLocation: 1)
            try session.flush()
            let saved = try XCTUnwrap(documents.load(id: note.id).attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
            XCTAssertEqual(saved.fileWrapper?.regularFileContents, Data("after".utf8))
        }
    }

    func testAIFormattingRejectsChangesToTextOrAttachmentsBeforeCheckpointing() throws {
        try withSession { _, _, _, session in
            try session.createAndOpen()
            let note = try XCTUnwrap(session.currentNote)
            let wrapper = FileWrapper(regularFileWithContents: Data("keep".utf8))
            wrapper.preferredFilename = "asset.txt"
            let source = NSMutableAttributedString(string: "Text\n")
            source.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            session.update(document: source, cursorLocation: 0)
            try session.flush()
            let revision = session.contentRevision(for: note.id)
            let versions = try session.versions(for: note.id).count
            XCTAssertThrowsError(try session.applyAIFormattedDocument(NSAttributedString(string: "Changed"),
                original: source, expectedRevision: revision, noteID: note.id))
            XCTAssertThrowsError(try session.applyAIFormattedDocument(NSAttributedString(string: source.string),
                original: source, expectedRevision: revision, noteID: note.id))
            XCTAssertEqual(try session.versions(for: note.id).count, versions)
            XCTAssertEqual(session.contentRevision(for: note.id), revision)
        }
    }

    func testAppliedImportSaveFailureBlocksDuplicateImportUntilRetrySucceeds() throws {
        for current in [true, false] {
            try withSession { _, repository, documents, session in
                try session.createAndOpen()
                try session.appendPlainText("Original")
                let note = try XCTUnwrap(session.currentNote)
                var reject = true
                let failing = NoteSession(repository: repository, documents: documents, saveRepository: {
                    if reject && note.plainText.contains("Imported") { throw CocoaError(.fileWriteNoPermission) }
                    try repository.save()
                })
                if current { try failing.open(note) }
                let addition = NSAttributedString(string: "Imported")
                XCTAssertThrowsError(try failing.importContent(addition, into: note.id, at: .end)) {
                    XCTAssertTrue($0 is NoteContentAppliedError)
                }
                XCTAssertThrowsError(try failing.importContent(addition, into: note.id, at: .end))
                reject = false
                failing.retrySave()
                XCTAssertNil(failing.saveError)
                XCTAssertEqual(try documents.load(id: note.id).string, "Original\nImported")
                if current { XCTAssertEqual(failing.externalEditRevision, 1) }
            }
        }
    }

    func testBackgroundAIFormattingAcceptsUnchangedCustomFontsAndAttachments() throws {
        try withSession { _, _, documents, session in
            try session.createAndOpen()
            let note = try XCTUnwrap(session.currentNote)
            let source = NSMutableAttributedString(string: "Custom\n", attributes: [.font: NSFont.systemFont(ofSize: 31)])
            let wrapper = FileWrapper(regularFileWithContents: Data("unchanged asset".utf8))
            wrapper.preferredFilename = "asset.txt"
            source.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            session.update(document: source, cursorLocation: 0)
            let revision = session.contentRevision(for: note.id)
            let replacement = NSMutableAttributedString(attributedString: source)
            replacement.addAttribute(.underlineStyle, value: 1, range: NSRange(location: 0, length: 6))
            try session.createAndOpen()
            let frontID = session.currentNote?.id
            try session.applyAIFormattedDocument(replacement, original: source, expectedRevision: revision, noteID: note.id)
            XCTAssertEqual(session.currentNote?.id, frontID)
            let loaded = try documents.load(id: note.id)
            XCTAssertEqual((loaded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 31)
            let attachment = try XCTUnwrap(loaded.attribute(.attachment, at: 7, effectiveRange: nil) as? NSTextAttachment)
            XCTAssertEqual(attachment.fileWrapper?.regularFileContents, Data("unchanged asset".utf8))
        }
    }

    func testBackupRejectsRTFDAttachmentTraversal() throws {
        try withSession { _, _, documents, session in
            try session.createAndOpen()
            let note = try XCTUnwrap(session.currentNote)
            let wrapper = FileWrapper(regularFileWithContents: Data("asset".utf8))
            wrapper.preferredFilename = "asset.txt"
            _ = try session.importContent(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)),
                into: note.id, at: .end)
            let backup = documents.root.appending(path: "Export")
            try session.exportBackup(to: backup)
            let rtf = backup.appending(path: "Documents/\(note.id.uuidString).rtfd/TXT.rtf")
            let contents = try String(contentsOf: rtf, encoding: .isoLatin1)
            XCTAssertTrue(contents.contains("asset.txt"))
            try contents.replacingOccurrences(of: "asset.txt", with: "../asset.txt").write(to: rtf, atomically: true, encoding: .isoLatin1)
            XCTAssertThrowsError(try session.importBackup(from: backup))
        }
    }

    func testBackupSettingsAreAllowlistedAndNeverOverwriteLocalPreferences() throws {
        try withSession { _, repository, documents, session in
            try session.createAndOpen()
            let suite = "QuickNote.P04Settings.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("sage", forKey: "appearance.noteTheme")
            defaults.set("secret-marker", forKey: "ai.apiKey")
            defaults.set("https://user:secret@example.com", forKey: "ai.baseURL")
            defaults.set("Remote", forKey: "ai.slot.0.name")
            defaults.set("openAI", forKey: "ai.slot.0.provider")
            defaults.set("https://api.example.com/v1", forKey: "ai.slot.0.baseURL")
            defaults.set("model-v1", forKey: "ai.slot.0.model")
            defaults.set(["text", "image"], forKey: "ai.slot.0.inputModalities")
            defaults.set("https://user:secret@example.com", forKey: "ai.slot.1.baseURL")
            defaults.set("https://example.com?key=secret", forKey: "ai.slot.2.baseURL")
            defaults.set(0, forKey: "ai.activeSlot")
            defaults.set(1, forKey: "ai.routing.text")
            defaults.set(2, forKey: "ai.routing.image")
            defaults.set(true, forKey: "ai.routing.automaticFallback")
            let backup = documents.root.appending(path: "Export")
            try repository.exportBackup(to: backup, documents: documents, defaults: defaults)
            let manifest = try String(contentsOf: backup.appending(path: "manifest.json"), encoding: .utf8)
            XCTAssertFalse(manifest.contains("secret"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any])
            let settings = try XCTUnwrap(json["settings"] as? [String: Any])
            XCTAssertEqual(settings["ai.slot.0.baseURL"] as? String, "https://api.example.com/v1")
            XCTAssertEqual(settings["ai.slot.0.inputModalities"] as? [String], ["text", "image"])
            XCTAssertEqual(settings["ai.activeSlot"] as? Int, 0)
            XCTAssertNil(settings["ai.slot.1.baseURL"])
            XCTAssertNil(settings["ai.slot.2.baseURL"])
            defaults.set("paper", forKey: "appearance.noteTheme")
            defaults.set("existing-model", forKey: "ai.slot.0.model")
            defaults.removeObject(forKey: "ai.activeSlot")
            defaults.removeObject(forKey: "ai.routing.image")
            _ = try repository.importBackup(from: backup, documents: documents, defaults: defaults, save: repository.save)
            XCTAssertEqual(defaults.string(forKey: "appearance.noteTheme"), "paper")
            XCTAssertEqual(defaults.string(forKey: "ai.slot.0.model"), "existing-model")
            XCTAssertEqual(defaults.object(forKey: "ai.activeSlot") as? Int, 0)
            XCTAssertEqual(defaults.object(forKey: "ai.routing.image") as? Int, 2)
            for invalid: [String: Any] in [["ai.activeSlot": 6], ["ai.routing.automaticFallback": "true"],
                ["ai.slot.0.inputModalities": ["text", "invalid"]], ["ai.slot.0.baseURL": "https://example.com?auth=secret"]] {
                var malformed = json
                malformed["settings"] = invalid
                try JSONSerialization.data(withJSONObject: malformed).write(to: backup.appending(path: "manifest.json"))
                XCTAssertThrowsError(try session.importBackup(from: backup))
            }
        }
    }

    func testIndexPublishesValueSnapshotOnlyAfterSavingAndRetrying() throws {
        try withSession { _, repository, documents, _ in
            var failSave = false
            let session = NoteSession(repository: repository, documents: documents, saveRepository: {
                if failSave { throw CocoaError(.fileWriteUnknown) }
                try repository.save()
            })
            try session.createAndOpen()
            let id = try XCTUnwrap(session.currentNote?.id)
            var snapshots: [NoteIndexSnapshot] = []
            session.onIndexChange = { change, _ in
                if case .saved(let snapshot) = change { snapshots.append(snapshot) }
            }
            failSave = true
            session.update(document: NSAttributedString(string: "已编辑的合成正文"), cursorLocation: 0)
            XCTAssertThrowsError(try session.flush())
            XCTAssertTrue(session.isDirty)
            XCTAssertTrue(snapshots.isEmpty)

            failSave = false
            try session.flush()
            let snapshot = try XCTUnwrap(snapshots.first)
            XCTAssertEqual(snapshot.noteID, id)
            XCTAssertEqual(snapshot.text, "已编辑的合成正文")
            XCTAssertEqual(snapshot.revision, session.contentRevision(for: id))
            session.update(document: NSAttributedString(string: "后续草稿"), cursorLocation: 0)
            XCTAssertEqual(snapshots.count, 1)
            XCTAssertEqual(snapshot.text, "已编辑的合成正文")
            try session.flush()
            XCTAssertEqual(snapshots.last?.text, "后续草稿")
        }
    }

    func testIndexSensitivityAndDeletionPublishImmediateChanges() throws {
        try withSession { _, _, _, session in
            try session.createAndOpen()
            try session.appendPlainText("用于索引的合成正文")
            let note = try XCTUnwrap(session.currentNote)
            var changes: [NoteIndexChange] = []
            var ineligibleIDs: [UUID] = []
            session.onIndexChange = { change, immediately in
                XCTAssertTrue(immediately)
                changes.append(change)
            }
            session.prepareSensitiveIndexRemoval = { id in
                XCTAssertEqual(id, note.id)
                XCTAssertTrue(note.isEligibleForAI, "缓存清理在提交敏感标记前完成")
            }
            session.onNoteBecameIneligibleForAI = { id in
                XCTAssertFalse(session.isEligibleForAI(noteID: id))
                ineligibleIDs.append(id)
            }
            defer { session.onNoteBecameIneligibleForAI = nil }
            try session.setSensitive(true, for: note)
            guard case .removed(let removedID)? = changes.last else { return XCTFail("敏感标记应移除索引") }
            XCTAssertEqual(removedID, note.id)
            XCTAssertEqual(ineligibleIDs, [note.id])
            try session.setSensitive(false, for: note)
            guard case .saved(let restored)? = changes.last else { return XCTFail("取消标记应更新索引") }
            XCTAssertEqual(restored.text, "用于索引的合成正文")

            // Switch away so deletion does not implicitly create a new note.
            session.onIndexChange = nil
            try session.createAndOpen()
            session.onIndexChange = { change, immediately in
                XCTAssertTrue(immediately)
                changes.append(change)
            }
            XCTAssertTrue(session.deleteRecovering(note))
            guard case .removed(let deletedID)? = changes.last else { return XCTFail("删除应移除索引") }
            XCTAssertEqual(deletedID, note.id)
            try session.restoreDeleted(note)
            guard case .saved(let recovered)? = changes.last else { return XCTFail("恢复应更新索引") }
            XCTAssertEqual(recovered.noteID, note.id)
            XCTAssertEqual(recovered.revision, session.contentRevision(for: note.id))
        }
    }

    private func withSession(_ body: (ModelContainer, NoteRepository, NoteDocumentStore, NoteSession) throws -> Void) throws {
        let (container, repository) = try makeFolderRepository()
        let documents = NoteDocumentStore(root: FileManager.default.temporaryDirectory.appending(path: "QuickNote-P04-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: documents.root) }
        let suite = "QuickNote.P04Tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = NoteSession(repository: repository, documents: documents, defaults: defaults)
        try body(container, repository, documents, session)
    }
}
