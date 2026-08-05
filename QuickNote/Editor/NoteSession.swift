import AppKit
import Combine

@MainActor
final class NoteSession: ObservableObject {
    @Published private(set) var currentNote: NoteRecord?
    @Published private(set) var document = NSAttributedString(string: "")
    @Published private(set) var isDirty = false
    @Published private(set) var saveError: (any Error)?

    private let repository: NoteRepository
    private let documents: NoteDocumentStore
    private var saveTask: Task<Void, Never>?

    var onSaved: (() -> Void)?

    init(repository: NoteRepository, documents: NoteDocumentStore) {
        self.repository = repository
        self.documents = documents
    }

    func createAndOpen() throws {
        try flush()
        let note = repository.createNote()
        try repository.save()
        currentNote = note
        document = try documents.load(id: note.id)
    }

    func open(_ note: NoteRecord) throws {
        try flush()
        let loadedDocument = try documents.load(id: note.id)
        currentNote = note
        document = loadedDocument
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

    func retrySave() {
        do {
            try flush()
        } catch {
            saveError = error
        }
    }

    func togglePinned(_ note: NoteRecord) throws {
        note.isPinned.toggle()
        note.updatedAt = .now
        try repository.save()
        onSaved?()
    }

    func flush() throws {
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
            try repository.save()
        } catch {
            isDirty = true
            saveError = error
            throw error
        }
        isDirty = false
        saveError = nil
        onSaved?()
    }
}
