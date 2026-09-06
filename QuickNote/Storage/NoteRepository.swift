import AppKit
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

struct NoteRecoveryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private enum BackupSetting: Codable {
    case string(String), integer(Int), boolean(Bool), strings([String])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else { self = .strings(try container.decode([String].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        }
    }

    var value: Any {
        switch self {
        case .string(let value): value
        case .integer(let value): value
        case .boolean(let value): value
        case .strings(let value): value
        }
    }
}

@MainActor
struct NoteVersionStore {
    let root: URL
    static let limit = 20

    func directory(for noteID: UUID) -> URL {
        root.appending(path: "History/\(noteID.uuidString)")
    }

    func versions(for noteID: UUID) throws -> [NoteVersion] {
        let folder = directory(for: noteID)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        _ = try NoteBackup.validateTree(folder)
        let data = try Data(contentsOf: folder.appending(path: "index.json"))
        let versions = try JSONDecoder().decode([NoteVersion].self, from: data)
        guard versions.count <= Self.limit, Set(versions.map(\.id)).count == versions.count,
              versions.allSatisfy({ $0.date.timeIntervalSince1970.isFinite && !$0.reason.isEmpty }) else {
            throw NoteRecoveryError(message: "版本索引损坏，请先备份存储目录。")
        }
        return versions.sorted { $0.date > $1.date }
    }

    func checkpoint(_ document: NSAttributedString, for noteID: UUID, reason: String) throws {
        let previous = try versions(for: noteID)
        // ponytail: at most one ordinary checkpoint per minute; tune only if recovery granularity requires it.
        if reason == "save", let latest = previous.first, Date.now.timeIntervalSince(latest.date) < 60 { return }
        let version = NoteVersion(id: UUID(), date: .now, reason: reason)
        let store = NoteDocumentStore(root: directory(for: noteID))
        try store.save(document, id: version.id)
        let retained = Array(([version] + previous).prefix(Self.limit))
        do {
            try JSONEncoder().encode(retained).write(to: store.root.appending(path: "index.json"), options: .atomic)
        } catch {
            try? store.delete(id: version.id)
            throw error
        }
        for expired in previous.dropFirst(Self.limit - 1) { try store.delete(id: expired.id) }
    }

    func load(_ version: NoteVersion, for noteID: UUID) throws -> NSAttributedString {
        guard try versions(for: noteID).contains(where: { $0.id == version.id }) else {
            throw NoteRecoveryError(message: "此版本已不存在，请刷新版本列表。")
        }
        return try NoteDocumentStore(root: directory(for: noteID)).load(id: version.id)
    }
}

/// A JSON manifest plus native RTFD packages. No keyed archives or settings-domain dumps.
@MainActor
private struct NoteBackup {
    struct Folder: Codable {
        let id: UUID
        let name: String
        let createdAt: Date
    }
    struct Note: Codable {
        let id: UUID
        let title: String
        let plainText: String
        let documentPath: String
        let createdAt: Date
        let updatedAt: Date
        let deletedAt: Date?
        let isPinned: Bool
        let cursorLocation: Int
        let tags: [String]
        let folderID: UUID?
        let versions: [NoteVersion]
    }
    struct Manifest: Codable {
        let formatVersion: Int
        let folders: [Folder]
        let notes: [Note]
        let settings: [String: BackupSetting]
    }

    static var settingKeys: [String] {
        ["appearance.noteTheme", "ai.activeSlot", "ai.routing.text", "ai.routing.image", "ai.routing.automaticFallback"]
            + AIProfileSlot.allCases.flatMap { slot in
                ["name", "provider", "baseURL", "model", "inputModalities"].map { "ai.slot.\(slot.rawValue).\($0)" }
            }
    }

    static func validSetting(_ key: String, _ value: BackupSetting) -> Bool {
        if key == "appearance.noteTheme", case .string(let theme) = value { return NoteTheme(rawValue: theme) != nil }
        if ["ai.activeSlot", "ai.routing.text", "ai.routing.image"].contains(key), case .integer(let slot) = value {
            return AIProfileSlot(rawValue: slot) != nil
        }
        if key == "ai.routing.automaticFallback", case .boolean = value { return true }
        let parts = key.split(separator: ".")
        guard parts.count == 4, parts[0] == "ai", parts[1] == "slot",
              let slot = Int(parts[2]), AIProfileSlot(rawValue: slot) != nil,
              String(slot) == parts[2] else { return false }
        switch (parts[3], value) {
        case ("name", .string(let name)):
            return name.count <= 30 && name.rangeOfCharacter(from: .controlCharacters) == nil
        case ("provider", .string(let provider)): return AIProvider(rawValue: provider) != nil
        case ("model", .string(let model)):
            return !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.count <= 200
                && model.rangeOfCharacter(from: .controlCharacters) == nil
        case ("baseURL", .string(let value)):
            guard value.count <= 2_048, let url = URLComponents(string: value),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else { return false }
            return url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host))
        case ("inputModalities", .strings(let values)):
            return values.contains("text") && values.count <= AIInputModality.allCases.count
                && Set(values).count == values.count && values.allSatisfy { AIInputModality(rawValue: $0) != nil }
        default: return false
        }
    }

    // Limits apply before any RTF parsing or import writes into the library.
    static func validateTree(_ root: URL) throws -> Set<String> {
        guard root.isFileURL else { throw NoteRecoveryError(message: "请选择本地备份目录。") }
        var entries = Set<String>()
        var bytes = 0
        func visit(_ url: URL, path: String, depth: Int) throws {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey,
                .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isAliasFile != true,
                  depth <= 32, entries.count < 10_000 else {
                throw NoteRecoveryError(message: "备份含链接或层级／文件数量超限：\(path)")
            }
            if !path.isEmpty { entries.insert(path) }
            if values.isDirectory == true {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    let name = child.lastPathComponent
                    guard name != ".", name != "..", !name.contains("\\"),
                          !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                        throw NoteRecoveryError(message: "备份包含不安全的文件名。")
                    }
                    try visit(child, path: path.isEmpty ? name : path + "/" + name, depth: depth + 1)
                }
            } else {
                guard !path.isEmpty, values.isRegularFile == true else {
                    throw NoteRecoveryError(message: "备份必须是目录，且只能包含普通文件：\(path)")
                }
                let size = values.fileSize ?? 0
                bytes += size
                let links = try FileManager.default.attributesOfItem(atPath: url.path)[.referenceCount] as? NSNumber
                guard size <= 64 * 1_024 * 1_024, bytes <= 512 * 1_024 * 1_024,
                      (links?.intValue ?? 1) == 1 else {
                    throw NoteRecoveryError(message: "备份文件超限或包含硬链接：\(path)")
                }
            }
        }
        try visit(root, path: "", depth: 0)
        return entries
    }

    static func validate(_ root: URL) throws -> Manifest {
        let paths = try validateTree(root)
        let manifestURL = root.appending(path: "manifest.json")
        let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 8 * 1_024 * 1_024 else { throw NoteRecoveryError(message: "备份清单超过 8 MB。") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let folderIDs = Set(manifest.folders.map(\.id))
        guard manifest.formatVersion == 1,
              folderIDs.count == manifest.folders.count,
              Set(manifest.notes.map(\.id)).count == manifest.notes.count,
              manifest.folders.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.name.count <= 1_024 && $0.createdAt.timeIntervalSince1970.isFinite }),
              manifest.settings.allSatisfy({ validSetting($0.key, $0.value) }) else {
            throw NoteRecoveryError(message: "备份格式、文件夹或设置清单无效。")
        }
        var roots = [String]()
        var allowed: Set<String> = ["manifest.json", "Documents", "History"]
        for note in manifest.notes {
            guard note.documentPath == "\(note.id.uuidString).rtfd",
                  note.folderID.map(folderIDs.contains) ?? true,
                  note.cursorLocation >= 0, note.title.count <= 100_000,
                  note.createdAt.timeIntervalSince1970.isFinite, note.updatedAt.timeIntervalSince1970.isFinite,
                  note.deletedAt?.timeIntervalSince1970.isFinite ?? true,
                  note.versions.count <= NoteVersionStore.limit,
                  Set(note.versions.map(\.id)).count == note.versions.count,
                  note.versions.allSatisfy({ $0.date.timeIntervalSince1970.isFinite
                      && ["save", "import", "aiFormatting", "restore"].contains($0.reason) }) else {
                throw NoteRecoveryError(message: "便签“\(note.title)”的清单无效（路径、日期或版本）。")
            }
            roots.append("Documents/\(note.documentPath)")
            allowed.insert("History/\(note.id.uuidString)")
            for version in note.versions {
                roots.append("History/\(note.id.uuidString)/\(version.id.uuidString).rtfd")
            }
        }
        guard paths.allSatisfy({ path in allowed.contains(path)
            || roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) }) else {
            throw NoteRecoveryError(message: "备份包含清单之外的文件。")
        }
        // Parse every declared document/version only after validating the entire tree.
        for note in manifest.notes {
            do {
                let doc = try NoteDocumentStore(root: root.appending(path: "Documents")).load(id: note.id)
                guard doc.string == note.plainText, note.cursorLocation <= doc.length else {
                    throw NoteRecoveryError(message: "正文或光标与清单不一致。")
                }
                for version in note.versions {
                    _ = try NoteDocumentStore(root: root.appending(path: "History/\(note.id.uuidString)")).load(id: version.id)
                }
            } catch {
                throw NoteRecoveryError(message: "备份中的便签“\(note.title)”缺失或损坏：\(error.localizedDescription)")
            }
        }
        return manifest
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

    func delete(_ note: NoteRecord) { note.deletedAt = .now }

    func restoreDeleted(_ note: NoteRecord) { note.deletedAt = nil }

    func deletedNotes() throws -> [NoteRecord] {
        try notesIncludingDeleted().filter { $0.deletedAt != nil }
            .sorted { $0.deletedAt! > $1.deletedAt! }
    }

    func notesIncludingDeleted() throws -> [NoteRecord] {
        try context.fetch(FetchDescriptor<NoteRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
    }

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
        for note in try notesIncludingDeleted() where note.folderID == folder.id {
            note.folderID = nil
        }
        context.delete(folder)
    }

    func allNotes() throws -> [NoteRecord] {
        try notesIncludingDeleted().filter { $0.deletedAt == nil }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func recentNotes(limit: Int = 6) throws -> [NoteRecord] {
        Array(try notesIncludingDeleted().filter { $0.deletedAt == nil }.prefix(max(0, limit)))
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

    func exportBackup(to destination: URL, documents: NoteDocumentStore, defaults: UserDefaults) throws {
        let fm = FileManager.default
        guard destination.isFileURL, !fm.fileExists(atPath: destination.path),
              (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw NoteRecoveryError(message: "请选择新的备份目录名称；不会覆盖已有文件。")
        }
        let stage = destination.deletingLastPathComponent().appending(path: ".quicknote-export-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage.appending(path: "Documents"), withIntermediateDirectories: false)
        let history = NoteVersionStore(root: documents.root)
        var notes: [NoteBackup.Note] = []
        for note in try notesIncludingDeleted() {
            do {
                guard note.documentPath == "\(note.id.uuidString).rtfd" else {
                    throw NoteRecoveryError(message: "文档路径无效。")
                }
                let source = documents.root.appending(path: note.documentPath)
                _ = try NoteBackup.validateTree(source)
                let document = try documents.load(id: note.id)
                try fm.copyItem(at: source, to: stage.appending(path: "Documents/\(note.documentPath)"))
                let versions = try history.versions(for: note.id)
                if !versions.isEmpty {
                    let target = stage.appending(path: "History/\(note.id.uuidString)")
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    for version in versions {
                        _ = try history.load(version, for: note.id)
                        let filename = "\(version.id.uuidString).rtfd"
                        try fm.copyItem(at: history.directory(for: note.id).appending(path: filename),
                            to: target.appending(path: filename))
                    }
                }
                notes.append(.init(id: note.id, title: note.title, plainText: document.string,
                    documentPath: note.documentPath, createdAt: note.createdAt, updatedAt: note.updatedAt,
                    deletedAt: note.deletedAt, isPinned: note.isPinned,
                    cursorLocation: min(max(0, note.cursorLocation), document.length),
                    tags: note.tags, folderID: note.folderID, versions: versions))
            } catch {
                throw NoteRecoveryError(message: "无法备份便签“\(note.title)”：\(error.localizedDescription) 请先检查原文档。")
            }
        }
        let folders = try allFolders().map { NoteBackup.Folder(id: $0.id, name: $0.name, createdAt: $0.createdAt) }
        var settings: [String: BackupSetting] = [:]
        for key in NoteBackup.settingKeys {
            guard let object = defaults.object(forKey: key),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed),
                  let setting = try? JSONDecoder().decode(BackupSetting.self, from: data),
                  NoteBackup.validSetting(key, setting) else { continue }
            settings[key] = setting
        }
        let manifest = NoteBackup.Manifest(formatVersion: 1, folders: folders, notes: notes, settings: settings)
        try JSONEncoder().encode(manifest).write(to: stage.appending(path: "manifest.json"), options: .atomic)
        _ = try NoteBackup.validate(stage)
        try fm.moveItem(at: stage, to: destination)
    }

    func importBackup(from source: URL, documents: NoteDocumentStore, defaults: UserDefaults,
                      save: () throws -> Void) throws -> Int {
        // Check the source, then validate an isolated copy again to avoid parsing through a swapped link.
        _ = try NoteBackup.validate(source)
        let fm = FileManager.default
        try fm.createDirectory(at: documents.root, withIntermediateDirectories: true)
        let stage = fm.temporaryDirectory.appending(path: ".quicknote-import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: source, to: stage)
        let manifest = try NoteBackup.validate(stage)
        var insertedNotes: [NoteRecord] = []
        var insertedFolders: [NoteFolder] = []
        var newPaths: [URL] = []
        let historyRoot = documents.root.appending(path: "History")
        let hadHistoryRoot = fm.fileExists(atPath: historyRoot.path)
        do {
            var folderMap: [UUID: UUID] = [:]
            for folder in manifest.folders {
                var name = folder.name
                var suffix = 1
                while try allFolders().contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    name = "\(folder.name) (导入 \(suffix))"
                    suffix += 1
                }
                let created = try createFolder(named: name)
                insertedFolders.append(created)
                created.createdAt = folder.createdAt
                folderMap[folder.id] = created.id
            }
            for entry in manifest.notes {
                let note = createNote()
                insertedNotes.append(note)
                note.title = entry.title
                note.plainText = entry.plainText
                note.createdAt = entry.createdAt
                note.updatedAt = entry.updatedAt
                note.deletedAt = entry.deletedAt
                note.isPinned = entry.isPinned
                note.cursorLocation = entry.cursorLocation
                note.tags = entry.tags
                note.folderID = entry.folderID.flatMap { folderMap[$0] }
                let target = documents.root.appending(path: note.documentPath)
                guard !fm.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
                try fm.moveItem(at: stage.appending(path: "Documents/\(entry.documentPath)"), to: target)
                newPaths.append(target)
                if !entry.versions.isEmpty {
                    let folder = NoteVersionStore(root: documents.root).directory(for: note.id)
                    try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard !fm.fileExists(atPath: folder.path) else { throw CocoaError(.fileWriteFileExists) }
                    try fm.moveItem(at: stage.appending(path: "History/\(entry.id.uuidString)"), to: folder)
                    newPaths.append(folder)
                    try JSONEncoder().encode(entry.versions).write(to: folder.appending(path: "index.json"), options: .atomic)
                }
            }
            try save()
        } catch {
            // Never context.rollback(): other callers may have unrelated unsaved metadata edits.
            for note in insertedNotes { context.delete(note) }
            for folder in insertedFolders { context.delete(folder) }
            var cleanupFailures: [String] = []
            for path in newPaths.reversed() {
                do { try fm.removeItem(at: path) } catch { cleanupFailures.append(path.path) }
            }
            if !hadHistoryRoot, (try? fm.contentsOfDirectory(atPath: historyRoot.path).isEmpty) == true {
                try? fm.removeItem(at: historyRoot)
            }
            if !cleanupFailures.isEmpty {
                throw NoteRecoveryError(message: "导入失败：\(error.localizedDescription)。请检查未清理的新文件：\(cleanupFailures.joined(separator: ", "))")
            }
            throw error
        }
        // Only fill absent, explicitly allowlisted local preferences; never replace current settings or read Keychain.
        for (key, value) in manifest.settings where defaults.object(forKey: key) == nil { defaults.set(value.value, forKey: key) }
        return insertedNotes.count
    }

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
