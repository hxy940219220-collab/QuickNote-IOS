import Foundation
import SwiftData

enum FolderNameError: LocalizedError, Equatable {
    case empty
    case duplicate

    var errorDescription: String? {
        switch self {
        case .empty: "请输入文件夹名称。"
        case .duplicate: "已存在同名文件夹。"
        }
    }
}

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

    func allFolders() throws -> [NoteFolder] {
        try context.fetch(
            FetchDescriptor<NoteFolder>(sortBy: [SortDescriptor(\.createdAt)])
        )
    }

    func createFolder(named rawName: String) throws -> NoteFolder {
        let folder = NoteFolder(name: try validatedFolderName(rawName))
        context.insert(folder)
        return folder
    }

    func rename(_ folder: NoteFolder, to rawName: String) throws {
        folder.name = try validatedFolderName(rawName, excluding: folder.id)
    }

    func move(_ note: NoteRecord, to folder: NoteFolder?) {
        note.folderID = folder?.id
    }

    func delete(_ folder: NoteFolder) throws {
        for note in try allNotes() where note.folderID == folder.id {
            note.folderID = nil
        }
        context.delete(folder)
    }

    func allNotes() throws -> [NoteRecord] {
        try context.fetch(
            FetchDescriptor<NoteRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        ).sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func recentNotes(limit: Int = 6) throws -> [NoteRecord] {
        Array(try context.fetch(
            FetchDescriptor<NoteRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        ).prefix(limit))
    }

    func search(_ query: String) throws -> [NoteRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return try allNotes() }
        // ponytail: linear scan is enough for personal-scale P0; add FTS only if measured search exceeds 50ms.
        return try allNotes().filter {
            $0.title.localizedStandardContains(normalized)
                || $0.plainText.localizedStandardContains(normalized)
                || $0.tags.contains { $0.localizedStandardContains(normalized) }
        }
    }

    func save() throws { try context.save() }

    private func validatedFolderName(
        _ rawName: String,
        excluding id: UUID? = nil
    ) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FolderNameError.empty }
        guard try !allFolders().contains(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else { throw FolderNameError.duplicate }
        return name
    }
}
