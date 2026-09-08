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
    let showSearch: () -> Void
    let editTags: (NoteRecord) -> Void

    @State private var expandedFolders = Set<UUID>()
    @State private var creatingFolder = false
    @State private var editingFolder: NoteFolder?
    @State private var pendingDeletion: NoteRecord?
    @State private var confirmingDeletion = false
    @State private var pendingFolderDeletion: NoteFolder?
    @State private var confirmingFolderDeletion = false
    @State private var hoveredNoteID: UUID?

    var body: some View {
        VStack(spacing: 6) {
            header

            if notes.isEmpty && folders.isEmpty {
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

            Button(action: showSearch) {
                Image(systemName: "magnifyingglass")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .quickNoteHoverHighlight()
            .help("搜索便签")
            .accessibilityLabel("搜索便签")

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
            Button(action: { select(note) }) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                    Text(note.title)
                        .font(.system(size: 13, weight: .regular))
                        .lineLimit(1)
                    if note.isPinned {
                        Circle()
                            .fill(Color.secondary.opacity(0.55))
                            .frame(width: 4, height: 4)
                            .help("已置顶")
                            .accessibilityLabel("已置顶")
                    }
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
        .frame(height: NoteDrawerLayout.noteRowHeight)
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
struct NoteSearchPanel: View {
    let notes: [NoteRecord]
    let folders: [NoteFolder]
    let theme: NoteTheme
    let search: (String) throws -> [NoteRecord]
    let select: (NoteRecord, String) -> Void
    let close: () -> Void
    var size = CGSize(width: 480, height: 380)
    @State private var query = ""
    @State private var matches: [NoteRecord] = []
    @State private var selectedID: UUID?
    @State private var error: String?
    @FocusState private var searchFocused: Bool
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索标题、正文、标签", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 14))
                        .focused($searchFocused)
                        .accessibilityLabel("搜索标题、正文、标签")
                        .onSubmit(openSelection)
                        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                }
                .padding(.horizontal, 10).frame(height: 34)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                Button(action: close) {
                    Image(systemName: "xmark")
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(.secondary).quickNoteHoverHighlight()
                    .help("关闭搜索（Esc）").accessibilityLabel("关闭搜索")
            }
            Text(trimmedQuery.isEmpty ? "最近便签" : "搜索结果 · \(matches.count)")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            if let error {
                VStack(spacing: 12) {
                    Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("重试", action: refreshSearch)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty {
                VStack(spacing: 8) {
                    Text(trimmedQuery.isEmpty ? "还没有便签" : "没有找到相关便签").font(.system(size: 14))
                    if !trimmedQuery.isEmpty { Text("试试标题、正文或标签中的其他关键词").font(.system(size: 12)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(matches) { note in
                                Button { select(note, trimmedQuery) } label: {
                                    HStack(spacing: 16) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(note.title).font(.system(size: 14)).lineLimit(1)
                                            let excerpt = NoteSearchExcerpt.text(for: note, query: trimmedQuery)
                                            if !excerpt.isEmpty {
                                                Text(excerpt).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                        Label(folders.first(where: { $0.id == note.folderID })?.name ?? "未分类", systemImage: "folder")
                                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                            .frame(maxWidth: 150, alignment: .trailing)
                                    }.padding(.horizontal, 10).padding(.vertical, 9)
                                        .frame(maxWidth: .infinity, minHeight: 38)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .background(selectedID == note.id ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                    .quickNoteHoverHighlight(cornerRadius: 7)
                                    .help(note.title).id(note.id)
                            }
                        }
                    }.onChange(of: selectedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .padding(16).frame(width: size.width, height: size.height)
        .foregroundStyle(Color(nsColor: theme.textColor))
        .background(Color(nsColor: theme.editorBackground))
        .preferredColorScheme(theme.colorScheme)
        .onAppear(perform: refreshSearch)
        .task {
            await Task.yield()
            searchFocused = true
        }
        .onChange(of: query) { _, _ in refreshSearch() }
        .onChange(of: notes.map(\.updatedAt)) { _, _ in refreshSearch() }
        .onExitCommand(perform: close)
    }

    private func refreshSearch() {
        do {
            matches = trimmedQuery.isEmpty ? notes.sorted { $0.updatedAt > $1.updatedAt } : try search(trimmedQuery)
            selectedID = matches.first?.id
            error = nil
        } catch {
            matches = []
            selectedID = nil
            self.error = "搜索暂时不可用，请重试。"
        }
    }

    private func moveSelection(_ offset: Int) {
        guard !matches.isEmpty else { return }
        let current = matches.firstIndex(where: { $0.id == selectedID }) ?? 0
        selectedID = matches[min(matches.count - 1, max(0, current + offset))].id
    }

    private func openSelection() {
        if let note = matches.first(where: { $0.id == selectedID }) { select(note, trimmedQuery) }
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
