import SwiftUI

struct NoteDrawerView: View {
    let notes: [NoteRecord]
    let selectedID: UUID?
    let select: (NoteRecord) -> Void
    let create: () -> Void
    let togglePin: (NoteRecord) -> Void
    @State private var query = ""

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
                                Text(note.title)
                                    .fontWeight(note.id == selectedID ? .semibold : .regular)
                                    .lineLimit(1)
                                Text(note.updatedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button(action: { togglePin(note) }) {
                            Image(systemName: note.isPinned ? "pin.fill" : "pin")
                                .foregroundStyle(note.isPinned ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(note.isPinned ? "取消置顶" : "置顶")
                        .accessibilityLabel(note.isPinned ? "取消置顶" : "置顶")
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
