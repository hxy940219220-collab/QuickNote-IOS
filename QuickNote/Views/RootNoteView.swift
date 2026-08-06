import SwiftUI

struct RootNoteView: View {
    @ObservedObject var session: NoteSession
    let allNotes: () throws -> [NoteRecord]
    let activateEditor: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

            HStack(spacing: 8) {
                toolbarButton(
                    "便签列表",
                    systemImage: "sidebar.left",
                    action: toggleDrawer
                )
                .keyboardShortcut("k", modifiers: .command)

                Text(session.currentNote?.title ?? "新便签")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if session.saveError == nil {
                    Text(session.isDirty ? "保存中…" : "已保存")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                toolbarButton(
                    session.currentNote?.isPinned == true ? "取消置顶" : "置顶",
                    systemImage: session.currentNote?.isPinned == true ? "pin.fill" : "pin",
                    action: toggleCurrentPin
                )

                toolbarButton("新建便签", systemImage: "square.and.pencil", action: create)
                    .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)

            Divider()

            HStack(spacing: 0) {
                if drawerOpen {
                    NoteDrawerView(
                        notes: notes,
                        selectedID: session.currentNote?.id,
                        select: open,
                        create: create,
                        togglePin: togglePin
                    )
                    .frame(width: 190)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                    Divider()
                }

                ZStack(alignment: .topLeading) {
                    RichTextEditor(
                        document: session.document,
                        cursorLocation: session.currentNote?.cursorLocation ?? 0,
                        onChange: session.update,
                        onActivate: activateEditor
                    )

                    if session.document.string.isEmpty {
                        Text("开始记录…")
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 17)
                            .padding(.top, 13)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func toggleDrawer() {
        notes = (try? allNotes()) ?? []
        setDrawerOpen(!drawerOpen)
    }

    private func open(_ note: NoteRecord) {
        if session.openRecovering(note) { setDrawerOpen(false) }
    }

    private func create() {
        if session.createAndOpenRecovering() { setDrawerOpen(false) }
    }

    private func togglePin(_ note: NoteRecord) {
        if session.togglePinnedRecovering(note) {
            notes = (try? allNotes()) ?? notes
        }
    }

    private func toggleCurrentPin() {
        guard let note = session.currentNote else { return }
        togglePin(note)
    }

    private func setDrawerOpen(_ open: Bool) {
        if reduceMotion {
            drawerOpen = open
        } else {
            withAnimation(.easeOut(duration: 0.16)) { drawerOpen = open }
        }
    }

    private func toolbarButton(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}
