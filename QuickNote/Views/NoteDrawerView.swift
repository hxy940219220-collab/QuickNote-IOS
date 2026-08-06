import SwiftUI

struct NoteDrawerView: View {
    let notes: [NoteRecord]
    let selectedID: UUID?
    let select: (NoteRecord) -> Void
    let create: () -> Void
    let togglePin: (NoteRecord) -> Void
    let delete: (NoteRecord) -> Void
    @State private var query = ""
    @State private var pendingDeletion: NoteRecord?
    @State private var confirmingDeletion = false

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("全部便签")
                    .font(.headline)

                Text("\(notes.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button(action: create) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("新建便签")
                .accessibilityLabel("新建便签")
            }

            TextField("搜索全部便签", text: $query)
                .textFieldStyle(.roundedBorder)

            if filtered.isEmpty {
                ContentUnavailableView {
                    Label("没有找到便签", systemImage: "magnifyingglass")
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { note in
                    HStack(spacing: 6) {
                        Button(action: { select(note) }) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Text(note.title)
                                        .fontWeight(note.id == selectedID ? .semibold : .regular)
                                        .lineLimit(1)
                                    if note.isPinned {
                                        Image(systemName: "pin.fill")
                                            .font(.caption2)
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                Text(note.updatedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Menu {
                            Button(action: { togglePin(note) }) {
                                Label(
                                    note.isPinned ? "取消置顶" : "置顶",
                                    systemImage: note.isPinned ? "pin.slash" : "pin"
                                )
                            }
                            Divider()
                            Button(role: .destructive) {
                                pendingDeletion = note
                                confirmingDeletion = true
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("编辑便签")
                        .accessibilityLabel("编辑便签")
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(
                        note.id == selectedID ? Color.accentColor.opacity(0.1) : Color.clear
                    )
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .alert("删除便签？", isPresented: $confirmingDeletion, presenting: pendingDeletion) { note in
            Button("删除", role: .destructive) {
                delete(note)
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { note in
            Text("“\(note.title)”将被永久删除。")
        }
    }

    private var filtered: [NoteRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedStandardContains(normalized)
                || $0.plainText.localizedStandardContains(normalized)
        }
    }
}
