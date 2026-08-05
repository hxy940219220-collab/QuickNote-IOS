import AppKit

@MainActor
final class PanelCoordinator {
    private var machine = PanelStateMachine()
    private let panel: NotePanelController
    private let session: NoteSession
    private let repository: NoteRepository
    private var dismissTask: Task<Void, Never>?

    init(panel: NotePanelController, session: NoteSession, repository: NoteRepository) {
        self.panel = panel
        self.session = session
        self.repository = repository
    }

    func toggleFromCommand() throws {
        dismissTask?.cancel()
        let note: NoteRecord
        if let currentNote = session.currentNote {
            note = currentNote
        } else {
            note = try repository.recentNotes(limit: 1).first ?? repository.createNote()
        }
        machine.send(.toggleCommand(noteID: note.id))
        try render(note: note, activate: true)
    }

    func hover(note: NoteRecord) throws {
        if case .editing = machine.state { return }
        dismissTask?.cancel()
        machine.send(.hover(noteID: note.id))
        try render(note: note, activate: false)
    }

    func activateEditor() {
        dismissTask?.cancel()
        machine.send(.editorActivated)
        session.retrySave()
    }

    func presentCurrentNote() throws {
        guard let note = session.currentNote else { return }
        dismissTask?.cancel()
        switch machine.state {
        case .hidden:
            machine.send(.toggleCommand(noteID: note.id))
        case .transient:
            machine.send(.editorActivated)
        case .editing:
            break
        }
        try render(note: note, activate: true)
    }

    func pointerExited() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            machine.send(.pointerExited)
            try? render(note: session.currentNote, activate: false)
        }
    }

    private func render(note: NoteRecord?, activate: Bool) throws {
        switch machine.state {
        case .hidden:
            try session.flush()
            panel.hideAndRestoreFocus()
        case .transient, .editing:
            if let note, session.currentNote?.id != note.id {
                try session.open(note)
            }
            panel.show(activate: activate, on: Self.pointerScreen())
        }
    }

    private static func pointerScreen() -> NSScreen {
        NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main!
    }
}
