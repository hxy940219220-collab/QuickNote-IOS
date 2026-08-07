import SwiftData
import XCTest
@testable import QuickNote

@MainActor
final class NoteRepositoryTests: XCTestCase {
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

    func testPinnedNotesPrecedeMoreRecentUnpinnedNotes() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let pinned = NoteRecord(now: Date(timeIntervalSince1970: 1))
        pinned.isPinned = true
        let recent = NoteRecord(now: Date(timeIntervalSince1970: 2))
        container.mainContext.insert(pinned)
        container.mainContext.insert(recent)
        try repository.save()
        XCTAssertEqual(try repository.recentNotes(limit: 2).map(\.id), [pinned.id, recent.id])
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

    private func makeFolderRepository() throws -> (ModelContainer, NoteRepository) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: NoteRecord.self,
            NoteFolder.self,
            configurations: configuration
        )
        return (container, NoteRepository(context: container.mainContext))
    }
}
