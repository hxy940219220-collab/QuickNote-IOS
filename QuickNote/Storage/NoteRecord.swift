import Foundation
import SwiftData

@Model
final class NoteRecord {
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

    var tags: [String] {
        get { tagsText.split(separator: "\n").map(String.init) }
        set { tagsText = newValue.joined(separator: "\n") }
    }

    init(id: UUID = UUID(), now: Date = .now) {
        self.id = id
        title = "新便签"
        plainText = ""
        documentPath = "\(id.uuidString).rtfd"
        createdAt = now
        updatedAt = now
        isPinned = false
        cursorLocation = 0
    }
}

@Model
final class NoteFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, now: Date = .now) {
        self.id = id
        self.name = name
        createdAt = now
    }
}
