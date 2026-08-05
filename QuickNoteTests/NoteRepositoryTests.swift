import SwiftData
import XCTest
@testable import QuickNote

@MainActor
final class NoteRepositoryTests: XCTestCase {
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
}
