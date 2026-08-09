import SwiftUI

struct EdgeRailView: View {
    let notes: [NoteRecord]
    let preview: (NoteRecord?) -> Void
    let select: (NoteRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(notes.prefix(8)) { note in
                Button {
                    select(note)
                } label: {
                    Capsule()
                        .fill(note.isPinned ? Color.primary : Color.secondary.opacity(0.45))
                        .frame(width: note.isPinned ? 10 : 8, height: 3)
                        .frame(width: 18, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(note.title)
                .onHover { preview($0 ? note : nil) }
            }
        }
        .padding(.vertical, 14)
        .frame(width: 18)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { if !$0 { preview(nil) } }
    }
}
