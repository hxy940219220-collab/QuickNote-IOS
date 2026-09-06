import AppKit
import Combine

struct NoteReadError: LocalizedError {
    let title: String
    let url: URL
    let reason: String

    var errorDescription: String? { "无法读取“\(title)”：\(reason)" }
}

struct NoteContentAppliedError: LocalizedError {
    let contentApplied = true
    let underlyingError: any Error
    var errorDescription: String? { "内容已应用，但保存未完成。请重试保存，不要再次导入。\n\(underlyingError.localizedDescription)" }
}

@MainActor
final class NoteSession: ObservableObject {
    @Published private(set) var currentNote: NoteRecord?
    @Published private(set) var document = NSAttributedString(string: "")
    @Published private(set) var isDirty = false
    @Published private(set) var saveError: (any Error)?
    @Published private(set) var readError: NoteReadError?
    @Published private(set) var tags: [String] = []
    @Published private(set) var externalEditRevision: Int = 0

    private let repository: NoteRepository
    private let documents: NoteDocumentStore
    private let saveRepository: () throws -> Void
    private var saveTask: Task<Void, Never>?
    private var pendingOperation: PendingOperation?
    private var contentRevisions: [UUID: Int] = [:]
    private var importCursors: [UUID: (location: Int, revision: Int)] = [:]
    private var persistedDocumentData: Data?
    private var externalSavePending = false
    private var history: NoteVersionStore { NoteVersionStore(root: documents.root) }
    private let defaults: UserDefaults

    var onSaved: (() -> Void)?

    func documentURL(for note: NoteRecord) -> URL {
        documents.root.appending(path: note.documentPath)
    }

    init(
        repository: NoteRepository,
        documents: NoteDocumentStore,
        saveRepository: (() throws -> Void)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.documents = documents
        self.saveRepository = saveRepository ?? repository.save
        self.defaults = defaults
    }

    func createAndOpen() throws {
        try performNew(.create(PendingCreate()))
    }

    func open(_ note: NoteRecord) throws {
        try performNew(.open(note))
    }

    func openMostRecentReadableNote() throws {
        var firstReadError: NoteReadError?
        defer {
            if let firstReadError { readError = firstReadError }
        }
        for note in try repository.recentNotes(limit: .max) {
            do {
                try open(note)
                return
            } catch let error as NoteReadError {
                firstReadError = firstReadError ?? error
            }
        }
        try createAndOpen()
    }

    func dismissReadError() { readError = nil }

    func contentRevision(for noteID: UUID) -> Int {
        contentRevisions[noteID, default: 0]
    }

    func documentSnapshot(for noteID: UUID) throws -> NSAttributedString {
        let note = try editableNote(noteID)
        let source = currentNote?.id == noteID ? document : try loadDocument(for: note)
        return NSAttributedString(attributedString: source)
    }

    func deletedNotes() throws -> [NoteRecord] { try repository.deletedNotes() }

    func restoreDeleted(_ note: NoteRecord) throws {
        try requireNoPendingOperation()
        guard try repository.deletedNotes().contains(where: { $0.id == note.id }) else {
            throw NoteRecoveryError(message: "便签已不在垃圾箱，请刷新列表。")
        }
        // Verify readability before making the record visible again.
        _ = try documents.load(id: note.id)
        let deletedAt = note.deletedAt
        repository.restoreDeleted(note)
        do { try saveRepository() } catch { note.deletedAt = deletedAt; throw error }
        contentRevisions[note.id, default: 0] += 1
        onSaved?()
    }

    func versions(for noteID: UUID) throws -> [NoteVersion] { try history.versions(for: noteID) }

    func restoreVersion(_ version: NoteVersion, for noteID: UUID) throws {
        try requireNoPendingOperation()
        let note = try editableNote(noteID)
        let replacement = try history.load(version, for: noteID)
        try persistCurrent(notify: false)
        let original = try loadDocument(for: note)
        try history.checkpoint(original, for: noteID, reason: "restore")
        try replaceDocument(replacement, for: note, cursor: min(note.cursorLocation, replacement.length))
        if currentNote?.id != noteID { activate(note, document: replacement) }
        onSaved?()
    }

    func captureImportCursor(for noteID: UUID, at location: Int? = nil) throws -> Int {
        let note = try editableNote(noteID)
        let revision = contentRevision(for: noteID)
        importCursors[noteID] = (location ?? note.cursorLocation, revision)
        return revision
    }

    @discardableResult
    func importContent(_ content: NSAttributedString, into noteID: UUID?, at position: NoteImportPosition,
                       expectedRevision: Int? = nil, title: String? = nil) throws -> UUID {
        try requireNoPendingOperation()
        guard content.length > 0 else { throw NoteRecoveryError(message: "没有可导入的内容。") }
        let imported = NSMutableAttributedString(attributedString: content)
        AttachmentPresentation.spaceMediaBlocks(in: imported)
        if position == .newNote {
            if let title {
                let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.count <= 120,
                      title.rangeOfCharacter(from: .newlines) == nil else {
                    throw NoteRecoveryError(message: "请填写 1–120 字的单行便签标题。")
                }
                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = 8
                imported.insert(NSAttributedString(string: title + "\n",
                    attributes: [.font: EditorTextStyle.title.font, .paragraphStyle: style]), at: 0)
            }
            try createAndOpen()
            let note = currentNote!
            try replaceDocument(NoteHeadingNormalizer.normalized(imported, promoteFirstLine: true), for: note, cursor: imported.length)
            return note.id
        }
        guard let noteID else { throw NoteRecoveryError(message: "请明确选择导入目标便签。") }
        let note = try editableNote(noteID)
        if let expectedRevision, contentRevision(for: noteID) != expectedRevision {
            throw AIFormattingError.documentChanged
        }
        let cursor: Int
        if position == .cursor {
            guard let expectedRevision, let captured = importCursors[noteID], captured.revision == expectedRevision else {
                throw NoteRecoveryError(message: "请重新选择插入位置；导入前需要捕获光标和内容版本。")
            }
            cursor = captured.location
        } else { cursor = .max }
        try persistCurrent(notify: false)
        let original = try loadDocument(for: note)
        let rawLocation = min(max(0, cursor), original.length)
        let string = original.string as NSString
        let location = rawLocation == original.length ? rawLocation
            : string.rangeOfComposedCharacterSequence(at: rawLocation).location
        let insertion = NSMutableAttributedString()
        let left = string.substring(to: location)
        let right = string.substring(from: location)
        if !left.isEmpty, !left.hasSuffix("\n"), !content.string.hasPrefix("\n") {
            insertion.append(NSAttributedString(string: "\n", attributes: [.font: EditorTextStyle.body.font]))
        }
        insertion.append(NoteHeadingNormalizer.normalized(imported, promoteFirstLine: original.length == 0))
        if !right.isEmpty, !right.hasPrefix("\n"), !content.string.hasSuffix("\n") {
            insertion.append(NSAttributedString(string: "\n", attributes: [.font: EditorTextStyle.body.font]))
        }
        let updated = NSMutableAttributedString(attributedString: original)
        updated.insert(insertion, at: location)
        try history.checkpoint(original, for: noteID, reason: "import")
        try replaceDocument(updated, for: note, cursor: location + insertion.length)
        importCursors[noteID] = nil
        return noteID
    }

    func applyAIFormattedDocument(_ replacement: NSAttributedString, original: NSAttributedString,
                                  expectedRevision: Int, noteID: UUID) throws {
        try requireNoPendingOperation()
        let note = try editableNote(noteID)
        guard contentRevision(for: noteID) == expectedRevision else { throw AIFormattingError.documentChanged }
        let current = currentNote?.id == noteID ? document : try loadDocument(for: note)
        guard replacement.string == original.string,
              try attachmentContent(replacement) == attachmentContent(original),
              try documentsMatch(current, original) else { throw AIFormattingError.documentChanged }
        try persistCurrent(notify: false)
        try history.checkpoint(current, for: noteID, reason: "aiFormatting")
        try replaceDocument(replacement, for: note, cursor: min(note.cursorLocation, replacement.length))
    }

    func exportBackup(to url: URL) throws {
        try requireNoPendingOperation()
        // Do not let a flush hide an already missing/corrupt on-disk document.
        for note in try repository.notesIncludingDeleted() {
            do { _ = try documents.load(id: note.id) }
            catch { throw NoteReadError(title: note.title, url: documentURL(for: note), reason: error.localizedDescription) }
        }
        try persistCurrent(notify: false)
        try repository.exportBackup(to: url, documents: documents, defaults: defaults)
    }

    @discardableResult
    func importBackup(from url: URL) throws -> Int {
        try requireNoPendingOperation()
        let count = try repository.importBackup(from: url, documents: documents, defaults: defaults, save: saveRepository)
        onSaved?()
        return count
    }

    private func requireNoPendingOperation() throws {
        if pendingOperation != nil || externalSavePending {
            // The previous operation applied, not the new caller's content. Keep its draft retryable.
            throw NoteRecoveryError(message: "上一项操作尚未保存，本次操作没有执行。请先在便签窗口重试保存，再应用这份草稿。")
        }
    }

    private func editableNote(_ id: UUID) throws -> NoteRecord {
        guard let note = try repository.allNotes().first(where: { $0.id == id }) else {
            throw NoteRecoveryError(message: "目标便签已删除或不存在，请重新选择目标。")
        }
        return note
    }

    private func replaceDocument(_ replacement: NSAttributedString, for note: NoteRecord, cursor: Int) throws {
        var applied = false
        do {
            if currentNote?.id == note.id {
                externalEditRevision += 1
                update(document: replacement, cursorLocation: cursor)
                applied = true
                try flush()
            } else {
                try documents.save(replacement, id: note.id)
                applied = true
                contentRevisions[note.id, default: 0] += 1
                note.cursorLocation = cursor
                updateMetadata(note, document: replacement)
                try saveRepository()
                onSaved?()
            }
        } catch {
            guard applied else { throw error }
            externalSavePending = true
            let failure = NoteContentAppliedError(underlyingError: error)
            saveError = failure
            throw failure
        }
    }

    private func attachmentContent(_ text: NSAttributedString) throws -> [String: Data] {
        let content = NSMutableAttributedString(string: text.string)
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { attachment, range, _ in
            if let attachment { content.addAttribute(.attachment, value: attachment, range: range) }
        }
        return try rtfdContents(content)
    }

    private func updateMetadata(_ note: NoteRecord, document: NSAttributedString) {
        note.plainText = document.string
        note.title = document.string.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { !$0.isEmpty }) ?? "新便签"
        note.updatedAt = .now
    }

    private func documentsMatch(_ lhs: NSAttributedString, _ rhs: NSAttributedString) throws -> Bool {
        if lhs.isEqual(to: rhs) { return true }
        // Native RTFD round-trip includes attachments and supported rich attributes, not just text.
        func canonical(_ text: NSAttributedString) throws -> [String: Data] {
            let restored = try NSAttributedString(data: documentData(text),
                options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
            return try rtfdContents(restored)
        }
        return try canonical(lhs) == canonical(rhs)
    }

    private func rtfdContents(_ text: NSAttributedString) throws -> [String: Data] {
        let wrapper = try text.fileWrapper(from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        var files: [String: Data] = [:]
        func collect(_ wrapper: FileWrapper, path: String) throws {
            if wrapper.isRegularFile, let data = wrapper.regularFileContents { files[path] = data }
            else if wrapper.isDirectory, let children = wrapper.fileWrappers {
                for (name, child) in children { try collect(child, path: path + "/" + name) }
            } else { throw NoteRecoveryError(message: "附件包含不支持的文件类型。") }
        }
        try collect(wrapper, path: "")
        // Compare package contents, not serialized FileWrapper filesystem metadata.
        return files
    }

    private func documentData(_ text: NSAttributedString) throws -> Data {
        try text.data(from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }

    @discardableResult
    func createAndOpenRecovering() -> Bool {
        attemptNew(.create(PendingCreate()))
    }

    @discardableResult
    func openRecovering(_ note: NoteRecord) -> Bool {
        attemptNew(.open(note))
    }

    @discardableResult
    func togglePinnedRecovering(_ note: NoteRecord) -> Bool {
        attemptNew(.setPinned(note, to: !note.isPinned, updatedAt: .now))
    }

    func update(document: NSAttributedString, cursorLocation: Int) {
        guard let note = currentNote else { return }
        self.document = NSAttributedString(attributedString: document)
        note.cursorLocation = cursorLocation
        contentRevisions[note.id, default: 0] += 1
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.retrySave()
        }
    }

    func appendPlainText(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try appendAttributedText(NSAttributedString(string: text, attributes: [.font: EditorTextStyle.body.font]))
    }

    func appendAttributedText(_ text: NSAttributedString) throws {
        guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let updated = NSMutableAttributedString(attributedString: document)
        if !updated.string.isEmpty {
            updated.append(NSAttributedString(
                string: updated.string.hasSuffix("\n") ? "\n" : "\n\n",
                attributes: [.font: EditorTextStyle.body.font]
            ))
        }
        let imported = NSMutableAttributedString(attributedString: text)
        AttachmentPresentation.spaceMediaBlocks(in: imported)
        updated.append(NoteHeadingNormalizer.normalized(imported, promoteFirstLine: document.length == 0))
        update(document: updated, cursorLocation: updated.length)
        try flush()
    }

    func appendImage(_ data: Data, filename: String = "截图.png") throws {
        guard let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = filename
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let size = AttachmentPresentation.scaledSize(
            for: image.size,
            fitting: NSSize(width: 620, height: 480)
        )
        attachment.image = AttachmentPresentation.scaledImage(image, to: size)
        attachment.bounds.size = size
        let content = NSMutableAttributedString()
        if document.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.append(NSAttributedString(
                string: "截图\n",
                attributes: [.font: EditorTextStyle.title.font]
            ))
        }
        content.append(NSAttributedString(attachment: attachment))
        try appendAttributedText(content)
    }

    func saveAIFormattedDocument(
        _ replacement: NSAttributedString,
        replacing original: NSAttributedString,
        expectedRevision: Int,
        for noteID: UUID
    ) throws {
        try applyAIFormattedDocument(replacement, original: original, expectedRevision: expectedRevision, noteID: noteID)
    }

    func setTags(_ values: [String]) {
        guard let note = currentNote else { return }
        let normalized = values.compactMap { value -> String? in
            let tag = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "#")))
            return tag.isEmpty ? nil : String(tag.prefix(24))
        }
        var unique: [String] = []
        for tag in normalized where !unique.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            unique.append(tag)
        }
        note.tags = unique
        tags = unique
        isDirty = true
        retrySave()
    }

    func retrySave() {
        if let pendingOperation {
            _ = attempt(pendingOperation)
            return
        }
        do {
            try persistCurrent(notify: true)
        } catch {
            saveError = error
        }
    }

    func togglePinned(_ note: NoteRecord) throws {
        try performNew(.setPinned(note, to: !note.isPinned, updatedAt: .now))
    }

    @discardableResult
    func deleteRecovering(_ note: NoteRecord) -> Bool {
        guard pendingOperation == nil else { return false }
        do {
            try persistCurrent(notify: false)
            if currentNote?.id == note.id {
                if let replacement = try repository.allNotes().first(where: { $0.id != note.id }) {
                    let loaded = try loadDocument(for: replacement)
                    activate(replacement, document: loaded)
                } else {
                    try createAndOpen()
                }
            }
            repository.delete(note)
            do {
                try saveRepository()
            } catch {
                saveError = error
                return true
            }
            saveError = nil
            onSaved?()
            return true
        } catch {
            if !(error is NoteReadError) { saveError = error }
            return false
        }
    }

    func flush() throws {
        if let pendingOperation {
            try perform(pendingOperation)
        } else {
            try persistCurrent(notify: true)
        }
    }

    private func attempt(_ operation: PendingOperation) -> Bool {
        do {
            try perform(operation)
            return true
        } catch {
            return false
        }
    }

    private func attemptNew(_ operation: PendingOperation) -> Bool {
        guard pendingOperation == nil else { return false }
        return attempt(operation)
    }

    private func performNew(_ operation: PendingOperation) throws {
        if pendingOperation != nil {
            if let saveError { throw saveError }
            throw SessionError.operationPending
        }
        try perform(operation)
    }

    private func perform(_ operation: PendingOperation) throws {
        do {
            try execute(operation)
        } catch {
            // A failed read must not queue a switch or block other healthy notes.
            if error is NoteReadError {
                pendingOperation = nil
                throw error
            }
            pendingOperation = operation
            saveError = error
            throw error
        }
        pendingOperation = nil
        saveError = nil
        readError = nil
        onSaved?()
    }

    private func execute(_ operation: PendingOperation) throws {
        switch operation {
        case let .open(note):
            try persistCurrent(notify: false)
            let loadedDocument = try loadDocument(for: note)
            activate(note, document: loadedDocument)
        case let .create(pending):
            try persistCurrent(notify: false)
            let note = pending.note ?? repository.createNote()
            pending.note = note
            let emptyDocument = NSAttributedString(string: "")
            try documents.save(emptyDocument, id: note.id)
            try saveRepository()
            activate(note, document: emptyDocument)
        case let .setPinned(note, intendedValue, updatedAt):
            try persistCurrent(notify: false)
            note.isPinned = intendedValue
            note.updatedAt = updatedAt
            try saveRepository()
        }
    }

    private func loadDocument(for note: NoteRecord) throws -> NSAttributedString {
        do {
            guard note.deletedAt == nil else { throw NoteRecoveryError(message: "便签在垃圾箱中，请先恢复。") }
            return try documents.load(id: note.id)
        } catch {
            let failure = NoteReadError(title: note.title, url: documentURL(for: note),
                                        reason: error.localizedDescription)
            readError = failure
            throw failure
        }
    }

    private func activate(_ note: NoteRecord, document: NSAttributedString) {
        currentNote = note
        self.document = document
        persistedDocumentData = try? documentData(document)
        tags = note.tags
        isDirty = false
    }

    private func persistCurrent(notify: Bool) throws {
        saveTask?.cancel()
        saveTask = nil
        guard let note = currentNote else {
            if externalSavePending {
                try saveRepository()
                externalSavePending = false
                saveError = nil
                if notify { onSaved?() }
            }
            return
        }
        do {
            guard note.deletedAt == nil else { throw NoteRecoveryError(message: "便签已删除，未覆盖正文。") }
            if isDirty {
                let data = try documentData(document)
                if data != persistedDocumentData {
                    let previous = try loadDocument(for: note)
                    try history.checkpoint(previous, for: note.id, reason: "save")
                    try documents.save(document, id: note.id)
                    persistedDocumentData = data
                }
                updateMetadata(note, document: document)
            }
            try saveRepository()
        } catch {
            isDirty = true
            saveError = error
            throw error
        }
        isDirty = false
        externalSavePending = false
        saveError = nil
        if notify { onSaved?() }
    }

    private enum PendingOperation {
        case open(NoteRecord)
        case create(PendingCreate)
        case setPinned(NoteRecord, to: Bool, updatedAt: Date)
    }

    private final class PendingCreate {
        var note: NoteRecord?
    }

    private enum SessionError: Error {
        case operationPending
    }
}
