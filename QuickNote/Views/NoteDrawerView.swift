import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

struct SidebarDragReference: Codable, Transferable, Sendable {
    enum Kind: String, Codable, Sendable { case note, folder }
    let id: UUID
    let kind: Kind
    static let contentType = UTType(exportedAs: "com.xixi.quicknote.note-reference", conformingTo: .data)

    init(id: UUID, kind: Kind = .note) { self.id = id; self.kind = kind }
    private enum CodingKeys: String, CodingKey { case id, kind }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .note
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        if kind != .note { try values.encode(kind, forKey: .kind) }
    }

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.register(self)
        provider.suggestedName = kind.rawValue
        return provider
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: contentType)
            .visibility(.ownProcess)
    }
}

typealias NoteDragReference = SidebarDragReference

@MainActor
struct SidebarDropDelegate: DropDelegate {
    let rowHeight: CGFloat
    let insertionKind: SidebarDragReference.Kind
    let allowedKinds: Set<SidebarDragReference.Kind>
    let hover: (Bool?, Bool) -> Void
    let receive: (SidebarDragReference, Bool) -> Bool

    static func accepts(_ providers: [NSItemProvider], kinds: Set<SidebarDragReference.Kind>) -> Bool {
        guard providers.count == 1, let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(SidebarDragReference.contentType.identifier) else { return false }
        // suggestedName is only a cursor/preview hint. The decoded kind is checked again on drop.
        guard let kind = provider.suggestedName.flatMap(SidebarDragReference.Kind.init(rawValue:)) else { return true }
        return kinds.contains(kind)
    }

    func validateDrop(info: DropInfo) -> Bool {
        Self.accepts(info.itemProviders(for: [SidebarDragReference.contentType]), kinds: allowedKinds)
    }

    private func update(_ info: DropInfo) {
        guard validateDrop(info: info) else { hover(nil, false); return }
        let name = info.itemProviders(for: [SidebarDragReference.contentType]).first?.suggestedName
        hover(name == insertionKind.rawValue ? info.location.y >= rowHeight / 2 : nil, true)
    }

    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }
    func dropExited(info: DropInfo) { hover(nil, false) }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info),
              let provider = info.itemProviders(for: [SidebarDragReference.contentType]).first else { return false }
        let after = info.location.y >= rowHeight / 2
        hover(nil, false)
        provider.loadTransferable(type: SidebarDragReference.self) { result in
            Task { @MainActor in
                guard case .success(let reference) = result, allowedKinds.contains(reference.kind) else { return }
                _ = receive(reference, after)
            }
        }
        return true
    }
}

@MainActor
enum NoteDrawerDrop {
    static func move(_ references: [NoteDragReference], notes: [NoteRecord], to folder: NoteFolder?,
                     using move: (NoteRecord, NoteFolder?) -> Void) -> Bool {
        let requested = Set(references.filter { $0.kind == .note }.map(\.id))
        var handled = Set<UUID>()
        let eligible = notes.filter {
            requested.contains($0.id) && $0.deletedAt == nil && $0.folderID != folder?.id
                && handled.insert($0.id).inserted
        }
        for note in eligible { move(note, folder) }
        return !eligible.isEmpty
    }
}

enum NoteDrawerLayout {
    static let noteLeadingIndent: CGFloat = 22
    static let folderNoteLeadingIndent: CGFloat = 44
    static let noteRowHeight: CGFloat = 28
    static let folderRowHeight = noteRowHeight
}

enum NoteDrawerSearch {
    static func matches(_ note: NoteRecord, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || note.title.localizedStandardContains(query)
            || note.plainText.localizedStandardContains(query)
            || note.tags.contains { $0.localizedStandardContains(query) }
    }
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
    var reorderNote: (UUID, UUID, Bool, Bool) -> Bool = { _, _, _, _ in false }
    var reorderFolder: (UUID, UUID, Bool) -> Bool = { _, _, _ in false }
    var toggleSensitive: ((NoteRecord) -> Void)? = nil
    var submitSearch: ((String) -> Void)? = nil

    @State private var expandedFolders = Set<UUID>()
    @State private var creatingFolder = false
    @State private var editingFolder: NoteFolder?
    @State private var pendingDeletion: NoteRecord?
    @State private var confirmingDeletion = false
    @State private var pendingFolderDeletion: NoteFolder?
    @State private var confirmingFolderDeletion = false
    @State private var hoveredNoteID: UUID?
    @State private var hoveredFolderID: UUID?
    @State private var targetedFolderID: UUID?
    @State private var unfiledIsTargeted = false
    @State private var insertionKey: String?
    @State private var insertAfter = false
    @State private var query = ""
    @State private var pinnedExpanded = true
    @State private var foldersExpanded = true
    @State private var unfiledExpanded = true
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            header
            searchField

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
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .background(Color(nsColor: theme.sidebarBackground))
        .onAppear(perform: expandSelectedFolder)
        .onChange(of: selectedID) { _, _ in expandSelectedFolder() }
        .onChange(of: query) { _, value in
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            pinnedExpanded = true; foldersExpanded = true; unfiledExpanded = true
            expandedFolders.formUnion(visibleNotes.compactMap(\.folderID))
        }
        .sheet(isPresented: $creatingFolder) {
            FolderNameEditor(
                title: "新建文件夹",
                initialName: "",
                save: createFolder
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
            Text("“\(folder.name)”中的便签会移到“便签集”，不会被删除。")
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text("全部便签")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .accessibilityIdentifier("library.heading")

            Spacer(minLength: 0)

            Button(action: showSearch) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .quickNoteHoverHighlight()
            .help("全文搜索（⌘⇧F）· 查找所有便签的正文")
            .accessibilityLabel("全文搜索")
            .accessibilityIdentifier("library.openSearch")
            .tint(Color(nsColor: .secondaryLabelColor))

            Button { creatingFolder = true } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .quickNoteHoverHighlight()
            .help("新建文件夹")
            .accessibilityLabel("新建文件夹")
            .tint(Color(nsColor: .secondaryLabelColor))

            Button(action: create) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .quickNoteHoverHighlight()
            .help("新建便签")
            .accessibilityLabel("新建便签")
            .tint(Color(nsColor: .secondaryLabelColor))
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 26)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("筛选便签", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searchFocused)
                .onSubmit {
                    guard !NoteSearchField.hasMarkedText else { return }
                    if let submitSearch { submitSearch(query) } else { showSearch() }
                }
                .onExitCommand { query = ""; searchFocused = false }
                .accessibilityLabel("筛选便签")
                .accessibilityIdentifier("library.filter")
            if !query.isEmpty {
                Button { query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Color(nsColor: theme == .system ? NoteChrome.inset : theme.toolbarBackground), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
        .contextMenu { Button("全文搜索…", action: showSearch) }
    }

    private var libraryList: some View {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 6) {
            if !pinnedNotes.isEmpty {
              VStack(spacing: 1) {
                sectionHeading("置顶", expanded: $pinnedExpanded)
                if pinnedExpanded { ForEach(pinnedNotes) { note in
                    noteRow(note, pinnedShortcut: true)
                        .id("pinned-\(note.id.uuidString)")
                        .accessibilityHint("置顶快捷入口，归档位置不变")
                } }
              }
            }

            if !visibleFolders.isEmpty {
              VStack(spacing: 1) {
                sectionHeading("文件夹", expanded: $foldersExpanded)
                if foldersExpanded { ForEach(visibleFolders) { folder in
                  VStack(spacing: 1) {
                    folderRow(folder)
                    if expandedFolders.contains(folder.id) {
                        ForEach(notes(in: folder)) { note in noteRow(note, inFolder: true) }
                        if notes(in: folder).isEmpty {
                            Text("暂无便签").font(.system(size: 12.5)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 46).padding(.vertical, 6)
                        }
                    }
                  }
                  .overlay(alignment: insertAfter ? .bottom : .top) { insertionLine("folder-\(folder.id)") }
                } }
              }
            }

            if !unfiledNotes.isEmpty || !folders.isEmpty {
              VStack(spacing: 1) {
                sectionHeading("便签集", expanded: $unfiledExpanded)
                    .contentShape(Rectangle())
                    .background(dropHighlight(unfiledIsTargeted))
                    .dropDestination(for: NoteDragReference.self) { items, _ in
                        acceptDrop(items, to: nil)
                    } isTargeted: { unfiledIsTargeted = $0 }
                    .help("拖动便签到这里，移出文件夹")

                if unfiledExpanded { ForEach(unfiledNotes) { note in
                    noteRow(note)
                } }
              }
            }
            if visibleNotes.isEmpty && !query.isEmpty {
                Text("没有匹配的便签").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
            }
          }
          .padding(.top, 4).padding(.bottom, 8)
        }
    }

    private var pinnedNotes: [NoteRecord] {
        visibleNotes.filter { $0.isPinned }.sorted(by: NoteSidebarOrder.pinnedPrecedes)
    }

    private func sectionHeading(_ title: String, expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 14)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 4).padding(.trailing, 8)
            .frame(height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .quickNoteHoverHighlight(cornerRadius: 6)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(title)
        .accessibilityValue(expanded.wrappedValue ? "已展开" : "已收起")
    }

    private func dropHighlight(_ targeted: Bool) -> some View {
        let accent = Color(nsColor: theme.accentColor)
        return RoundedRectangle(cornerRadius: 6)
            .fill(targeted ? accent.opacity(0.10) : .clear)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(targeted ? accent.opacity(0.6) : .clear, lineWidth: 1))
    }

    @ViewBuilder
    private func folderActions(_ folder: NoteFolder) -> some View {
        Button { editingFolder = folder } label: { Label("重命名", systemImage: "pencil") }
        Divider()
        Button(role: .destructive) {
            pendingFolderDeletion = folder
            confirmingFolderDeletion = true
        } label: { Label("删除文件夹", systemImage: "trash") }
    }

    private func markInsertion(_ key: String, after: Bool?) {
        if let after { insertionKey = key; insertAfter = after }
        else if insertionKey == key { insertionKey = nil }
    }

    private func insertionLine(_ key: String) -> some View {
        Rectangle().fill(Color(nsColor: theme.accentColor))
            .frame(height: insertionKey == key ? 1 : 0)
            .padding(.horizontal, 6).allowsHitTesting(false)
    }

    private func folderRow(_ folder: NoteFolder) -> some View {
        let dropKey = "folder-\(folder.id)"
        return Group {
            if editingFolder?.id == folder.id {
                FolderInlineNameEditor(initialName: folder.name, save: { name in
                    try renameFolder(folder, name)
                    editingFolder = nil
                }, cancel: { editingFolder = nil })
                    .id(folder.id)
            } else {
                Button {
                    toggleFolder(folder)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "folder")
                            .font(.system(size: 13, weight: .regular))
                            .frame(width: 15)
                            .foregroundStyle(.secondary)
                        Text(folder.name)
                            .font(.system(size: 13.5, weight: .regular))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                    }
                    .padding(.trailing, 24)
                    .frame(maxWidth: .infinity, minHeight: NoteDrawerLayout.folderRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(folder.name)
                .accessibilityValue(expandedFolders.contains(folder.id) ? "已展开" : "已收起")
                .accessibilityLabel("\(expandedFolders.contains(folder.id) ? "收起" : "展开")文件夹 \(folder.name)")
                .onDrag { SidebarDragReference(id: folder.id, kind: .folder).itemProvider() }
                .overlay(alignment: .trailing) {
                    Menu { folderActions(folder) } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: NoteDrawerLayout.folderRowHeight)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .quickNoteHoverHighlight(cornerRadius: 4)
                    .help("编辑文件夹")
                    .accessibilityLabel("编辑文件夹")
                    .opacity(hoveredFolderID == folder.id ? 0.75 : 0)
                    .allowsHitTesting(hoveredFolderID == folder.id)
                }
                .frame(height: NoteDrawerLayout.folderRowHeight)
            }
        }
        .contextMenu { folderActions(folder) }
        .padding(.leading, 22).padding(.trailing, 8)
        .onHover { hovering in
            if hovering { hoveredFolderID = folder.id }
            else if hoveredFolderID == folder.id { hoveredFolderID = nil }
        }
        .background(dropHighlight(targetedFolderID == folder.id))
        .quickNoteHoverHighlight(cornerRadius: 6, enabled: targetedFolderID != folder.id && editingFolder?.id != folder.id)
        .onDrop(of: [SidebarDragReference.contentType], delegate: SidebarDropDelegate(
            rowHeight: NoteDrawerLayout.folderRowHeight, insertionKind: .folder, allowedKinds: [.note, .folder],
            hover: { after, targeted in
                markInsertion(dropKey, after: after)
                if targeted { targetedFolderID = folder.id }
                else if targetedFolderID == folder.id { targetedFolderID = nil }
            }, receive: { reference, after in
                if reference.kind == .folder { return reorderFolder(reference.id, folder.id, after) }
                return acceptDrop([reference], to: folder)
            }))
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func noteRow(_ note: NoteRecord, inFolder: Bool = false, pinnedShortcut: Bool = false) -> some View {
        let dropKey = "note-\(pinnedShortcut)-\(note.id)"
        return HStack(spacing: 0) {
            Button(action: { select(note) }) {
                HStack(spacing: 9) {
                    Image(systemName: pinnedShortcut ? "pin" : "doc.text")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(pinnedShortcut || note.id == selectedID ? Color(nsColor: theme.accentColor) : Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 15)
                    Text(note.title)
                        .font(.system(size: 13.5, weight: note.id == selectedID ? .semibold : .regular))
                        .lineLimit(1)
                    if note.isSensitive {
                        Image(systemName: "lock")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, inFolder ? NoteDrawerLayout.folderNoteLeadingIndent : NoteDrawerLayout.noteLeadingIndent)
                .frame(maxWidth: .infinity, minHeight: NoteDrawerLayout.noteRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(note.title)
            .accessibilityValue([note.isPinned ? "已置顶的便签" : "", note.isSensitive ? "敏感便签" : ""]
                .filter { !$0.isEmpty }.joined(separator: "，"))
            .accessibilityAddTraits(note.id == selectedID ? .isSelected : [])
            .onDrag { SidebarDragReference(id: note.id).itemProvider() }

            Menu {
                sensitivityAction(for: note)
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
                        Label("便签集", systemImage: "tray")
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
        .padding(.trailing, 8)
        .frame(height: NoteDrawerLayout.noteRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(note.id == selectedID ? (theme == .system ? Color(nsColor: NoteChrome.selection) : Color(nsColor: theme.accentColor).opacity(0.17)) : Color.clear)
        )
        .quickNoteHoverHighlight(cornerRadius: 6, enabled: note.id != selectedID)
        .contextMenu { sensitivityAction(for: note) }
        .overlay(alignment: insertAfter ? .bottom : .top) { insertionLine(dropKey) }
        .onDrop(of: [SidebarDragReference.contentType], delegate: SidebarDropDelegate(
            rowHeight: NoteDrawerLayout.noteRowHeight, insertionKind: .note, allowedKinds: [.note],
            hover: { after, _ in markInsertion(dropKey, after: after) },
            receive: { reference, after in reorderNote(reference.id, note.id, after, pinnedShortcut) }))
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
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

    @ViewBuilder
    private func sensitivityAction(for note: NoteRecord) -> some View {
        if let toggleSensitive {
            Button(action: { toggleSensitive(note) }) {
                Label(note.isSensitive ? "取消敏感标记" : "标记为敏感",
                      systemImage: note.isSensitive ? "lock.open" : "lock")
            }
        }
    }

    private var unfiledNotes: [NoteRecord] {
        visibleNotes.filter { $0.folderID == nil }
    }

    private var visibleNotes: [NoteRecord] { notes.filter { NoteDrawerSearch.matches($0, query: query) } }
    private var visibleFolders: [NoteFolder] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? folders
            : folders.filter { folder in visibleNotes.contains { $0.folderID == folder.id } }
    }

    private func notes(in folder: NoteFolder) -> [NoteRecord] {
        visibleNotes.filter { $0.folderID == folder.id }
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

    private func acceptDrop(_ references: [NoteDragReference], to folder: NoteFolder?) -> Bool {
        guard folder == nil || folders.contains(where: { $0.id == folder?.id }) else { return false }
        let moved = NoteDrawerDrop.move(references, notes: notes, to: folder, using: move)
        if moved, let folder { expandedFolders.insert(folder.id) }
        if moved { foldersExpanded = true; unfiledExpanded = true }
        targetedFolderID = nil
        unfiledIsTargeted = false
        return moved
    }

    private func expandSelectedFolder() {
        guard
            let selectedID,
            let folderID = notes.first(where: { $0.id == selectedID })?.folderID
        else { return }
        expandedFolders.insert(folderID)
    }
}
@MainActor
private enum NoteSearchField {
    static var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }
}

enum NoteSearchMode: String {
    case search, ask

    static func suggestsAsking(for query: String) -> Bool {
        let last = query.trimmingCharacters(in: .whitespacesAndNewlines).last
        return last == "?" || last == "？"
    }
}

struct NoteSearchPanel: View {
    private typealias ItemID = NoteSearchNavigation.ItemID

    let notes: [NoteRecord]
    let folders: [NoteFolder]
    let theme: NoteTheme
    let search: (String) throws -> [NoteRecord]
    let select: (NoteRecord, String, NoteSearchSnippet?) -> Void
    let close: () -> Void
    let size: CGSize
    let askController: NoteAskController?
    let selectCitation: (NoteAskEvidence, String) -> Void

    @Binding private var mode: NoteSearchMode
    @State private var query: String
    @State private var matches: [NoteRecord] = []
    @State private var selectedItem: ItemID?
    @State private var pointerSelection = NoteSearchNavigation.PointerSelection()
    @State private var expandedNoteIDs: Set<UUID> = []
    @State private var error: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isAsking: Bool { askController != nil && mode == .ask }
    private var suggestsAsk: Bool { !isAsking && NoteSearchMode.suggestsAsking(for: query) }

    init(notes: [NoteRecord], folders: [NoteFolder], theme: NoteTheme, search: @escaping (String) throws -> [NoteRecord],
         select: @escaping (NoteRecord, String, NoteSearchSnippet?) -> Void, close: @escaping () -> Void,
         size: CGSize = CGSize(width: 560, height: 440), initialQuery: String = "",
         mode: Binding<NoteSearchMode> = .constant(.search), askController: NoteAskController? = nil,
         selectCitation: @escaping (NoteAskEvidence, String) -> Void = { _, _ in }) {
        self.notes = notes
        self.folders = folders
        self.theme = theme
        self.search = search
        self.select = select
        self.close = close
        self.size = size
        self.askController = askController
        self.selectCitation = selectCitation
        _mode = mode
        _query = State(initialValue: initialQuery)
    }

    init(notes: [NoteRecord], folders: [NoteFolder], theme: NoteTheme, search: @escaping (String) throws -> [NoteRecord],
         select: @escaping (NoteRecord, String) -> Void, close: @escaping () -> Void,
         size: CGSize = CGSize(width: 560, height: 440), initialQuery: String = "") {
        self.init(notes: notes, folders: folders, theme: theme, search: search,
                  select: { note, query, _ in select(note, query) }, close: close,
                  size: size, initialQuery: initialQuery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isAsking, let askController {
                NoteAskView(controller: askController, answerQuestion: submit) {
                    selectCitation($0, NoteAskQuestion.normalized(trimmedQuery))
                }
            } else {
                results
                    .onHover { insideResults in
                        if !insideResults { pointerSelection = .init() }
                    }
            }
            footer
        }
        .padding(12)
        .frame(width: size.width)
        .frame(maxHeight: size.height, alignment: .top)
        .foregroundStyle(Color(nsColor: theme.textColor))
        .background(Color(nsColor: theme.editorBackground))
        .preferredColorScheme(theme.colorScheme)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .onAppear {
            if isAsking { askController?.activate(question: query) }
            else { refreshSearch() }
        }
        .onDisappear { if isAsking { askController?.deactivate() } }
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            searchFocused = true
        }
        .onChange(of: query) { _, _ in
            expandedNoteIDs.removeAll()
            selectedItem = nil
            pointerSelection = .init()
            if isAsking { askController?.setQuestion(query) }
            else { refreshSearch() }
        }
        .onChange(of: mode) { _, _ in
            if isAsking {
                askController?.activate(question: query)
            } else {
                askController?.deactivate()
                refreshSearch()
            }
            searchFocused = true
        }
        .onChange(of: notes.map(\.updatedAt)) { _, _ in if !isAsking { refreshSearch() } }
        .onChange(of: notes.map(\.isSensitive)) { _, _ in if !isAsking { refreshSearch() } }
        .onExitCommand { if !NoteSearchField.hasMarkedText { close() } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if askController != nil {
                Picker("搜索模式", selection: $mode) {
                    Text("搜索").tag(NoteSearchMode.search)
                    Text("提问").tag(NoteSearchMode.ask)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("search.mode")
            }
            HStack(spacing: 8) {
                Image(systemName: isAsking ? "questionmark.circle" : "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(isAsking ? "向便签提问" : "搜索标题、正文、标签", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .accessibilityLabel(isAsking ? "向便签提问" : "搜索标题、正文、标签")
                    .accessibilityIdentifier("search.field")
                    .onSubmit { submit() }
                    .onKeyPress(.downArrow) { handleArrow(1) }
                    .onKeyPress(.upArrow) { handleArrow(-1) }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))

            if !isAsking {
                Text("\(matches.count) 条")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityIdentifier("search.count")
            }

            Button(action: close) {
                Image(systemName: "xmark")
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .quickNoteHoverHighlight()
            .help("关闭搜索（Esc）")
            .accessibilityLabel("关闭搜索")
            .accessibilityIdentifier("search.close")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if askController != nil && suggestsAsk {
                Text("按 Tab 切换到提问")
                    .foregroundStyle(Color(nsColor: theme.accentColor))
                    .lineLimit(1)
                    .accessibilityIdentifier("search.askSuggestion")
            }
            Spacer(minLength: 0)
            Text(footerShortcuts)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("search.footer")
        }
        .font(.system(size: 11))
    }

    private var footerShortcuts: String {
        if isAsking { return "Tab 搜索  ↩ 回答  esc 关闭" }
        if askController != nil { return "Tab 提问  ↑↓ 选择  ↩ 打开  esc 关闭" }
        return "↑↓ 选择  ↩ 打开  esc 关闭"
    }

    private func submit() {
        guard !NoteSearchField.hasMarkedText else { return }
        if isAsking, let askController {
            let question = NoteAskQuestion.normalized(query)
            if question != trimmedQuery { query = question }
            askController.setQuestion(question)
            askController.answerQuestion()
        } else {
            openSelection()
        }
    }

    @ViewBuilder
    private var results: some View {
        if let error {
            HStack(spacing: 8) {
                Text(error)
                Button("重试", action: refreshSearch)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        } else if matches.isEmpty {
            Text(trimmedQuery.isEmpty ? "还没有便签" : "没有找到包含‘\(trimmedQuery)’的便签")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .accessibilityIdentifier("search.empty")
        } else {
            ViewThatFits(in: .vertical) {
                resultList
                    .fixedSize(horizontal: false, vertical: true)
                ScrollViewReader { proxy in
                    ScrollView { resultList }
                        .onChange(of: selectedItem) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                }
            }
        }
    }

    private var resultList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(matches) { note in resultRow(note, match: match(for: note)) }
        }
    }

    private func match(for note: NoteRecord) -> NoteSearchMatch {
        NoteSearchMatch(title: note.title, location: folders.first(where: { $0.id == note.folderID })?.name ?? "便签集",
                        body: note.plainText, tags: note.tags, isSensitive: note.isSensitive, query: trimmedQuery)
    }

    private func resultRow(_ note: NoteRecord, match: NoteSearchMatch) -> some View {
        let isExpanded = expandedNoteIDs.contains(note.id)
        let titleID = ItemID(noteID: note.id, snippetID: nil)
        return VStack(alignment: .leading, spacing: 2) {
            if match.snippets.isEmpty {
                Button {
                    select(note, note.isSensitive ? trimmedQuery : "", nil)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        resultHeading(match)
                        if !match.otherSources.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(match.otherSources, id: \.self) { source in
                                    Text(source == .title ? "标题命中" : "标签命中")
                                }
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(selectionBackground(for: titleID), in: RoundedRectangle(cornerRadius: 5))
                .onHover { pointerSelection.update(isHovered: $0, item: titleID) }
                .accessibilityIdentifier("search.title.\(note.id.uuidString)")
                .id(titleID)
            } else {
                resultHeading(match)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .accessibilityIdentifier("search.title.\(note.id.uuidString)")
                ForEach(match.visibleSnippets(expanded: isExpanded)) { snippet in
                    snippetRow(snippet, note: note)
                }
                if match.hiddenSnippetCount > 0 {
                    Button(isExpanded ? "收起" : "还有 \(match.hiddenSnippetCount) 处") {
                        toggleExpansion(for: note.id, match: match)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                    .padding(.vertical, 3)
                    .accessibilityIdentifier("search.expand.\(note.id.uuidString)")
                }
            }
        }
    }

    private func resultHeading(_ match: NoteSearchMatch) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(match.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(match.location)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .trailing)
                .layoutPriority(1)
        }
    }

    private func snippetRow(_ snippet: NoteSearchSnippet, note: NoteRecord) -> some View {
        let id = ItemID(noteID: note.id, snippetID: snippet.id)
        return Button { select(note, trimmedQuery, snippet) } label: {
            Text(highlighted(snippet))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 7)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.28))
                        .frame(width: 1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selectionBackground(for: id), in: RoundedRectangle(cornerRadius: 5))
        .onHover { pointerSelection.update(isHovered: $0, item: id) }
        .accessibilityIdentifier("search.snippet.\(note.id.uuidString).\(snippet.id)")
        .id(id)
    }

    private func selectionBackground(for item: ItemID) -> Color {
        pointerSelection.highlightedItem(keyboardItem: selectedItem) == item
            ? Color.primary.opacity(0.055) : .clear
    }

    private func highlighted(_ snippet: NoteSearchSnippet) -> AttributedString {
        var text = AttributedString()
        for run in snippet.runs {
            var segment = AttributedString(run.text)
            if run.isMatch {
                segment.font = .system(size: 12, weight: .bold)
                segment.foregroundColor = Color(nsColor: theme.accentColor)
            }
            text.append(segment)
        }
        return text
    }

    private var navigationItems: [ItemID] {
        matches.flatMap { note in
            NoteSearchNavigation.items(noteID: note.id, match: match(for: note),
                                       expanded: expandedNoteIDs.contains(note.id))
        }
    }

    private func toggleExpansion(for noteID: UUID, match: NoteSearchMatch) {
        pointerSelection.clearItem()
        if expandedNoteIDs.remove(noteID) == nil {
            expandedNoteIDs.insert(noteID)
        } else if let selectedItem, selectedItem.noteID == noteID {
            let visible = NoteSearchNavigation.items(noteID: noteID, match: match, expanded: false)
            if !visible.contains(selectedItem) { self.selectedItem = visible.first }
        }
    }

    private func refreshSearch() {
        do {
            matches = trimmedQuery.isEmpty ? notes.sorted { $0.updatedAt > $1.updatedAt } : try search(trimmedQuery)
            let items = navigationItems
            if !items.contains(where: { $0 == selectedItem }) { selectedItem = items.first }
            if let pointerItem = pointerSelection.item, !items.contains(pointerItem) {
                pointerSelection.clearItem()
            }
            error = nil
        } catch {
            matches = []
            selectedItem = nil
            pointerSelection = .init()
            self.error = "搜索暂时不可用，请重试。"
        }
    }

    private func handleArrow(_ offset: Int) -> KeyPress.Result {
        guard !isAsking, !NoteSearchField.hasMarkedText else { return .ignored }
        let current = pointerSelection.item ?? selectedItem
        pointerSelection = .init()
        selectedItem = NoteSearchNavigation.move(in: navigationItems, selected: current, offset: offset)
        return .handled
    }

    private func openSelection() {
        guard let item = pointerSelection.item ?? selectedItem,
              let note = matches.first(where: { $0.id == item.noteID }) else { return }
        if let snippetID = item.snippetID {
            guard let snippet = match(for: note).snippets.first(where: { $0.id == snippetID }) else { return }
            select(note, trimmedQuery, snippet)
        } else {
            select(note, note.isSensitive ? trimmedQuery : "", nil)
        }
    }
}

struct FolderInlineNameEditor: View {
    let save: (String) throws -> Void
    let cancel: () -> Void
    @State private var name: String
    @State private var message: String?
    @FocusState private var focused: Bool

    init(initialName: String, save: @escaping (String) throws -> Void, cancel: @escaping () -> Void) {
        self.save = save
        self.cancel = cancel
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 15)
                TextField("文件夹名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13.5))
                    .controlSize(.small)
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancel)
                    .accessibilityLabel("文件夹名称")
                Button(action: submit) {
                    Image(systemName: "checkmark").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("保存名称（回车）").accessibilityLabel("保存文件夹名称")
                Button(action: cancel) {
                    Image(systemName: "xmark").frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .help("取消重命名（Esc）").accessibilityLabel("取消重命名")
            }
            .font(.system(size: 10))
            .buttonStyle(.plain)
            .frame(height: NoteDrawerLayout.folderRowHeight)
            if let message {
                Text(message).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 19).padding(.bottom, 4)
            }
        }
        .task { await Task.yield(); focused = true }
        .onChange(of: name) { _, _ in message = nil }
    }

    private func submit() {
        do { try save(name) }
        catch { message = error.localizedDescription; focused = true }
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
