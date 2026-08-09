import XCTest
@testable import QuickNote

final class PanelStateMachineTests: XCTestCase {
    func testCommandOpenStaysEditingWhenPointerLeaves() {
        let id = UUID()
        var machine = PanelStateMachine()
        machine.send(.toggleCommand(noteID: id))
        machine.send(.pointerExited)
        XCTAssertEqual(machine.state, .editing(id))
    }

    func testHoverOpenClosesWhenPointerLeavesBeforeEditing() {
        let id = UUID()
        var machine = PanelStateMachine()
        machine.send(.hover(noteID: id))
        machine.send(.pointerExited)
        XCTAssertEqual(machine.state, .hidden)
    }

    func testTypingPromotesTransientPanelToEditing() {
        let id = UUID()
        var machine = PanelStateMachine()
        machine.send(.hover(noteID: id))
        machine.send(.editorActivated)
        XCTAssertEqual(machine.state, .editing(id))
    }

    func testHoverCannotReplaceAnEditingNote() {
        let editingID = UUID()
        var machine = PanelStateMachine()
        machine.send(.toggleCommand(noteID: editingID))
        machine.send(.hover(noteID: UUID()))
        XCTAssertEqual(machine.state, .editing(editingID))
    }

    func testRailSelectionReplacesTheActiveNoteAndStaysEditing() {
        let firstID = UUID()
        let secondID = UUID()
        var machine = PanelStateMachine()
        machine.send(.toggleCommand(noteID: firstID))

        machine.send(.select(noteID: secondID))

        XCTAssertEqual(machine.state, .editing(secondID))
    }
}
