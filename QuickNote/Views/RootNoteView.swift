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
}

enum QuickNoteShortcut: Equatable {
    case zoomIn
    case zoomOut
    case toggleSidebar
    case newNote
    case insertLink

    static func resolve(
        characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> QuickNoteShortcut? {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
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

    func start(action: @escaping (QuickNoteShortcut) -> Void) {
        self.action = action
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
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

struct RootNoteView: View {
    @ObservedObject var session: NoteSession
    let allNotes: () throws -> [NoteRecord]
    let allFolders: () throws -> [NoteFolder]
    let createFolderAction: (String) throws -> Void
    let renameFolderAction: (NoteFolder, String) throws -> Void
    let deleteFolderAction: (NoteFolder) throws -> Void
    let moveNoteAction: (NoteRecord, NoteFolder?) throws -> Void
    let activateEditor: () -> Void
    let drawerVisibilityChanged: (Bool) -> Void
    let setWindowLocked: (Bool) -> Void
    let showAISettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var editorController = RichTextEditorController()
    @StateObject private var shortcutMonitor = QuickNoteShortcutMonitor()
    @State private var drawerOpen = false
    @State private var windowLocked = false
    @State private var calendarPresented = false
    @State private var settingsPresented = false
    @State private var settingsDestination: QuickNoteSettingsDestination?
    @State private var noteStorageLocations: [NoteStorageLocation] = []
    @State private var themePresented = false
    @State private var formatPresented = false
    @State private var tablePresented = false
    @State private var selectedDate = Date()
    @State private var notes: [NoteRecord] = []
    @State private var folders: [NoteFolder] = []
    @AppStorage("appearance.noteTheme") private var selectedTheme = NoteTheme.system.rawValue

    var body: some View {
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
                            selectedDate = context.date
                            calendarPresented.toggle()
                        } label: {
                            Text(CalendarText.toolbarDate(for: context.date))
                                .font(.system(size: 12, weight: .medium))
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

                    toolbarButton("便签主题", systemImage: "paintpalette") {
                        themePresented.toggle()
                    }
                    .popover(isPresented: $themePresented, arrowEdge: .top) {
                        NoteThemePicker(selection: $selectedTheme)
                    }

                    toolbarButton("AI 模型", systemImage: "sparkles", action: showAISettings)

                    toolbarButton(
                        windowLocked ? "取消锁定" : "锁定在最前",
                        systemImage: windowLocked ? "lock.fill" : "lock.open",
                        action: toggleWindowLock
                    )

                    toolbarButton("设置", systemImage: "gearshape") {
                        settingsPresented.toggle()
                    }
                }
                .padding(.leading, 74)
                .padding(.trailing, 10)

                HStack(spacing: 2) {
                    toolbarButton("格式", systemImage: "textformat") {
                        formatPresented.toggle()
                    }
                    .popover(isPresented: $formatPresented, arrowEdge: .top) {
                        NoteFormatPopover(controller: editorController)
                    }

                    toolbarButton("插入待办项", systemImage: "checklist") {
                        editorController.insertChecklistItem()
                    }

                    toolbarButton("表格", systemImage: "tablecells") {
                        tablePresented.toggle()
                    }
                    .popover(isPresented: $tablePresented, arrowEdge: .top) {
                        TablePickerPopover(controller: editorController)
                    }

                    toolbarButton("插入文件", systemImage: "paperclip", action: chooseFiles)
                }
                .padding(.horizontal, 4)
                .frame(height: 30)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            }
            .frame(height: 38)
            .background(Color(nsColor: theme.toolbarBackground))

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
                        theme: theme
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
                        onChange: session.update,
                        onActivate: activateEditor,
                        backgroundColor: theme.editorBackground,
                        textColor: theme.textColor,
                        overridesDocumentTextColor: theme.overridesDocumentTextColor
                    )

                    if session.document.string.isEmpty {
                        Text("开始记录…")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(nsColor: theme.textColor).opacity(0.35))
                            .padding(.leading, 17)
                            .padding(.top, 13)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .background(Color(nsColor: theme.editorBackground))
        .tint(Color(nsColor: theme.accentColor))
        .preferredColorScheme(theme.colorScheme)
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .topTrailing) {
            if settingsPresented {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { settingsPresented = false }

                    QuickNoteSettingsView(open: showSettings)
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
        .sheet(item: $settingsDestination) { destination in
            QuickNoteSettingsDetailView(
                destination: destination,
                locations: noteStorageLocations
            )
        }
        .onAppear { shortcutMonitor.start(action: performShortcut) }
        .onDisappear { shortcutMonitor.stop() }
    }

    private var theme: NoteTheme {
        NoteTheme.resolved(from: selectedTheme)
    }

    private func toggleDrawer() {
        if !drawerOpen { reloadLibraryRecovering() }
        setDrawerOpen(!drawerOpen)
    }

    private func open(_ note: NoteRecord) {
        let previousNoteID = session.currentNote?.id
        if session.openRecovering(note) {
            if session.currentNote?.id != previousNoteID {
                editorController.clearUndoHistory()
            }
        }
    }

    private func create() {
        if session.createAndOpenRecovering() {
            editorController.clearUndoHistory()
        }
    }

    private func togglePin(_ note: NoteRecord) {
        if session.togglePinnedRecovering(note) {
            reloadLibraryRecovering()
        }
    }

    private func delete(_ note: NoteRecord) {
        let deletingCurrentNote = session.currentNote?.id == note.id
        if session.deleteRecovering(note) {
            if deletingCurrentNote {
                editorController.clearUndoHistory()
            }
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

    private func reloadLibrary() throws {
        let refreshedNotes = try allNotes()
        let refreshedFolders = try allFolders()
        notes = refreshedNotes
        folders = refreshedFolders
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

    private func performShortcut(_ shortcut: QuickNoteShortcut) {
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
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .quickNoteHoverHighlight()
        .help(label)
        .accessibilityLabel(label)
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
    let controller: RichTextEditorController
    @State private var colorsPresented = false
    @State private var paragraphPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                formatButton("B", help: "粗体", action: controller.toggleBold)
                    .fontWeight(.bold)
                formatButton("I", help: "斜体", action: controller.toggleItalic)
                    .italic()
                formatButton("U", help: "下划线", action: controller.toggleUnderline)
                    .underline()
                formatButton("S", help: "删除线", action: controller.toggleStrikethrough)
                    .strikethrough()
                Divider().frame(height: 24)
                Button {
                    colorsPresented.toggle()
                } label: {
                    Text("A")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
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
                    .frame(width: 36, height: 28)
                }
                .buttonStyle(.borderless)
                .quickNoteHoverHighlight(cornerRadius: 5)
                .help("对齐与缩进")
                .accessibilityLabel("对齐与缩进")
                .popover(isPresented: $paragraphPresented, arrowEdge: .trailing) {
                    ParagraphFormatPopover(controller: controller)
                }
            }
            .padding(.bottom, 10)

            Divider()

            ForEach(EditorTextStyle.allCases) { style in
                Button {
                    controller.applyTextStyle(style)
                } label: {
                    Text(style.title)
                        .font(.system(size: min(style.font.pointSize, 18), weight: style == .body ? .regular : .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .quickNoteHoverHighlight(cornerRadius: 5)
            }

            Divider().padding(.vertical, 6)

            formatRow("项目符号列表", image: "list.bullet") { controller.applyList(.disc) }
            formatRow("短划线列表", image: "list.dash") { controller.applyList(.hyphen) }
            formatRow("编号列表", image: "list.number") { controller.applyList(.decimal) }
            formatRow("块引用", image: "text.quote", action: controller.applyBlockQuote)
        }
        .padding(12)
        .frame(width: 240)
    }

    private func formatButton(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .quickNoteHoverHighlight(cornerRadius: 5)
        .help(help)
        .accessibilityLabel(help)
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
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .quickNoteHoverHighlight(cornerRadius: 5)
    }

}

private struct ParagraphFormatPopover: View {
    let controller: RichTextEditorController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            paragraphRow("左对齐", image: "text.alignleft") { controller.applyAlignment(.left) }
            paragraphRow("居中对齐", image: "text.aligncenter") { controller.applyAlignment(.center) }
            paragraphRow("右对齐", image: "text.alignright") { controller.applyAlignment(.right) }
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
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: image)
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
    let controller: RichTextEditorController
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

            Button("删除表格", systemImage: "trash", role: .destructive) {
                if controller.deleteCurrentTable() {
                    dismiss()
                } else {
                    NSSound.beep()
                }
            }
            .buttonStyle(.borderless)
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
    let open: (QuickNoteSettingsDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设置")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.bottom, 2)

            settingsButton(.localStorage)
            settingsButton(.shortcuts)
            settingsButton(.help)
        }
        .padding(8)
        .frame(width: 176)
    }

    private func settingsButton(_ destination: QuickNoteSettingsDestination) -> some View {
        Button { open(destination) } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage)
                    .frame(width: 18)
                Text(destination.title)
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
    let locations: [NoteStorageLocation]

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
    }

    private var detailSize: CGSize {
        switch destination {
        case .localStorage: CGSize(width: 560, height: 420)
        case .shortcuts: CGSize(width: 430, height: 410)
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

    private var shortcutsDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                shortcutRow(keys: ["⌘", "⌘"], title: "双击 Command", detail: "打开或收起 QuickNote")
                shortcutDivider
                shortcutRow(keys: ["⌥", "Space"], title: "Option + 空格", detail: "分析当前选中的文字")
                shortcutDivider
                shortcutRow(keys: ["⌘", "+ / −"], title: "Command + / −", detail: "放大或缩小便签内容")
                shortcutDivider
                shortcutRow(keys: ["⌘", "B"], title: "Command + B", detail: "展开或收起侧边栏")
                shortcutDivider
                shortcutRow(keys: ["⌘", "N"], title: "Command + N", detail: "新建便签")
                shortcutDivider
                shortcutRow(keys: ["⌘", "K"], title: "Command + K", detail: "为选中文字插入链接")
                shortcutDivider
                shortcutRow(keys: ["⌘", "Z"], title: "Command + Z", detail: "撤销最近一次文字或格式操作")
                shortcutDivider
                shortcutRow(keys: ["⌘", "⇧"], title: "Command + Shift", detail: "选择区域截图并使用 AI 分析")
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

    private func shortcutRow(keys: [String], title: String, detail: String) -> some View {
        HStack(spacing: 20) {
            HStack(spacing: 5) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.system(size: key == "Space" ? 9 : 13, weight: .medium))
                        .frame(minWidth: key == "Space" || key == "+ / −" ? 44 : 24, minHeight: 24)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
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
