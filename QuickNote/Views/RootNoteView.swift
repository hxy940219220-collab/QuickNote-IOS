import SwiftUI

struct RootNoteView: View {
    @ObservedObject var session: NoteSession
    let allNotes: () throws -> [NoteRecord]
    let activateEditor: () -> Void
    let drawerVisibilityChanged: (Bool) -> Void
    let setWindowLocked: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawerOpen = false
    @State private var windowLocked = false
    @State private var notes: [NoteRecord] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                toolbarButton(
                    "便签列表",
                    systemImage: "sidebar.left",
                    action: toggleDrawer
                )
                .keyboardShortcut("k", modifiers: .command)

                Spacer(minLength: 8)

                if session.saveError == nil {
                    Text(session.isDirty ? "保存中…" : "已保存")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                toolbarButton(
                    windowLocked ? "取消锁定" : "锁定在最前",
                    systemImage: windowLocked ? "lock.fill" : "lock.open",
                    action: toggleWindowLock
                )

                toolbarButton("新建便签", systemImage: "square.and.pencil", action: create)
                    .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.leading, 74)
            .padding(.trailing, 10)
            .frame(height: 38)
            .background(Color(nsColor: .windowBackgroundColor))

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
        .ignoresSafeArea(.container, edges: .top)
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

    private func toggleWindowLock() {
        windowLocked.toggle()
        setWindowLocked(windowLocked)
    }

    private func setDrawerOpen(_ open: Bool) {
        drawerVisibilityChanged(open)
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
