import SwiftUI

struct RootNoteView: View {
    @ObservedObject var session: NoteSession
    let allNotes: () throws -> [NoteRecord]
    let activateEditor: () -> Void
    let drawerVisibilityChanged: (Bool) -> Void
    let setWindowLocked: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawerOpen = false
    @State private var windowLocked = false
    @State private var calendarPresented = false
    @State private var selectedDate = Date()
    @State private var notes: [NoteRecord] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                toolbarButton(
                    "便签列表",
                    systemImage: "sidebar.left",
                    action: toggleDrawer
                )
                .offset(y: -1)
                .keyboardShortcut("k", modifiers: .command)

                Spacer(minLength: 8)

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

private struct CalendarPopoverView: View {
    @Binding var selectedDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(CalendarText.fullDate(for: selectedDate))
                .font(.system(size: 18, weight: .semibold))

            HStack(spacing: 10) {
                Text(CalendarText.weekday(for: selectedDate))
                Text(CalendarText.lunarDate(for: selectedDate))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))

            Divider()

            DatePicker("日期", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "zh_CN"))
        }
        .padding(14)
        .frame(width: 240)
    }
}

enum CalendarText {
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

    private static func gregorianComponents(for date: Date, timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day], from: date)
    }
}
