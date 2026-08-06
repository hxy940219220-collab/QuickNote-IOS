import SwiftUI

struct EdgeRailView: View {
    let notes: [NoteRecord]
    let hover: (NoteRecord) -> Void
    let exit: () -> Void

    var body: some View {
        VStack(spacing: 13) {
            ForEach(notes.prefix(8)) { note in
                Capsule()
                    .fill(note.isPinned ? Color.primary : Color.secondary.opacity(0.45))
                    .frame(width: note.isPinned ? 10 : 8, height: 3)
                    .help("\(note.title) · \(note.updatedAt.formatted())\n\(note.plainText.prefix(50))")
                    .onHover { inside in
                        if inside { hover(note) }
                    }
            }
        }
        .padding(.vertical, 14)
        .frame(width: 18)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { inside in
            if !inside { exit() }
        }
    }
}
