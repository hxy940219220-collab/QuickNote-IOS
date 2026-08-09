import Foundation

struct PanelStateMachine {
    enum State: Equatable {
        case hidden
        case transient(UUID)
        case editing(UUID)
    }

    enum Event {
        case toggleCommand(noteID: UUID)
        case select(noteID: UUID)
        case hover(noteID: UUID)
        case editorActivated
        case pointerExited
        case dismiss
    }

    private(set) var state: State = .hidden

    mutating func send(_ event: Event) {
        switch (state, event) {
        case (_, let .select(id)):
            state = .editing(id)
        case (_, .dismiss), (.transient, .toggleCommand), (.editing, .toggleCommand):
            state = .hidden
        case (.hidden, let .toggleCommand(id)):
            state = .editing(id)
        case (.hidden, let .hover(id)), (.transient, let .hover(id)):
            state = .transient(id)
        case (let .transient(id), .editorActivated):
            state = .editing(id)
        case (.transient, .pointerExited):
            state = .hidden
        default:
            break
        }
    }
}
