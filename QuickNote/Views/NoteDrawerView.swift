import SwiftUI

enum NoteDrawerLayout {
    static let noteLeadingIndent: CGFloat = 20
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

    @State private var query = ""
    @State private var expandedFolders = Set<UUID>()
    @State private var creatingFolder = false
    @State private var editingFolder: NoteFolder?
    @State private var pendingDeletion: NoteRecord?
    @State private var confirmingDeletion = false
    @State private var pendingFolderDeletion: NoteFolder?
    @State private var confirmingFolderDeletion = false

    var body: some View {
        VStack(spacing: 10) {
            header

            TextField("搜索便签标题", text: $query)
                .textFieldStyle(.roundedBorder)

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
        .padding(10)
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
            Text("“\(note.title)”将被永久删除。")
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
        HStack {
            Text("全部便签")
                .font(.headline)

            Text("\(notes.count)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Button { creatingFolder = true } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("新建文件夹")
            .accessibilityLabel("新建文件夹")

            Button(action: create) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("新建便签")
            .accessibilityLabel("新建便签")
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if filtered.isEmpty {
            ContentUnavailableView {
                Label("没有找到便签", systemImage: "magnifyingglass")
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filtered) { note in
                noteRow(note)
            }
            .listStyle(.plain)
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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 2, trailing: 8))
                    .listRowSeparator(.hidden)

                ForEach(unfiledNotes) { note in
                    noteRow(note)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func folderRow(_ folder: NoteFolder) -> some View {
        HStack(spacing: 6) {
            Button {
                toggleFolder(folder)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(folder.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expandedFolders.contains(folder.id) ? "收起" : "展开")文件夹 \(folder.name)")

            Menu {
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
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("编辑文件夹")
            .accessibilityLabel("编辑文件夹 \(folder.name)")
        }
        .frame(height: 40)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
    }

    private func noteRow(_ note: NoteRecord) -> some View {
        HStack(spacing: 6) {
            Button(action: { select(note) }) {
                HStack(spacing: 4) {
                    Text(note.title)
                        .font(.system(size: 14, weight: .regular))
                        .lineLimit(1)
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.leading, NoteDrawerLayout.noteLeadingIndent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
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
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("编辑便签")
            .accessibilityLabel("编辑便签")
        }
        .frame(height: 32)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowBackground(
            note.id == selectedID ? Color(nsColor: theme.accentColor).opacity(0.12) : Color.clear
        )
        .listRowSeparator(.hidden)
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filtered: [NoteRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return notes }
        return notes.filter { $0.title.localizedStandardContains(normalized) }
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
