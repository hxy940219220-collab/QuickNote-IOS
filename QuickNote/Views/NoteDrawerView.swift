import SwiftUI

enum NoteSearchExcerpt {
    static func text(for note: NoteRecord, query: String) -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "" }
        if let tag = note.tags.first(where: { $0.localizedStandardContains(query) }) { return "#\(tag)" }
        let content = note.plainText
        guard let match = content.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return "" }
        let start = content.index(match.lowerBound, offsetBy: -20, limitedBy: content.startIndex) ?? content.startIndex
        let end = content.index(match.upperBound, offsetBy: 40, limitedBy: content.endIndex) ?? content.endIndex
        return (start > content.startIndex ? "…" : "")
            + content[start..<end].replacingOccurrences(of: "\n", with: " ")
            + (end < content.endIndex ? "…" : "")
    }
}

enum NoteDrawerLayout {
    static let noteLeadingIndent: CGFloat = 24
    static let noteRowHeight: CGFloat = 28
    static let folderRowHeight = noteRowHeight
}

struct NoteDrawerView: View {
    let notes: [NoteRecord]
    let folders: [NoteFolder]
    let selectedID: UUID?
    let select: (NoteRecord) -> Void
    let create: () -> Void
    let createFolder: (String) throws -> Void
    let renameFolder: (NoteFolder, String) throws -> Void
    let deleteFolder: (NoteFolder) -> Void
    let move: (NoteRecord, NoteFolder?) -> Void
    let togglePin: (NoteRecord) -> Void
    let delete: (NoteRecord) -> Void
    let theme: NoteTheme
    let search: (String) throws -> [NoteRecord]
    let selectMatch: (NoteRecord, String) -> Void
    let editTags: (NoteRecord) -> Void

    @State private var query = ""
    @State private var expandedFolders = Set<UUID>()
    @State private var creatingFolder = false
    @State private var editingFolder: NoteFolder?
    @State private var pendingDeletion: NoteRecord?
    @State private var confirmingDeletion = false
    @State private var pendingFolderDeletion: NoteFolder?
    @State private var confirmingFolderDeletion = false
    @State private var hoveredNoteID: UUID?
    @State private var matches: [NoteRecord] = []
    @State private var searchError: String?

    var body: some View {
        VStack(spacing: 6) {
            header

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                TextField("搜索标题、正文、标签", text: $query)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 7)
            .frame(height: 27)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
            }

            if isSearching {
                searchResults
            } else if notes.isEmpty && folders.isEmpty {
                ContentUnavailableView {
                    Label("还没有便签", systemImage: "note.text")
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                libraryList
            }
        }
        .padding(8)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Color(nsColor: theme.sidebarBackground))
        .onAppear(perform: expandSelectedFolder)
        .onChange(of: selectedID) { _, _ in expandSelectedFolder() }
        .onChange(of: query) { _, _ in refreshSearch() }
        .onChange(of: notes.map(\.updatedAt)) { _, _ in refreshSearch() }
        .sheet(isPresented: $creatingFolder) {
            FolderNameEditor(
                title: "新建文件夹",
                initialName: "",
                save: createFolder
            )
        }
        .sheet(item: $editingFolder) { folder in
            FolderNameEditor(
                title: "重命名文件夹",
                initialName: folder.name,
                save: { try renameFolder(folder, $0) }
            )
        }
        .alert("删除便签？", isPresented: $confirmingDeletion, presenting: pendingDeletion) { note in
            Button("删除", role: .destructive) {
                delete(note)
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { note in
            Text("“\(note.title)”将移入最近删除，可在设置 → 本地存储中恢复。")
        }
        .alert(
            "删除文件夹？",
            isPresented: $confirmingFolderDeletion,
            presenting: pendingFolderDeletion
        ) { folder in
            Button("删除", role: .destructive) {
                deleteFolder(folder)
                pendingFolderDeletion = nil
            }
            Button("取消", role: .cancel) { pendingFolderDeletion = nil }
        } message: { folder in
            Text("“\(folder.name)”中的便签会移到“未分类”，不会被删除。")
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("全部便签")
                .font(.system(size: 13, weight: .medium))

            Text("\(notes.count)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Button { creatingFolder = true } label: {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .quickNoteHoverHighlight()
            .help("新建文件夹")
            .accessibilityLabel("新建文件夹")

            Button(action: create) {
                Image(systemName: "square.and.pencil")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .quickNoteHoverHighlight()
            .help("新建便签")
            .accessibilityLabel("新建便签")
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if let searchError {
            Text(searchError).font(.caption).foregroundStyle(.secondary)
            Button("重新搜索", action: refreshSearch)
        } else if matches.isEmpty {
            ContentUnavailableView {
                Label("没有找到便签", systemImage: "magnifyingglass")
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(matches) { note in
                noteRow(note)
            }
            .listStyle(.plain)
            .contentMargins(.all, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
        }
    }

    private var libraryList: some View {
        List {
            ForEach(folders) { folder in
                folderRow(folder)

                if expandedFolders.contains(folder.id) {
                    ForEach(notes(in: folder)) { note in
                        noteRow(note)
                    }
                }
            }

            if !unfiledNotes.isEmpty {
                Text("未分类")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(height: 20, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 0, trailing: 4))
                    .listRowSeparator(.hidden)

                ForEach(unfiledNotes) { note in
                    noteRow(note)
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.all, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
    }

    private func folderRow(_ folder: NoteFolder) -> some View {
        Button {
            toggleFolder(folder)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .light))
                    .frame(width: 14)
                    .foregroundStyle(.secondary)
                Text(folder.name)
                    .font(.system(size: 13, weight: .regular))
                    .lineLimit(1)
                Spacer()
                Image(systemName: expandedFolders.contains(folder.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, height: NoteDrawerLayout.folderRowHeight)
            }
            .frame(maxWidth: .infinity, minHeight: NoteDrawerLayout.folderRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folder.name)
        .accessibilityValue(expandedFolders.contains(folder.id) ? "已展开" : "已收起")
        .accessibilityLabel("\(expandedFolders.contains(folder.id) ? "收起" : "展开")文件夹 \(folder.name)")
        .contextMenu {
            Button {
                editingFolder = folder
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                pendingFolderDeletion = folder
                confirmingFolderDeletion = true
            } label: {
                Label("删除文件夹", systemImage: "trash")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: NoteDrawerLayout.folderRowHeight)
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func noteRow(_ note: NoteRecord) -> some View {
        HStack(spacing: 0) {
            Button(action: { isSearching ? selectMatch(note, query) : select(note) }) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                    Text(note.title)
                        .font(.system(size: 13, weight: .light))
                        .lineLimit(1)
                    if note.isPinned {
                        Circle()
                            .fill(Color.secondary.opacity(0.55))
                            .frame(width: 4, height: 4)
                            .help("已置顶")
                            .accessibilityLabel("已置顶")
                    }
                    }
                    if isSearching {
                        Text(NoteSearchExcerpt.text(for: note, query: query))
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.leading, NoteDrawerLayout.noteLeadingIndent)
                .frame(maxWidth: .infinity, minHeight: NoteDrawerLayout.noteRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(note.title)
            .accessibilityValue(note.isPinned ? "已置顶的便签" : "")
            .accessibilityAddTraits(note.id == selectedID ? .isSelected : [])

            Menu {
                Button("标签…") { editTags(note) }
                Button(action: { togglePin(note) }) {
                    Label(
                        note.isPinned ? "取消置顶" : "置顶",
                        systemImage: note.isPinned ? "pin.slash" : "pin"
                    )
                }

                Menu {
                    Button {
                        moveNote(note, to: nil)
                    } label: {
                        Label("未分类", systemImage: "tray")
                    }
                    .disabled(note.folderID == nil)

                    if !folders.isEmpty {
                        Divider()
                    }

                    ForEach(folders) { folder in
                        Button {
                            moveNote(note, to: folder)
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                        .disabled(note.folderID == folder.id)
                    }
                } label: {
                    Label("移动到文件夹", systemImage: "folder")
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
                    .font(.system(size: 12))
                    .frame(width: 24, height: NoteDrawerLayout.noteRowHeight)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hoveredNoteID == note.id || note.id == selectedID ? 0.75 : 0)
            .quickNoteHoverHighlight(cornerRadius: 6)
            .help("编辑便签")
            .accessibilityLabel("编辑便签")
        }
        .padding(.horizontal, 6)
        .frame(height: isSearching ? 50 : NoteDrawerLayout.noteRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(note.id == selectedID ? Color(nsColor: theme == .system ? .controlAccentColor : theme.accentColor).opacity(0.09) : Color.clear)
        )
        .quickNoteHoverHighlight(cornerRadius: 5, enabled: note.id != selectedID)
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .onHover { hovering in
            if hovering {
                hoveredNoteID = note.id
            } else if hoveredNoteID == note.id {
                hoveredNoteID = nil
            }
        }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func refreshSearch() {
        do {
            matches = try search(query)
            searchError = nil
        } catch {
            matches = []
            searchError = "搜索失败：\(error.localizedDescription)"
        }
    }

    private var unfiledNotes: [NoteRecord] {
        notes.filter { $0.folderID == nil }
    }

    private func notes(in folder: NoteFolder) -> [NoteRecord] {
        notes.filter { $0.folderID == folder.id }
    }

    private func toggleFolder(_ folder: NoteFolder) {
        if expandedFolders.contains(folder.id) {
            expandedFolders.remove(folder.id)
        } else {
            expandedFolders.insert(folder.id)
        }
    }

    private func moveNote(_ note: NoteRecord, to folder: NoteFolder?) {
        move(note, folder)
        if let folder { expandedFolders.insert(folder.id) }
    }

    private func expandSelectedFolder() {
        guard
            let selectedID,
            let folderID = notes.first(where: { $0.id == selectedID })?.folderID
        else { return }
        expandedFolders.insert(folderID)
    }
}
private struct FolderNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let save: (String) throws -> Void
    @State private var name: String
    @State private var message: String?

    init(
        title: String,
        initialName: String,
        save: @escaping (String) throws -> Void
    ) {
        self.title = title
        self.save = save
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))

            TextField("文件夹名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("保存", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 300)
    }

    private func submit() {
        do {
            try save(name)
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
