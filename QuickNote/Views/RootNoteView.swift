import SwiftUI

struct RootNoteView: View {
    @ObservedObject var session: NoteSession
    let allNotes: () throws -> [NoteRecord]
    let activateEditor: () -> Void
    @State private var drawerOpen = false
    @State private var notes: [NoteRecord] = []

    var body: some View {
        VStack(spacing: 0) {
            if let error = session.saveError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("保存失败：\(error.localizedDescription)")
                        .lineLimit(2)
                    Spacer()
                    Button("重试", action: session.retrySave)
                }
                .padding(8)
                .foregroundStyle(.white)
                .background(Color.red)
            }

            HStack(spacing: 0) {
                if drawerOpen {
                    NoteDrawerView(notes: notes, select: open, create: create, togglePin: togglePin)
                        .frame(width: 180)
                }

                RichTextEditor(
                    document: session.document,
                    cursorLocation: session.currentNote?.cursorLocation ?? 0,
                    onChange: session.update,
                    onActivate: activateEditor
                )
            }
        }
        .background {
            Button("", action: toggleDrawer)
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
    }

    private func toggleDrawer() {
        notes = (try? allNotes()) ?? []
        drawerOpen.toggle()
    }

    private func open(_ note: NoteRecord) {
        if session.openRecovering(note) { drawerOpen = false }
    }

    private func create() {
        if session.createAndOpenRecovering() { drawerOpen = false }
    }

    private func togglePin(_ note: NoteRecord) {
        if session.togglePinnedRecovering(note) {
            notes = (try? allNotes()) ?? notes
        }
    }
}
