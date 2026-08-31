import AppKit
import Combine

@MainActor
final class NoteSession: ObservableObject {
    @Published private(set) var currentNote: NoteRecord?
    @Published private(set) var document = NSAttributedString(string: "")
    @Published private(set) var isDirty = false
    @Published private(set) var saveError: (any Error)?
    @Published private(set) var tags: [String] = []

    private let repository: NoteRepository
    private let documents: NoteDocumentStore
    private let saveRepository: () throws -> Void
    private var saveTask: Task<Void, Never>?
    private var pendingOperation: PendingOperation?
    private var pendingDocumentDeletion: UUID?

    var onSaved: (() -> Void)?

    func documentURL(for note: NoteRecord) -> URL {
        documents.root.appending(path: note.documentPath)
    }

    init(
        repository: NoteRepository,
        documents: NoteDocumentStore,
        saveRepository: (() throws -> Void)? = nil
    ) {
        self.repository = repository
        self.documents = documents
        self.saveRepository = saveRepository ?? repository.save
    }

    func createAndOpen() throws {
        try performNew(.create(PendingCreate()))
    }

    func open(_ note: NoteRecord) throws {
        try performNew(.open(note))
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
        self.document = NSAttributedString(attributedString: document)
        currentNote?.cursorLocation = cursorLocation
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
        try appendAttributedText(NSAttributedString(string: text))
    }

    func appendAttributedText(_ text: NSAttributedString) throws {
        guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let updated = NSMutableAttributedString(attributedString: document)
        if !updated.string.isEmpty {
            updated.append(NSAttributedString(string: updated.string.hasSuffix("\n") ? "\n" : "\n\n"))
        }
        updated.append(text)
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
        for note: NoteRecord
    ) throws {
        guard currentNote?.id != note.id,
              try repository.allNotes().contains(where: { $0.id == note.id }),
              try documents.load(id: note.id).string == original.string else {
            throw AIFormattingError.documentChanged
        }
        try documents.save(replacement, id: note.id)
        note.plainText = replacement.string
        note.title = replacement.string
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? "新便签"
        note.updatedAt = .now
        try saveRepository()
        onSaved?()
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
                let replacement = try repository.allNotes().first { $0.id != note.id }
                    ?? repository.createNote()
                currentNote = replacement
                document = try documents.load(id: replacement.id)
                tags = replacement.tags
                isDirty = false
            }
            repository.delete(note)
            pendingDocumentDeletion = note.id
            do {
                try saveRepository()
            } catch {
                saveError = error
                return true
            }
            finishDocumentDeletion()
            saveError = nil
            onSaved?()
            return true
        } catch {
            saveError = error
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
            pendingOperation = operation
            saveError = error
            throw error
        }
        pendingOperation = nil
        saveError = nil
        onSaved?()
    }

    private func execute(_ operation: PendingOperation) throws {
        switch operation {
        case let .open(note):
            try persistCurrent(notify: false)
            let loadedDocument = try documents.load(id: note.id)
            currentNote = note
            document = loadedDocument
            tags = note.tags
        case let .create(pending):
            try persistCurrent(notify: false)
            let note = pending.note ?? repository.createNote()
            pending.note = note
            try saveRepository()
            let loadedDocument = try documents.load(id: note.id)
            currentNote = note
            document = loadedDocument
            tags = note.tags
        case let .setPinned(note, intendedValue, updatedAt):
            try persistCurrent(notify: false)
            note.isPinned = intendedValue
            note.updatedAt = updatedAt
            try saveRepository()
        }
    }

    private func persistCurrent(notify: Bool) throws {
        saveTask?.cancel()
        saveTask = nil
        guard let note = currentNote else { return }
        do {
            try documents.save(document, id: note.id)
            note.plainText = document.string
            note.title = document.string
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty }) ?? "新便签"
            note.updatedAt = .now
            try saveRepository()
            finishDocumentDeletion()
        } catch {
            isDirty = true
            saveError = error
            throw error
        }
        isDirty = false
        saveError = nil
        if notify { onSaved?() }
    }

    private func finishDocumentDeletion() {
        guard let id = pendingDocumentDeletion else { return }
        try? documents.delete(id: id)
        pendingDocumentDeletion = nil
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
