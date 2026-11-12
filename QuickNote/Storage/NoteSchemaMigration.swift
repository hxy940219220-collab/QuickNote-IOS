import Foundation
import SwiftData

// These historical schemas describe stores created before schema versioning was introduced.
enum NoteSchemaBeforeOrdering: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [NoteRecord.self, NoteFolder.self] }

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
        var deletedAt: Date? = nil

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
}

enum NoteSchemaBeforeSensitivity: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [NoteRecord.self, NoteFolder.self] }

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
        var deletedAt: Date? = nil
        var manualOrder: Int? = nil
        var pinnedOrder: Int? = nil

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
        var manualOrder: Int? = nil

        init(id: UUID = UUID(), name: String, now: Date = .now) {
            self.id = id
            self.name = name
            createdAt = now
        }
    }
}

enum NoteSchemaWithSensitivity: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] { [NoteRecord.self, NoteFolder.self] }
}

enum NoteSchemaMigration: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [NoteSchemaBeforeOrdering.self, NoteSchemaBeforeSensitivity.self, NoteSchemaWithSensitivity.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: NoteSchemaBeforeOrdering.self, toVersion: NoteSchemaBeforeSensitivity.self),
            .lightweight(fromVersion: NoteSchemaBeforeSensitivity.self, toVersion: NoteSchemaWithSensitivity.self)
        ]
    }

    @MainActor
    static func makeContainer(configuration: ModelConfiguration? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: NoteSchemaWithSensitivity.self)
        return try ModelContainer(for: schema, migrationPlan: Self.self,
                                  configurations: [configuration ?? ModelConfiguration(schema: schema)])
    }
}
