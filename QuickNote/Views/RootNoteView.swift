import AppKit
import SwiftUI

struct QuickNoteHoverHighlight: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    let cornerRadius: CGFloat
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .background(
                Color.primary.opacity(enabled && hovering ? 0.065 : 0),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = enabled && $0 }
    }
}

extension View {
    func quickNoteHoverHighlight(cornerRadius: CGFloat = 6, enabled: Bool = true) -> some View {
        modifier(QuickNoteHoverHighlight(cornerRadius: cornerRadius, enabled: enabled))
    }

    func quickNoteTooltip(_ text: String, alignment: Alignment = .bottom) -> some View {
        modifier(QuickNoteTooltip(text: text, alignment: alignment))
    }
}

private struct QuickNoteTooltip: ViewModifier {
    @State private var hovering = false
    let text: String
    let alignment: Alignment

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if hovering {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .fixedSize()
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                        .offset(y: 30)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(hovering ? 100 : 0)
            .onHover { hovering = $0 }
    }
}

enum QuickNoteShortcut: Equatable {
    case zoomIn
    case zoomOut
    case toggleSidebar
    case newNote
    case insertLink
    case previousNote
    case nextNote

    static func resolve(
        characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> QuickNoteShortcut? {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command, .option] {
            if characters == String(UnicodeScalar(NSLeftArrowFunctionKey)!) { return .previousNote }
            if characters == String(UnicodeScalar(NSRightArrowFunctionKey)!) { return .nextNote }
        }
        guard modifiers.contains(.command),
              !modifiers.contains(.control),
              !modifiers.contains(.option) else { return nil }
        let value = characters?.lowercased()
        if value == "+" || value == "=" { return .zoomIn }
        guard modifiers == .command else { return nil }
        return switch value {
        case "-": .zoomOut
        case "b": .toggleSidebar
        case "n": .newNote
        case "k": .insertLink
        default: nil
        }
    }
}

@MainActor
private final class QuickNoteShortcutMonitor: ObservableObject {
    private var monitor: Any?
    private var action: ((QuickNoteShortcut) -> Void)?

    func start(window: @escaping () -> NSWindow?, action: @escaping (QuickNoteShortcut) -> Void) {
        self.action = action
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let owner = window(), event.window === owner, owner.isKeyWindow,
                  owner.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            guard let shortcut = QuickNoteShortcut.resolve(
                characters: event.charactersIgnoringModifiers,
                modifiers: event.modifierFlags
            ), !event.isARepeat || shortcut == .zoomIn || shortcut == .zoomOut else { return event }
            self?.action?(shortcut)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        action = nil
    }
}

/// Keep traversal stable while autosave changes recency; opening the library resets to its visible order.
struct NoteNavigationOrder {
    private(set) var ids: [UUID] = []

    mutating func refresh(notes: [NoteRecord], folders: [NoteFolder], reset: Bool) {
        let folderIDs = Set(folders.map(\.id))
        let ordered = folders.flatMap { folder in notes.filter { $0.folderID == folder.id } }
            + notes.filter { $0.folderID == nil || !folderIDs.contains($0.folderID!) }
        let fresh = ordered.filter { $0.deletedAt == nil }.map(\.id)
        let live = Set(fresh), old = Set(ids)
        ids = reset ? fresh : ids.filter { live.contains($0) } + fresh.filter { !old.contains($0) }
    }

    func neighbor(of current: UUID?, offset: Int) -> UUID? {
        guard offset == -1 || offset == 1, let current, let index = ids.firstIndex(of: current),
              ids.indices.contains(index + offset) else { return nil }
        return ids[index + offset]
    }
}

struct NoteNavigationControls: View {
    let previousTitle: String?
    let nextTitle: String?
    let navigate: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            navigationButton(offset: -1, title: previousTitle)
            navigationButton(offset: 1, title: nextTitle)
        }
        .foregroundStyle(.secondary)
        .background(.primary.opacity(0.045), in: Capsule())
        .overlay {
            Rectangle().fill(.quaternary).frame(width: 1, height: 12).allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("便签翻页")
    }

    private func navigationButton(offset: Int, title: String?) -> some View {
        NoteNavigationButton(previous: offset < 0, title: title) { navigate(offset) }
            .frame(width: 34, height: 30)
            .quickNoteHoverHighlight(enabled: title != nil)
    }
}

private struct NoteNavigationButton: NSViewRepresentable {
    let previous: Bool
    let title: String?
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> FirstClickNavigationButton {
        let button = FirstClickNavigationButton(title: "", target: nil, action: nil)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.imagePosition = .imageOnly
        button.target = button
        button.action = #selector(FirstClickNavigationButton.press)
        return button
    }

    func updateNSView(_ button: FirstClickNavigationButton, context: Context) {
        let label = previous ? "上一条便签" : "下一条便签"
        let keys = previous ? "⌘⌥←" : "⌘⌥→"
        button.image = NSImage(systemSymbolName: previous ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        button.contentTintColor = .secondaryLabelColor
        button.isEnabled = enabled && title != nil
        button.onPress = action
        button.toolTip = title.map { "\(label)：\($0)（\(keys)）" } ?? (previous ? "已是第一条便签" : "已是最后一条便签")
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(title ?? "没有更多便签")
    }
}

private final class FirstClickNavigationButton: NSButton {
    var onPress: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }
    override var mouseDownCanMoveWindow: Bool { false }
    @objc func press() { if isEnabled { onPress?() } }
}

enum AIFormattingComparison {
    static func changedParagraphCount(before: NSAttributedString, after: NSAttributedString) -> Int {
        guard before.string == after.string else { return 0 }
        let text = before.string as NSString
        var location = 0
        var count = 0
        while location < text.length {
            let range = text.paragraphRange(for: NSRange(location: location, length: 0))
            if !before.attributedSubstring(from: range).isEqual(to: after.attributedSubstring(from: range)) { count += 1 }
            location = NSMaxRange(range)
        }
        return count
    }
}

private struct AIFormattingPreview {
    let noteID: UUID
    let revision: Int
    let title: String
    let baseline: NSAttributedString
    let original: NSAttributedString
    let formatted: NSAttributedString
}

struct RootNoteView: View {
    @ObservedObject var session: NoteSession
    let allNotes: () throws -> [NoteRecord]
    let searchNotes: (String) throws -> [NoteRecord]
    let allFolders: () throws -> [NoteFolder]
    let createFolderAction: (String) throws -> Void
    let renameFolderAction: (NoteFolder, String) throws -> Void
    let deleteFolderAction: (NoteFolder) throws -> Void
    let moveNoteAction: (NoteRecord, NoteFolder?) throws -> Void
    let activateEditor: () -> Void
    let drawerVisibilityChanged: (Bool) -> Void
    let setWindowLocked: (Bool) -> Void
    let showAISettings: () -> Void
    var desktopPet: DesktopPetController? = nil
    @AppStorage(DesktopPetController.enabledKey) private var petEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var editorController = RichTextEditorController()
    @StateObject private var shortcutMonitor = QuickNoteShortcutMonitor()
    @State private var drawerOpen = false
    @State private var windowLocked = false
    @State private var calendarPresented = false
    @State private var settingsPresented = false
    @State private var searchPresented = false
    @State private var settingsDestination: QuickNoteSettingsDestination?
    @State private var noteStorageLocations: [NoteStorageLocation] = []
    @State private var commandPresented = false
    @State private var isAIFormatting = false
    @State private var aiFormattingTask: Task<Void, Never>?
    @State private var aiFormattingID: UUID?
    @State private var aiFormattingNoteTitle: String?
    @State private var formattingPreview: AIFormattingPreview?
    @State private var previewPresented = false
    @State private var tagsPresented = false
    @State private var selectedDate = Date()
    @State private var notes: [NoteRecord] = []
    @State private var folders: [NoteFolder] = []
    @State private var navigationOrder = NoteNavigationOrder()
    @AppStorage("appearance.noteTheme") private var selectedTheme = NoteTheme.system.rawValue

    var body: some View {
        let noteID = session.currentNote?.id
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    toolbarButton(
                        "便签列表",
                        systemImage: "sidebar.left",
                        action: toggleDrawer
                    )
                    .offset(y: -1)

                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Button {
                            commandPresented = false
                            settingsPresented = false
                            selectedDate = context.date
                            calendarPresented.toggle()
                        } label: {
                            Text(CalendarText.toolbarDate(for: context.date))
                                .font(.system(size: 12, weight: .regular))
                        }
                        .buttonStyle(.borderless)
                        .quickNoteHoverHighlight()
                        .help("查看日历")
                        .accessibilityLabel(CalendarText.fullDate(for: context.date))
                        .popover(isPresented: $calendarPresented, arrowEdge: .top) {
                            CalendarPopoverView(selectedDate: $selectedDate)
                        }
                    }

                    Spacer(minLength: 8)

                    toolbarButton("新建便签（Command + N）", systemImage: "square.and.pencil") {
                        commandPresented = false
                        create()
                    }

                    toolbarButton(
                        windowLocked ? "取消窗口置顶（不是加密）" : "窗口置顶（不是加密）",
                        systemImage: windowLocked ? "pin.fill" : "pin",
                        action: {
                            commandPresented = false
                            toggleWindowLock()
                        }
                    )

                    toolbarButton("打开设置", systemImage: "gearshape", tooltipAlignment: .bottomTrailing) {
                        commandPresented = false
                        calendarPresented = false
                        settingsPresented.toggle()
                    }
                }
                .padding(.leading, 74)
                .padding(.trailing, 10)

                HStack(spacing: 2) {
                    toolbarButton("编辑工具", systemImage: "slider.horizontal.3") {
                        calendarPresented = false
                        settingsPresented = false
                        editorController.captureSelection()
                        commandPresented.toggle()
                    }
                    .background(
                        commandPresented ? Color.primary.opacity(0.065) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .popover(isPresented: $commandPresented, arrowEdge: .top) {
                        NoteFormatPopover(
                            controller: editorController,
                            toggleChecklist: editorController.toggleChecklistItemAtSelection,
                            chooseFiles: chooseFiles
                        )
                    }

                    toolbarButton(
                        isAIFormatting ? "停止 AI 排版" : "AI 排版",
                        systemImage: isAIFormatting ? "stop.circle" : "wand.and.stars",
                        action: {
                            commandPresented = false
                            toggleAIFormatting()
                        }
                    )
                }
                .padding(.horizontal, 4)
                .frame(height: 30)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            }
            .frame(height: 38)
            .background(Color(nsColor: theme.toolbarBackground))
            .zIndex(1)

            if let aiFormattingNoteTitle {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("AI 正在排版：")
                        .foregroundStyle(.secondary)
                    Text(aiFormattingNoteTitle)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer()
                    Button("停止", action: toggleAIFormatting)
                        .buttonStyle(.borderless)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Color.accentColor.opacity(0.07))
            }

            if let preview = formattingPreview {
                HStack(spacing: 8) {
                    Text("排版待确认：\(preview.title)").lineLimit(1)
                    Spacer()
                    Button("查看预览") { previewPresented = true }
                    Button("放弃") { formattingPreview = nil }
                }
                .font(.system(size: 11))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.accentColor.opacity(0.06))
            }

            if let error = session.saveError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("保存失败：\(error.localizedDescription)")
                        .lineLimit(2)
                    Spacer()
                    Button("重试", action: session.retrySave)
                }
                .padding(8)
                .foregroundStyle(.white)
                .background(Color.red)
            }

            if let error = session.readError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("\(error.localizedDescription)\n未覆盖原记录，可在列表中选择其他便签。")
                        .font(.system(size: 11))
                        .lineLimit(3)
                    Spacer()
                    Button("存储位置") {
                        NSWorkspace.shared.open(error.url.deletingLastPathComponent())
                    }
                    Button("关闭", action: session.dismissReadError)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
            }

            Divider()

            HStack(spacing: 0) {
                if drawerOpen {
                    NoteDrawerView(
                        notes: notes,
                        folders: folders,
                        selectedID: session.currentNote?.id,
                        select: open,
                        create: create,
                        createFolder: createFolder,
                        renameFolder: renameFolder,
                        deleteFolder: deleteFolder,
                        move: move,
                        togglePin: togglePin,
                        delete: delete,
                        theme: theme,
                        showSearch: {
                            settingsPresented = false
                            calendarPresented = false
                            commandPresented = false
                            searchPresented = true
                        },
                        editTags: { note in
                            if session.openRecovering(note) { tagsPresented = true }
                        }
                    )
                    .frame(width: 210)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                    Divider()
                }

                ZStack(alignment: .topLeading) {
                    RichTextEditor(
                        document: session.document,
                        cursorLocation: session.currentNote?.cursorLocation ?? 0,
                        controller: editorController,
                        onChange: { document, cursor in
                            guard session.currentNote?.id == noteID else { return }
                            session.update(document: document, cursorLocation: cursor)
                        },
                        onActivate: activateEditor,
                        noteID: noteID,
                        externalEditRevision: session.externalEditRevision,
                        onSelectionChange: { cursor in
                            guard let note = session.currentNote, note.id == noteID,
                                  note.cursorLocation != cursor else { return }
                            note.cursorLocation = cursor
                        },
                        backgroundColor: theme.editorBackground,
                        textColor: theme.textColor,
                        overridesDocumentTextColor: theme.overridesDocumentTextColor
                    )

                    if session.document.string.isEmpty {
                        Text("开始记录…")
                            .font(.system(size: 15, weight: .light))
                            .foregroundStyle(Color(nsColor: theme.textColor).opacity(0.35))
                            .padding(.leading, 17)
                            .padding(.top, 13)
                            .allowsHitTesting(false)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if notes.count > 1 {
                        HStack {
                            Spacer(minLength: 0)
                            NoteNavigationControls(previousTitle: neighboringNote(-1)?.title,
                                                   nextTitle: neighboringNote(1)?.title, navigate: navigateNote)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: theme.editorBackground))
                    }
                }
            }
        }
        .background(Color(nsColor: theme.editorBackground))
        .tint(Color(nsColor: theme.accentColor))
        .preferredColorScheme(theme.colorScheme)
        .ignoresSafeArea(.container, edges: .top)
        .disabled(searchPresented)
        .overlay(alignment: .topTrailing) {
            if settingsPresented {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { settingsPresented = false }

                    QuickNoteSettingsView(
                        selectedTheme: $selectedTheme,
                        petEnabled: $petEnabled,
                        open: showSettings,
                        openAISettings: {
                            settingsPresented = false
                            showAISettings()
                        }
                    )
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
                        .padding(.top, 4)
                        .padding(.trailing, 8)
                }
            }
        }
        .overlay {
            if searchPresented {
                let close = { searchPresented = false }
                GeometryReader { geometry in
                    ZStack {
                        Color.primary.opacity(0.15)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture(perform: close)
                            .accessibilityLabel("关闭搜索背景")
                        NoteSearchPanel(notes: notes, folders: folders, theme: theme, search: searchNotes,
                            select: { note, query in
                                if query.isEmpty { open(note) } else { openSearchMatch(note, query: query) }
                                close()
                            }, close: close,
                            size: CGSize(width: min(480, geometry.size.width - 32),
                                         height: min(380, geometry.size.height - 32)))
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .contentShape(RoundedRectangle(cornerRadius: 22))
                            .onTapGesture { }
                            .shadow(color: .black.opacity(0.16), radius: 16, y: 4)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            searchPresented = false
        }
        .sheet(item: $settingsDestination) { destination in
            QuickNoteSettingsDetailView(
                destination: destination,
                locations: noteStorageLocations,
                session: session,
                allNotes: allNotes,
                didChangeLibrary: reloadLibraryRecovering
            )
        }
        .sheet(isPresented: $previewPresented) {
            if let preview = formattingPreview {
                AIFormattingPreviewView(preview: preview, apply: applyFormattingPreview) {
                    previewPresented = false
                }
            }
        }
        .sheet(isPresented: $tagsPresented) {
            VStack(alignment: .trailing, spacing: 0) {
                Button("完成") { tagsPresented = false }.padding([.top, .trailing], 12)
                NoteTagsPopover(session: session)
            }
        }
        .onChange(of: session.currentNote?.id) { _, _ in
            do { try reloadLibrary(resetNavigation: false) }
            catch { NSAlert(error: error).runModal() }
        }
        .onChange(of: petEnabled) { _, enabled in desktopPet?.setEnabled(enabled) }
        .onAppear {
            reloadLibraryRecovering()
            shortcutMonitor.start(window: { editorController.window }, action: performShortcut)
        }
        .onDisappear {
            shortcutMonitor.stop()
            aiFormattingTask?.cancel()
            if let id = aiFormattingID { desktopPet?.finish(id, message: "已停止排版", clip: "attention") }
        }
    }

    private var theme: NoteTheme {
        NoteTheme.resolved(from: selectedTheme)
    }

    private func toggleDrawer() {
        if !drawerOpen { reloadLibraryRecovering() }
        setDrawerOpen(!drawerOpen)
    }

    private func open(_ note: NoteRecord) {
        navigationOrder.refresh(notes: notes, folders: folders, reset: true)
        session.openRecovering(note)
    }

    private func neighboringNote(_ offset: Int) -> NoteRecord? {
        guard let id = navigationOrder.neighbor(of: session.currentNote?.id, offset: offset) else { return nil }
        return notes.first { $0.id == id }
    }

    private func navigateNote(_ offset: Int) {
        do {
            try reloadLibrary(resetNavigation: false)
            guard let note = neighboringNote(offset) else { return }
            commandPresented = false
            calendarPresented = false
            settingsPresented = false
            _ = session.openRecovering(note) // Existing save/read recovery must succeed before switching.
        } catch { NSAlert(error: error).runModal() }
    }

    private func openSearchMatch(_ note: NoteRecord, query: String) {
        guard session.openRecovering(note) else { return }
        DispatchQueue.main.async {
            guard session.currentNote?.id == note.id else { return }
            _ = editorController.findText(query)
        }
    }

    private func create() {
        session.createAndOpenRecovering()
    }

    private func togglePin(_ note: NoteRecord) {
        if session.togglePinnedRecovering(note) {
            reloadLibraryRecovering()
        }
    }

    private func delete(_ note: NoteRecord) {
        if session.deleteRecovering(note) {
            reloadLibraryRecovering()
        }
    }

    private func createFolder(_ name: String) throws {
        try createFolderAction(name)
        try reloadLibrary()
    }

    private func renameFolder(_ folder: NoteFolder, to name: String) throws {
        try renameFolderAction(folder, name)
        try reloadLibrary()
    }

    private func deleteFolder(_ folder: NoteFolder) {
        do {
            try deleteFolderAction(folder)
            try reloadLibrary()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func move(_ note: NoteRecord, to folder: NoteFolder?) {
        do {
            try moveNoteAction(note, folder)
            try reloadLibrary()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func reloadLibraryRecovering() {
        do {
            try reloadLibrary()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func reloadLibrary(resetNavigation: Bool = true) throws {
        let refreshedNotes = try allNotes()
        let refreshedFolders = try allFolders()
        notes = refreshedNotes
        folders = refreshedFolders
        navigationOrder.refresh(notes: refreshedNotes, folders: refreshedFolders, reset: resetNavigation)
    }

    private func toggleWindowLock() {
        windowLocked.toggle()
        setWindowLocked(windowLocked)
    }

    private func showSettings(_ destination: QuickNoteSettingsDestination) {
        if destination == .localStorage {
            do {
                noteStorageLocations = try allNotes().map { note in
                    NoteStorageLocation(
                        id: note.id,
                        title: note.title,
                        url: session.documentURL(for: note),
                        isCurrent: note.id == session.currentNote?.id
                    )
                }
            } catch {
                NSAlert(error: error).runModal()
                return
            }
        }
        settingsPresented = false
        DispatchQueue.main.async { settingsDestination = destination }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "插入"
        guard panel.runModal() == .OK else { return }
        do {
            try editorController.insertFiles(panel.urls)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func toggleAIFormatting() {
        if isAIFormatting {
            if let id = aiFormattingID { desktopPet?.finish(id, message: "已停止排版", clip: "attention") }
            aiFormattingTask?.cancel()
            aiFormattingTask = nil
            aiFormattingID = nil
            aiFormattingNoteTitle = nil
            isAIFormatting = false
            return
        }
        if formattingPreview != nil {
            previewPresented = true
            return
        }
        do {
            guard let note = session.currentNote else { throw AIFormattingError.noContent }
            guard AIConfigurationStore.shared.confirmSending(.text, content: "发送“\(note.title)”的文字用于排版，不发送附件原文件。") else { return }
            let noteID = note.id
            let revision = session.contentRevision(for: noteID)
            let source = try editorController.aiFormattingSource()
            let baseline = NSAttributedString(attributedString: session.document)
            guard baseline.string == source.document.string else { throw AIFormattingError.documentChanged }
            let requestID = UUID()
            isAIFormatting = true
            aiFormattingID = requestID
            aiFormattingNoteTitle = source.documentText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty }) ?? note.title
            desktopPet?.begin(id: requestID, message: "正在排版…", detail: aiFormattingNoteTitle ?? note.title)
            aiFormattingTask = Task {
                defer {
                    if aiFormattingID == requestID {
                        isAIFormatting = false
                        aiFormattingTask = nil
                        aiFormattingID = nil
                        aiFormattingNoteTitle = nil
                    }
                }
                do {
                    let result = try await AITextAnalyzer.respond(
                        instruction: AIFormattingPlan.instruction,
                        text: source.material,
                        store: .shared
                    )
                    try Task.checkCancellation()
                    let plan = try AIFormattingPlan.parse(result.text)
                    try Task.checkCancellation()
                    guard session.contentRevision(for: noteID) == revision else {
                        throw AIFormattingError.documentChanged
                    }
                    let document = try editorController.formattedDocument(plan, source: source)
                    formattingPreview = AIFormattingPreview(noteID: noteID, revision: revision,
                        title: aiFormattingNoteTitle ?? note.title, baseline: baseline,
                        original: source.document, formatted: document)
                    desktopPet?.finish(requestID, message: "排版好了，等你确认")
                } catch {
                    guard !Task.isCancelled else {
                        desktopPet?.finish(requestID, message: "已停止排版", clip: "attention")
                        return
                    }
                    desktopPet?.finish(requestID, message: "排版遇到问题", clip: "attention")
                    NSAlert(error: error).runModal()
                }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func applyFormattingPreview() throws {
        guard let preview = formattingPreview else { return }
        do {
            try session.applyAIFormattedDocument(preview.formatted, original: preview.baseline,
                expectedRevision: preview.revision, noteID: preview.noteID)
        } catch let error as NoteContentAppliedError {
            formattingPreview = nil
            previewPresented = false
            throw error
        }
        formattingPreview = nil
        previewPresented = false
        try reloadLibrary()
    }

    private func performShortcut(_ shortcut: QuickNoteShortcut) {
        guard !searchPresented else { return }
        switch shortcut {
        case .zoomIn:
            editorController.zoom(by: 0.1)
        case .zoomOut:
            editorController.zoom(by: -0.1)
        case .toggleSidebar:
            toggleDrawer()
        case .newNote:
            create()
        case .insertLink:
            promptForLink()
        case .previousNote:
            navigateNote(-1)
        case .nextNote:
            navigateNote(1)
        }
    }

    private func promptForLink() {
        let field = NSTextField(string: editorController.selectedLinkSuggestion)
        field.placeholderString = "https://example.com"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)

        let alert = NSAlert()
        alert.messageText = "插入链接"
        alert.informativeText = "输入网址；未选择文字时会插入网址本身。"
        alert.accessoryView = field
        alert.addButton(withTitle: "插入")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field

        while alert.runModal() == .alertFirstButtonReturn {
            if editorController.applyLink(field.stringValue) { return }
            alert.informativeText = "请输入有效的 http 或 https 地址。"
            NSSound.beep()
        }
    }

    private func setDrawerOpen(_ open: Bool) {
        drawerVisibilityChanged(open)
        if reduceMotion {
            drawerOpen = open
        } else {
            withAnimation(.easeOut(duration: 0.16)) { drawerOpen = open }
        }
    }

    private func toolbarButton(
        _ label: String,
        systemImage: String,
        tooltipAlignment: Alignment = .bottom,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .quickNoteHoverHighlight()
        .quickNoteTooltip(label, alignment: tooltipAlignment)
        .accessibilityLabel(label)
    }
}

private struct AIFormattingPreviewView: View {
    let preview: AIFormattingPreview
    let apply: () throws -> Void
    let close: () -> Void
    @State private var showingOriginal = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI 排版预览").font(.system(size: 18, weight: .medium))
            Text(preview.title).font(.system(size: 13)).lineLimit(1)
            let count = AIFormattingComparison.changedParagraphCount(before: preview.original, after: preview.formatted)
            Text(count == 0 ? "未发现排版变化，原便签未改动。" : "调整了 \(count) 个段落的样式。文字和附件保持不变；应用后可在版本记录中恢复。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("对比", selection: $showingOriginal) {
                Text("排版后").tag(false)
                Text("排版前").tag(true)
            }
            .pickerStyle(.segmented)
            ReadOnlyNotePreview(document: showingOriginal ? preview.original : preview.formatted)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
            HStack {
                Button("稍后处理", action: close)
                Spacer()
                Button("应用排版") {
                    do { try apply() } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
            }
        }
        .padding(18)
        .frame(width: min(620, (NSScreen.main?.visibleFrame.width ?? 900) - 80), height: 500)
    }
}

struct ReadOnlyNotePreview: NSViewRepresentable {
    let document: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 14, height: 14)
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        if !text.attributedString().isEqual(to: document) {
            text.textStorage?.setAttributedString(document)
        }
    }
}

private struct NoteThemePicker: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("便签主题")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            ForEach(NoteTheme.allCases) { theme in
                Button {
                    selection = theme.rawValue
                } label: {
                    HStack(spacing: 10) {
                        HStack(spacing: 0) {
                            Color(nsColor: theme.sidebarBackground)
                            Color(nsColor: theme.editorBackground)
                        }
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                        .overlay {
                            Circle().stroke(Color(nsColor: theme.accentColor).opacity(0.75), lineWidth: 1)
                        }

                        Text(theme.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(nsColor: theme.accentColor))
                            .opacity(selection == theme.rawValue ? 1 : 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .background(
                        selection == theme.rawValue
                            ? Color(nsColor: theme.accentColor).opacity(0.12)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .quickNoteHoverHighlight(cornerRadius: 7, enabled: selection != theme.rawValue)
                .accessibilityLabel("切换到\(theme.name)主题")
            }
        }
        .padding(10)
        .frame(width: 190)
    }
}

private struct NoteFormatPopover: View {
    @ObservedObject var controller: RichTextEditorController
    let toggleChecklist: () -> Void
    let chooseFiles: () -> Void
    @State private var colorsPresented = false
    @State private var paragraphPresented = false
    @State private var tablePresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                formatButton("B", help: "粗体", state: controller.selectionState.bold, action: controller.toggleBold)
                    .fontWeight(.bold)
                formatButton("I", help: "斜体", state: controller.selectionState.italic, action: controller.toggleItalic)
                    .italic()
                formatButton("U", help: "下划线", state: controller.selectionState.underline, action: controller.toggleUnderline)
                    .underline()
                formatButton("S", help: "删除线", state: controller.selectionState.strike, action: controller.toggleStrikethrough)
                    .strikethrough()
                Divider().frame(height: 22)
                Button {
                    colorsPresented.toggle()
                } label: {
                    Text("A")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .background(Color.yellow.opacity(0.48), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.borderless)
                .quickNoteHoverHighlight(cornerRadius: 5)
                .help("文字与背景颜色")
                .accessibilityLabel("文字与背景颜色")
                .popover(isPresented: $colorsPresented, arrowEdge: .trailing) {
                    EditorColorPopover(controller: controller)
                }

                Button {
                    paragraphPresented.toggle()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "text.alignleft")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .frame(width: 32, height: 26)
                }
                .buttonStyle(.borderless)
                .quickNoteHoverHighlight(cornerRadius: 5)
                .help("对齐与缩进")
                .accessibilityLabel("对齐与缩进")
                .popover(isPresented: $paragraphPresented, arrowEdge: .trailing) {
                    ParagraphFormatPopover(controller: controller)
                }
            }
            .padding(.bottom, 7)

            Divider()

            ForEach(EditorTextStyle.allCases) { style in
                Button {
                    controller.applyTextStyle(style)
                } label: {
                    HStack {
                        Text(style.title)
                            .font(.system(size: min(style.font.pointSize, 18), weight: .regular))
                        Spacer()
                        if controller.selectionState.textStyle == style {
                            Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(Color.accentColor)
                        }
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .quickNoteHoverHighlight(cornerRadius: 5)
                .accessibilityValue(controller.selectionState.textStyle == style ? "当前样式" : "")
            }
            if controller.selectionState.textStyle == nil {
                Text("混合或自定义样式").font(.system(size: 10)).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 4)

            formatRow("项目符号列表", image: "list.bullet") { controller.applyList(.disc) }
            formatRow("短划线列表", image: "list.dash") { controller.applyList(.hyphen) }
            formatRow("编号列表", image: "list.number") { controller.applyList(.decimal) }
            formatRow("块引用", image: "text.quote", action: controller.applyBlockQuote)

            Divider().padding(.vertical, 4)

            Text("插入")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .padding(.bottom, 4)

            HStack(spacing: 5) {
                insertButton("待办", image: "checklist", action: toggleChecklist)
                    .help("点击添加或取消待办")
                    .background(controller.selectionState.checklist == .off ? Color.clear : Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityValue(controller.selectionState.checklist == .mixed ? "混合待办" : (controller.selectionState.checklist == .on ? "已添加待办" : "未添加待办"))
                insertButton("表格", image: "tablecells") { tablePresented.toggle() }
                    .popover(isPresented: $tablePresented, arrowEdge: .trailing) {
                        TablePickerPopover(controller: controller)
                    }
                insertButton("附件", image: "paperclip", action: chooseFiles)
            }
        }
        .padding(10)
        .frame(width: 220)
    }

    private func formatButton(_ title: String, help: String, state: EditorToggleState, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17))
                .frame(width: 25, height: 26)
                .background(state == .off ? Color.clear : Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .bottomTrailing) {
                    if state == .mixed { Text("−").font(.system(size: 9)).foregroundStyle(Color.accentColor) }
                }
        }
        .buttonStyle(.borderless)
        .quickNoteHoverHighlight(cornerRadius: 5)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(state == .mixed ? "混合" : (state == .on ? "已启用" : "未启用"))
    }

    private func formatRow(
        _ title: String,
        image: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: image)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .quickNoteHoverHighlight(cornerRadius: 5)
    }

    private func insertButton(
        _ title: String,
        image: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: image)
                .font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .quickNoteHoverHighlight(cornerRadius: 6)
        .accessibilityLabel(title)
    }

}

private struct ParagraphFormatPopover: View {
    @ObservedObject var controller: RichTextEditorController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if controller.selectionState.alignment == nil {
                Text("混合对齐").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            paragraphRow("左对齐", image: "text.alignleft", selected: controller.selectionState.alignment == .left || controller.selectionState.alignment == .natural) { controller.applyAlignment(.left) }
            paragraphRow("居中对齐", image: "text.aligncenter", selected: controller.selectionState.alignment == .center) { controller.applyAlignment(.center) }
            paragraphRow("右对齐", image: "text.alignright", selected: controller.selectionState.alignment == .right) { controller.applyAlignment(.right) }
            Divider().padding(.vertical, 4)
            Menu {
                lineSpacingButton("单倍", value: 1)
                lineSpacingButton("1.25 倍", value: 1.25)
                lineSpacingButton("1.5 倍", value: 1.5)
                lineSpacingButton("双倍", value: 2)
            } label: {
                Label("行间距", systemImage: "arrow.up.and.down.text.horizontal")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .frame(height: 30)
            }
            .menuStyle(.borderlessButton)
            paragraphRow("增加缩进", image: "increase.indent") { controller.changeIndent(by: 18) }
            paragraphRow("减少缩进", image: "decrease.indent") { controller.changeIndent(by: -18) }
        }
        .padding(8)
        .frame(width: 160)
    }

    private func paragraphRow(
        _ title: String,
        image: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: image)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 10)) }
            }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .frame(height: 30)
        }
        .buttonStyle(.plain)
        .quickNoteHoverHighlight(cornerRadius: 5)
    }

    private func lineSpacingButton(_ title: String, value: CGFloat) -> some View {
        Button(title) { controller.applyLineHeightMultiple(value) }
    }
}

private struct EditorColorPopover: View {
    let controller: RichTextEditorController

    private let textColors: [(name: String, color: NSColor)] = [
        ("默认", .labelColor), ("灰色", .systemGray), ("红色", .systemRed),
        ("橙色", .systemOrange), ("黄色", .systemYellow), ("绿色", .systemGreen),
        ("青色", .systemCyan), ("蓝色", .systemBlue), ("紫色", .systemPurple), ("粉色", .systemPink),
    ]
    private let backgroundColors: [(name: String, color: NSColor)] = [
        ("灰色", .systemGray), ("红色", .systemRed), ("橙色", .systemOrange),
        ("黄色", .systemYellow), ("绿色", .systemGreen), ("薄荷色", .systemMint),
        ("青色", .systemCyan), ("蓝色", .systemBlue), ("紫色", .systemPurple), ("粉色", .systemPink),
    ]
    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 6), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("字体颜色")
                .font(.system(size: 12, weight: .medium))

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(textColors, id: \.name) { item in
                    Button {
                        controller.applyTextColor(item.color)
                    } label: {
                        Text("A")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Color(nsColor: item.color))
                            .frame(width: 28, height: 28)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .quickNoteHoverHighlight(cornerRadius: 5)
                    .help(item.name)
                    .accessibilityLabel("字体颜色：\(item.name)")
                }
            }

            Divider()

            Text("背景颜色")
                .font(.system(size: 12, weight: .medium))

            LazyVGrid(columns: columns, spacing: 6) {
                Button {
                    controller.applyBackgroundColor(nil)
                } label: {
                    Image(systemName: "nosign")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .quickNoteHoverHighlight(cornerRadius: 5)
                .help("无背景色")
                .accessibilityLabel("无背景色")

                ForEach(backgroundColors.prefix(9), id: \.name) { item in
                    Button {
                        controller.applyBackgroundColor(item.color.withAlphaComponent(0.28))
                    } label: {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: item.color).opacity(0.4))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .quickNoteHoverHighlight(cornerRadius: 5)
                    .help(item.name)
                    .accessibilityLabel("背景颜色：\(item.name)")
                }
            }

            Button("恢复默认") {
                controller.applyTextColor(.labelColor)
                controller.applyBackgroundColor(nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .frame(width: 190)
    }
}

private struct TablePickerPopover: View {
    @ObservedObject var controller: RichTextEditorController
    @Environment(\.dismiss) private var dismiss
    @State private var rows = 2
    @State private var columns = 2

    private let maximumSize = 8
    private let gridColumns = Array(repeating: GridItem(.fixed(22), spacing: 4), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(rows) 行 × \(columns) 列")
                .font(.system(size: 13, weight: .semibold))

            Text("移动鼠标选择表格大小")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .padding(.bottom, 10)

            LazyVGrid(columns: gridColumns, spacing: 4) {
                ForEach(0..<(maximumSize * maximumSize), id: \.self) { index in
                    let row = index / maximumSize + 1
                    let column = index % maximumSize + 1
                    tableCell(row: row, column: column)
                }
            }

            Divider()
                .padding(.vertical, 10)

            HStack {
                Button("增加行") { controller.insertTableRow() }
                Button("删除行") { controller.deleteTableRow() }
            }
            .disabled(!controller.isSelectionInTable)
            HStack {
                Button("增加列") { controller.insertTableColumn() }
                Button("删除列") { controller.deleteTableColumn() }
            }
            .disabled(!controller.isSelectionInTable)
            .padding(.top, 4)

            Button("删除表格", systemImage: "trash", role: .destructive) {
                if controller.deleteCurrentTable() {
                    dismiss()
                } else {
                    NSSound.beep()
                }
            }
            .buttonStyle(.borderless)
            .disabled(!controller.isSelectionInTable)
        }
        .padding(12)
        .frame(width: 228)
    }

    private func tableCell(row: Int, column: Int) -> some View {
        let selected = row <= rows && column <= columns
        return Button {
            controller.insertTable(rows: row, columns: column)
            dismiss()
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(
                            selected ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor),
                            lineWidth: 1
                        )
                }
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                rows = row
                columns = column
            }
        }
        .help("插入 \(row) 行 × \(column) 列表格")
        .accessibilityLabel("插入 \(row) 行 × \(column) 列表格")
    }
}

private struct NoteTagsPopover: View {
    @ObservedObject var session: NoteSession
    @State private var input = ""

    private let columns = [GridItem(.adaptive(minimum: 82), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("标签")
                .font(.system(size: 15, weight: .semibold))

            if session.tags.isEmpty {
                Text("用标签整理并搜索便签。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(session.tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text("#\(tag)").lineLimit(1)
                            Button {
                                session.setTags(session.tags.filter { $0 != tag })
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移除标签 \(tag)")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7)
                        .frame(height: 24)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("添加标签", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTag)
                Button("添加", action: addTag)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private func addTag() {
        session.setTags(session.tags + [input])
        input = ""
    }
}

private enum QuickNoteSettingsDestination: String, Identifiable {
    case localStorage
    case shortcuts
    case help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localStorage: "本地存储"
        case .shortcuts: "快捷键"
        case .help: "帮助与权限"
        }
    }

    var systemImage: String {
        switch self {
        case .localStorage: "folder"
        case .shortcuts: "keyboard"
        case .help: "questionmark.circle"
        }
    }
}

private struct NoteStorageLocation: Identifiable {
    let id: UUID
    let title: String
    let url: URL
    let isCurrent: Bool
}

private struct QuickNoteSettingsView: View {
    @Binding var selectedTheme: String
    @Binding var petEnabled: Bool
    let open: (QuickNoteSettingsDestination) -> Void
    let openAISettings: () -> Void
    @State private var themePresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.bottom, 2)

            Toggle(isOn: $petEnabled) {
                Label("Pip 桌宠陪伴", systemImage: "bird")
                    .font(.system(size: 13, weight: .regular))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.horizontal, 6)
            .frame(height: 30)
            .help("Pip，陪你随手记的小鸟；可拖动与右键操作")
            .accessibilityHint("显示或隐藏独立桌宠；收起便签不影响桌宠，关闭桌宠不影响 AI 功能")
            settingsButton("便签主题", systemImage: "paintpalette") {
                themePresented.toggle()
            }
            .accessibilityHint("选择便签主题")
            .popover(isPresented: $themePresented, arrowEdge: .trailing) {
                NoteThemePicker(selection: $selectedTheme)
            }
            settingsButton("AI 模型", systemImage: "sparkles", action: openAISettings)
            settingsButton(.localStorage)
            settingsButton(.shortcuts)
            settingsButton(.help)
        }
        .padding(8)
        .frame(width: 176)
    }

    private func settingsButton(_ destination: QuickNoteSettingsDestination) -> some View {
        settingsButton(destination.title, systemImage: destination.systemImage) {
            open(destination)
        }
    }

    private func settingsButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .quickNoteHoverHighlight(cornerRadius: 6)
        .accessibilityHint("打开详细页面")
    }
}

private struct QuickNoteSettingsDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let destination: QuickNoteSettingsDestination
    @State var locations: [NoteStorageLocation]
    @ObservedObject var session: NoteSession
    let allNotes: () throws -> [NoteRecord]
    let didChangeLibrary: () -> Void
    @State private var storageTab = 0
    @State private var deletedNotes: [NoteRecord] = []
    @State private var historyNoteID: UUID?
    @State private var versions: [NoteVersion] = []
    @State private var storageNotice = ""
    @State private var storageError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Label(destination.title, systemImage: destination.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 12)

            Divider()

            detail
                .padding(.top, 12)
        }
        .padding(16)
        .frame(width: detailSize.width, height: detailSize.height)
        .onAppear {
            if destination == .localStorage {
                historyNoteID = session.currentNote?.id
                refreshStorage()
            }
        }
        .onChange(of: historyNoteID) { _, _ in loadVersions() }
    }

    private var detailSize: CGSize {
        switch destination {
        case .localStorage: CGSize(width: 560, height: 480)
        case .shortcuts: CGSize(width: 430, height: 500)
        case .help: CGSize(width: 500, height: 390)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch destination {
        case .localStorage:
            localStorageDetail
        case .shortcuts:
            shortcutsDetail
        case .help:
            helpDetail
        }
    }

    private var localStorageDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("导出整库备份", action: exportBackup)
                Button("导入备份副本", action: importBackup)
                Spacer()
            }
            .controlSize(.small)
            Text("备份含便签、素材、目录和非密钥设置，不含 API Key。文件未加密；导入不会覆盖现有便签。单文件上限 64 MB，整库上限 512 MB。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("存储管理", selection: $storageTab) {
                Text("便签文件").tag(0)
                Text("最近删除（\(deletedNotes.count)）").tag(1)
                Text("版本记录").tag(2)
            }
            .pickerStyle(.segmented)
            if !storageNotice.isEmpty {
                Text(storageNotice).font(.caption).foregroundStyle(storageError ? Color.red : Color.secondary).lineLimit(3)
            }
            if storageTab == 1 {
                deletedNotesList
            } else if storageTab == 2 {
                versionList
            } else {
            HStack {
                Text("每条便签保存为独立的 RTFD 文档。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if let folder = locations.first?.url.deletingLastPathComponent() {
                    Button("打开存储文件夹") { NSWorkspace.shared.open(folder) }
                        .controlSize(.small)
                }
            }

            if locations.isEmpty {
                Spacer()
                Text("暂无便签")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(locations) { location in
                            storageRow(location)
                        }
                    }
                }
            }
            }
        }
    }

    private var deletedNotesList: some View {
        VStack(alignment: .leading) {
            Text("已删除的便签保留在本机，不会自动清空。")
                .font(.caption).foregroundStyle(.secondary)
            if deletedNotes.isEmpty {
                Text("最近删除为空").foregroundStyle(.secondary).padding(.top, 20)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(deletedNotes) { note in
                        HStack {
                            Text(note.title).lineLimit(1)
                            Spacer()
                            Button("恢复") {
                                storageOperation {
                                    try session.restoreDeleted(note)
                                    return "已恢复“\(note.title)”"
                                }
                            }
                            .controlSize(.small)
                        }
                        .font(.system(size: 12))
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var versionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("便签", selection: $historyNoteID) {
                Text("选择便签").tag(Optional<UUID>.none)
                ForEach(locations) { note in Text(note.title).tag(Optional(note.id)) }
            }
            Text("每篇保留最近 20 个版本。恢复前也会保留当前内容，方便返回。")
                .font(.caption).foregroundStyle(.secondary)
            if versions.isEmpty { Text("暂无历史版本").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(versions) { version in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(version.date.formatted(date: .abbreviated, time: .standard))
                                Text(versionReason(version.reason)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("恢复此版本") { restoreVersion(version) }.controlSize(.small)
                        }
                        .font(.system(size: 12))
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private func versionReason(_ reason: String) -> String {
        switch reason {
        case "import": "导入前"
        case "aiFormatting": "AI 排版前"
        case "restore": "恢复历史前"
        case "delete": "删除前"
        default: "编辑前"
        }
    }

    private func restoreVersion(_ version: NoteVersion) {
        guard let noteID = historyNoteID else { return }
        let alert = NSAlert()
        alert.messageText = "恢复这个版本？"
        alert.informativeText = "将替换该便签的当前内容。替换前会保存当前版本；其他便签不会改变。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        storageOperation {
            try session.restoreVersion(version, for: noteID)
            return "已恢复，可关闭设置查看便签。"
        }
    }

    private func exportBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "选择备份位置"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let name = "QuickNote-\(Date().formatted(.iso8601.year().month().day()))-\(UUID().uuidString.prefix(8)).quicknotebackup"
        let destination = folder.appending(path: name)
        storageOperation {
            try session.exportBackup(to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
            return "整库备份已导出。API Key 仍只保存在钥匙串。"
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "导入备份副本"
        panel.message = "选择完整的 QuickNote 备份文件夹。将添加副本，不覆盖现有便签。"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        storageOperation {
            let count = try session.importBackup(from: folder)
            return "已导入 \(count) 篇便签副本。AI 密钥需在新机器上重新填写。"
        }
    }

    private func storageOperation(_ action: () throws -> String) {
        do {
            storageNotice = try action()
            storageError = false
            refreshStorage()
            didChangeLibrary()
        } catch {
            storageNotice = error.localizedDescription
            storageError = true
        }
    }

    private func refreshStorage() {
        do {
            deletedNotes = try session.deletedNotes()
            locations = try allNotes().map { note in
                NoteStorageLocation(id: note.id, title: note.title, url: session.documentURL(for: note),
                    isCurrent: note.id == session.currentNote?.id)
            }
            loadVersions()
        } catch {
            storageNotice = error.localizedDescription
            storageError = true
        }
    }

    private func loadVersions() {
        do { versions = try historyNoteID.map(session.versions) ?? [] }
        catch {
            versions = []
            storageNotice = error.localizedDescription
            storageError = true
        }
    }

    private var shortcutsDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("核心快捷键", systemImage: "bolt.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 0) {
                shortcutRow(keys: ["⌘", "⌘"], title: "双击 Command", detail: "打开或收起 QuickNote", emphasized: true)
                shortcutDivider
                shortcutRow(keys: ["⌥", "Space"], title: "Option + 空格", detail: "分析当前选中的文字", emphasized: true)
                shortcutDivider
                shortcutRow(keys: ["⌘", "⇧"], title: "Command + Shift", detail: "选择区域截图并使用 AI 分析", emphasized: true)
            }
            .padding(.horizontal, 6)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
            }

            Text("其他快捷键")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(spacing: 0) {
                shortcutRow(keys: ["⌘", "+ / −"], title: "Command + / −", detail: "放大或缩小便签内容")
                shortcutDivider
                shortcutRow(keys: ["⌘", "B"], title: "Command + B", detail: "展开或收起侧边栏")
                shortcutDivider
                shortcutRow(keys: ["⌘", "⌥", "← / →"], title: "Command + Option + 方向键", detail: "上一条或下一条便签，无需展开侧栏")
                shortcutDivider
                shortcutRow(keys: ["⌘", "N"], title: "Command + N", detail: "新建便签")
                shortcutDivider
                shortcutRow(keys: ["⌘", "K"], title: "Command + K", detail: "为选中文字插入链接")
                shortcutDivider
                shortcutRow(keys: ["⌘", "Z"], title: "Command + Z", detail: "撤销最近一次文字或格式操作")
            }
        }
    }

    private var shortcutDivider: some View {
        Divider().padding(.leading, 112)
    }

    private var helpDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            permissionRow(
                title: "输入监控",
                detail: "隐私与安全性 → 输入监控，用于识别双击 Command。",
                button: "打开设置",
                settingsPane: "Privacy_ListenEvent"
            )
            Divider()
            permissionRow(
                title: "辅助功能",
                detail: "隐私与安全性 → 辅助功能，用于读取你主动选中的文字。",
                button: "打开设置",
                settingsPane: "Privacy_Accessibility"
            )
            Divider()
            permissionRow(
                title: "屏幕录制",
                detail: "隐私与安全性 → 屏幕与系统音频录制，用于你主动触发的截图识图。",
                button: "打开设置",
                settingsPane: "Privacy_ScreenCapture"
            )
            Divider()
            Label("API Key 只保存在这台 Mac 的系统钥匙串中。", systemImage: "key")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func storageRow(_ location: NoteStorageLocation) -> some View {
        Button { reveal(location.url) } label: {
            HStack(spacing: 12) {
                Image(systemName: "note.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(location.title.isEmpty ? "新便签" : location.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if location.isCurrent {
                            Text("当前")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(location.url.path)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .linkColor))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "arrow.forward.circle")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .quickNoteHoverHighlight(cornerRadius: 8)
        .help("在访达中显示")
    }

    private func shortcutRow(
        keys: [String],
        title: String,
        detail: String,
        emphasized: Bool = false
    ) -> some View {
        HStack(spacing: 20) {
            HStack(spacing: 5) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(size: key == "Space" ? 9 : 13, weight: .medium))
                        .frame(minWidth: key == "Space" || key == "+ / −" ? 44 : 24, minHeight: 24)
                        .background(
                            emphasized ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(
                                    emphasized ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.25),
                                    lineWidth: 1
                                )
                        }
                }
            }
            .frame(width: 92, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(height: 42)
    }

    private func permissionRow(
        title: String,
        detail: String,
        button: String,
        settingsPane: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Button(button) { openSystemSettings(settingsPane) }
                .controlSize(.small)
        }
    }

    private func openSystemSettings(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

private struct CalendarPopoverView: View {
    @Binding var selectedDate: Date
    @State private var displayedMonth: Date

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 7)

    init(selectedDate: Binding<Date>) {
        _selectedDate = selectedDate
        _displayedMonth = State(initialValue: CalendarText.startOfMonth(for: selectedDate.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(CalendarText.fullDate(for: selectedDate))
                .font(.system(size: 20, weight: .semibold))

            HStack(spacing: 10) {
                Text(CalendarText.weekday(for: selectedDate))
                Text(CalendarText.lunarDate(for: selectedDate))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.top, 6)

            Divider()
                .padding(.vertical, 12)

            HStack {
                Text(CalendarText.monthTitle(for: displayedMonth))
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                monthButton("上个月", image: "chevron.left", offset: -1)
                monthButton("下个月", image: "chevron.right", offset: 1)
            }
            .padding(.bottom, 8)

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(CalendarText.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 20)
                }

                ForEach(Array(CalendarText.monthGrid(containing: displayedMonth).enumerated()), id: \.offset) { _, date in
                    dayButton(date)
                }
            }
        }
        .padding(14)
        .frame(width: 248)
    }

    private func monthButton(_ label: String, image: String, offset: Int) -> some View {
        Button {
            displayedMonth = CalendarText.addingMonths(offset, to: displayedMonth)
        } label: {
            Image(systemName: image)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .quickNoteHoverHighlight(cornerRadius: 5)
        .help(label)
        .accessibilityLabel(label)
    }

    private func dayButton(_ date: Date) -> some View {
        let selected = CalendarText.isSameDay(date, selectedDate)
        let inMonth = CalendarText.isSameMonth(date, displayedMonth)
        let today = CalendarText.isToday(date)

        return Button {
            selectedDate = date
            displayedMonth = CalendarText.startOfMonth(for: date)
        } label: {
            Text(CalendarText.dayNumber(for: date))
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.5)))
                .frame(width: 28, height: 28)
                .background {
                    if selected {
                        Circle().fill(Color.accentColor)
                    } else if today {
                        Circle().stroke(Color.secondary.opacity(0.45), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .quickNoteHoverHighlight(cornerRadius: 14, enabled: !selected)
        .accessibilityLabel(CalendarText.fullDate(for: date))
    }
}

enum CalendarText {
    static let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

    static func toolbarDate(for date: Date, timeZone: TimeZone = .current) -> String {
        let components = gregorianComponents(for: date, timeZone: timeZone)
        return "\(components.month ?? 0)月\(components.day ?? 0)日"
    }

    static func fullDate(for date: Date, timeZone: TimeZone = .current) -> String {
        let components = gregorianComponents(for: date, timeZone: timeZone)
        return "\(components.year ?? 0)年\(components.month ?? 0)月\(components.day ?? 0)日"
    }

    static func weekday(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let names = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        return names[calendar.component(.weekday, from: date) - 1]
    }

    static func lunarDate(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .chinese)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.month, .day, .isLeapMonth], from: date)
        let months = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]
        let days = [
            "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
            "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
            "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
        ]
        guard let month = components.month,
              let day = components.day,
              months.indices.contains(month - 1),
              days.indices.contains(day - 1) else { return "农历" }
        return "农历 \(components.isLeapMonth == true ? "闰" : "")\(months[month - 1])\(days[day - 1])"
    }

    static func monthTitle(for date: Date, timeZone: TimeZone = .current) -> String {
        let components = gregorianComponents(for: date, timeZone: timeZone)
        return "\(components.year ?? 0)年\(components.month ?? 0)月"
    }

    static func dayNumber(for date: Date, timeZone: TimeZone = .current) -> String {
        String(gregorianComponents(for: date, timeZone: timeZone).day ?? 0)
    }

    static func startOfMonth(for date: Date, timeZone: TimeZone = .current) -> Date {
        let calendar = gregorianCalendar(timeZone: timeZone)
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    static func addingMonths(_ count: Int, to date: Date, timeZone: TimeZone = .current) -> Date {
        gregorianCalendar(timeZone: timeZone).date(byAdding: .month, value: count, to: date) ?? date
    }

    static func monthGrid(containing date: Date, timeZone: TimeZone = .current) -> [Date] {
        var calendar = gregorianCalendar(timeZone: timeZone)
        calendar.firstWeekday = 1
        let month = startOfMonth(for: date, timeZone: timeZone)
        let leadingDays = calendar.component(.weekday, from: month) - calendar.firstWeekday
        guard let first = calendar.date(byAdding: .day, value: -leadingDays, to: month) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    static func isSameDay(_ lhs: Date, _ rhs: Date, timeZone: TimeZone = .current) -> Bool {
        gregorianCalendar(timeZone: timeZone).isDate(lhs, inSameDayAs: rhs)
    }

    static func isSameMonth(_ lhs: Date, _ rhs: Date, timeZone: TimeZone = .current) -> Bool {
        let calendar = gregorianCalendar(timeZone: timeZone)
        return calendar.dateComponents([.year, .month], from: lhs)
            == calendar.dateComponents([.year, .month], from: rhs)
    }

    static func isToday(_ date: Date, timeZone: TimeZone = .current) -> Bool {
        gregorianCalendar(timeZone: timeZone).isDateInToday(date)
    }

    private static func gregorianComponents(for date: Date, timeZone: TimeZone) -> DateComponents {
        let calendar = gregorianCalendar(timeZone: timeZone)
        return calendar.dateComponents([.year, .month, .day], from: date)
    }

    private static func gregorianCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
