import SwiftUI

struct NoteDrawerView: View {
    let notes: [NoteRecord]
    let select: (NoteRecord) -> Void
    let create: () -> Void
    let togglePin: (NoteRecord) -> Void
    @State private var query = ""

    var body: some View {
        VStack(spacing: 8) {
            TextField("搜索全部便签", text: $query)
                .textFieldStyle(.roundedBorder)

            Button("新建便签", action: create)
                .frame(maxWidth: .infinity, alignment: .leading)

            List(filtered) { note in
                HStack {
                    Button(action: { select(note) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title)
                                .lineLimit(1)
                            Text(note.updatedAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button(action: { togglePin(note) }) {
                        Image(systemName: note.isPinned ? "pin.fill" : "pin")
                    }
                    .buttonStyle(.borderless)
                    .help(note.isPinned ? "取消置顶" : "置顶")
                }
            }
        }
        .padding(10)
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
