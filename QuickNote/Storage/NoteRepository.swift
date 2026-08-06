import Foundation
import SwiftData

@MainActor
final class NoteRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func createNote() -> NoteRecord {
        let note = NoteRecord()
        context.insert(note)
        return note
    }

    func delete(_ note: NoteRecord) { context.delete(note) }

    func allNotes() throws -> [NoteRecord] {
        try context.fetch(
            FetchDescriptor<NoteRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        ).sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func recentNotes(limit: Int = 8) throws -> [NoteRecord] {
        Array(try allNotes().prefix(limit))
    }

    func search(_ query: String) throws -> [NoteRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return try allNotes() }
        // ponytail: linear scan is enough for personal-scale P0; add FTS only if measured search exceeds 50ms.
        return try allNotes().filter {
            $0.title.localizedStandardContains(normalized) || $0.plainText.localizedStandardContains(normalized)
        }
    }

    func save() throws { try context.save() }
}
