import AppKit

@MainActor
final class PanelCoordinator {
    private var machine = PanelStateMachine()
    private let panel: NotePanelController
    private let session: NoteSession
    private var dismissTask: Task<Void, Never>?

    init(panel: NotePanelController, session: NoteSession) {
        self.panel = panel
        self.session = session
        panel.onDismiss = { [weak self] in self?.dismissFromWindow() }
        panel.onMiniaturize = { [weak self] in self?.miniaturizeFromWindow() }
    }

    func toggleFromCommand() throws {
        dismissTask?.cancel()
        let isOpening = machine.state == .hidden
        if isOpening {
            CaptureLatencyProbe.begin()
        }
        do {
            if session.currentNote == nil { try session.openMostRecentReadableNote() }
            guard let note = session.currentNote else { return }
            machine.send(.toggleCommand(noteID: note.id))
            try render(note: note, activate: true)
        } catch {
            if isOpening {
                CaptureLatencyProbe.cancel()
            }
            throw error
        }
    }

    func hover(note: NoteRecord) throws {
        if case .editing = machine.state { return }
        dismissTask?.cancel()
        machine.send(.hover(noteID: note.id))
        try render(note: note, activate: false)
    }

    func select(note: NoteRecord) throws {
        dismissTask?.cancel()
        machine.send(.select(noteID: note.id))
        try render(note: note, activate: true)
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

    private func dismissFromWindow() {
        dismissTask?.cancel()
        machine.send(.dismiss)
        try? render(note: session.currentNote, activate: false)
    }

    private func miniaturizeFromWindow() {
        dismissTask?.cancel()
        machine.send(.dismiss)
        session.retrySave()
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
