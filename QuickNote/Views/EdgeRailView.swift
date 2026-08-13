import SwiftUI

struct EdgeRailView: View {
    static let maximumNotes = 6
    static let collapsedSize = NSSize(width: 8, height: 40)

    static func expandedSize(noteCount: Int) -> NSSize {
        NSSize(width: 18, height: CGFloat(min(noteCount, maximumNotes) * 16 + 28))
    }

    let notes: [NoteRecord]
    let preview: (NoteRecord?) -> Void
    let select: (NoteRecord) -> Void
    let expandedChanged: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Group {
            if expanded {
                VStack(spacing: 0) {
                    ForEach(notes.prefix(Self.maximumNotes)) { note in
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
                .frame(width: Self.expandedSize(noteCount: notes.count).width)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            } else {
                Capsule()
                    .fill(Color.secondary.opacity(0.32))
                    .frame(width: Self.collapsedSize.width, height: Self.collapsedSize.height)
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: expanded
        )
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                expanded = hovering
            }
            expandedChanged(hovering)
            if !hovering { preview(nil) }
        }
    }
}
