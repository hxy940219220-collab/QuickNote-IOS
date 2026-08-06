import AppKit
import SwiftUI

struct RootNoteView: View {
    @ObservedObject var session: NoteSession
    let allNotes: () throws -> [NoteRecord]
    let activateEditor: () -> Void
    let drawerVisibilityChanged: (Bool) -> Void
    let setWindowLocked: (Bool) -> Void
    let showAISettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var editorController = RichTextEditorController()
    @State private var drawerOpen = false
    @State private var windowLocked = false
    @State private var calendarPresented = false
    @State private var helpPresented = false
    @State private var formatPresented = false
    @State private var tablePresented = false
    @State private var selectedDate = Date()
    @State private var notes: [NoteRecord] = []

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
                    .keyboardShortcut("k", modifiers: .command)

                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Button {
                            selectedDate = context.date
                            calendarPresented.toggle()
                        } label: {
                            Text(CalendarText.toolbarDate(for: context.date))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .help("查看日历")
                        .accessibilityLabel(CalendarText.fullDate(for: context.date))
                        .popover(isPresented: $calendarPresented, arrowEdge: .top) {
                            CalendarPopoverView(selectedDate: $selectedDate)
                        }
                    }

                    Spacer(minLength: 8)

                    toolbarButton("权限与快捷键帮助", systemImage: "questionmark.circle") {
                        helpPresented.toggle()
                    }
                    .popover(isPresented: $helpPresented, arrowEdge: .top) {
                        QuickNoteHelpView()
                    }

                    toolbarButton("AI 模型", systemImage: "sparkles", action: showAISettings)

                    toolbarButton(
                        windowLocked ? "取消锁定" : "锁定在最前",
                        systemImage: windowLocked ? "lock.fill" : "lock.open",
                        action: toggleWindowLock
                    )

                    toolbarButton("新建便签", systemImage: "square.and.pencil", action: create)
                        .keyboardShortcut("n", modifiers: .command)
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
            .background(Color(nsColor: .windowBackgroundColor))

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
                        selectedID: session.currentNote?.id,
                        select: open,
                        create: create,
                        togglePin: togglePin,
                        delete: delete
                    )
                    .frame(width: 190)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                    Divider()
                }

                ZStack(alignment: .topLeading) {
                    RichTextEditor(
                        document: session.document,
                        cursorLocation: session.currentNote?.cursorLocation ?? 0,
                        controller: editorController,
                        onChange: session.update,
                        onActivate: activateEditor
                    )

                    if session.document.string.isEmpty {
                        Text("开始记录…")
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 17)
                            .padding(.top, 13)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private func toggleDrawer() {
        notes = (try? allNotes()) ?? []
        setDrawerOpen(!drawerOpen)
    }

    private func open(_ note: NoteRecord) {
        if session.openRecovering(note) { setDrawerOpen(false) }
    }

    private func create() {
        if session.createAndOpenRecovering() { setDrawerOpen(false) }
    }

    private func togglePin(_ note: NoteRecord) {
        if session.togglePinnedRecovering(note) {
            notes = (try? allNotes()) ?? notes
        }
    }

    private func delete(_ note: NoteRecord) {
        if session.deleteRecovering(note) {
            notes = (try? allNotes()) ?? notes.filter { $0.id != note.id }
        }
    }

    private func toggleWindowLock() {
        windowLocked.toggle()
        setWindowLocked(windowLocked)
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
        .help(label)
        .accessibilityLabel(label)
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

private struct QuickNoteHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("权限与快捷键")
                        .font(.system(size: 18, weight: .semibold))
                    Text("只开启需要的系统权限；完成后重新打开 QuickNote。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                permissionSection(
                    number: "1",
                    title: "输入监控",
                    path: "隐私与安全性 → 输入监控",
                    detail: "用于在 QuickNote 已运行时监听双击 Command，从而呼出或收起便签。若列表中没有 QuickNote，点“+”添加 /Applications/QuickNote.app，再打开开关。",
                    button: "打开输入监控",
                    settingsPane: "Privacy_ListenEvent"
                )

                Divider()

                permissionSection(
                    number: "2",
                    title: "辅助功能",
                    path: "隐私与安全性 → 辅助功能",
                    detail: "用于读取你主动选中的文字。选中文字后按 Option + 空格，即可打开 AI 分析栏。若列表中没有 QuickNote，点“+”添加 App 并打开开关。",
                    button: "打开辅助功能",
                    settingsPane: "Privacy_Accessibility"
                )

                Divider()

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("API Key 与钥匙串")
                            .font(.system(size: 13, weight: .semibold))
                        Text("API Key 只保存在这台 Mac 的系统钥匙串中。首次保存或使用时，macOS 会请求授权，请选择“始终允许”（推荐）或“允许”。AI 请求内容只会发送给你当前选择的服务商。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 380, height: 430)
    }

    private func permissionSection(
        number: String,
        title: String,
        path: String,
        detail: String,
        button: String,
        settingsPane: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(path)
                    .font(.system(size: 11, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(button) {
                    guard let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)"
                    ) else { return }
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
            }
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
