import AppKit
import Combine

@MainActor
final class NoteSession: ObservableObject {
    @Published private(set) var currentNote: NoteRecord?
    @Published private(set) var document = NSAttributedString(string: "")

    private let repository: NoteRepository
    private let documents: NoteDocumentStore
    private var saveTask: Task<Void, Never>?

    var onSaved: (() -> Void)?

    init(repository: NoteRepository, documents: NoteDocumentStore) {
        self.repository = repository
        self.documents = documents
    }

    func createAndOpen() throws {
        let note = repository.createNote()
        try repository.save()
        try open(note)
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
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            try? self?.flush()
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
        try documents.save(document, id: note.id)
        note.plainText = document.string
        note.title = document.string
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? "新便签"
        note.updatedAt = .now
        try repository.save()
        onSaved?()
    }
}
