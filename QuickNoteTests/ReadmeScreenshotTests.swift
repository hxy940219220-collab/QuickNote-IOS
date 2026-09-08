import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import QuickNote

/// Renders the shipping views with disposable sample data. No user notes, microphone or API calls.
@MainActor
final class ReadmeScreenshotTests: XCTestCase {
    func testRenderCurrentReadmeScreenshots() async throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "quicknote-readme-current")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let container = try ModelContainer(for: NoteRecord.self, NoteFolder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repository = NoteRepository(context: container.mainContext)
        let documents = NoteDocumentStore(root: FileManager.default.temporaryDirectory.appending(path: "QuickNote-Readme-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: documents.root) }
        let session = NoteSession(repository: repository, documents: documents)
        let work = try repository.createFolder(named: "工作与项目")
        let life = try repository.createFolder(named: "生活与灵感")
        for (title, folder) in [("周末想去的地方", life), ("阅读摘录", life), ("下周行动清单", work), ("产品例会", work)] {
            try session.createAndOpen()
            try session.appendPlainText(title + "\n随手收下，让想法有处可去。")
            repository.move(try XCTUnwrap(session.currentNote), to: folder)
        }
        try session.createAndOpen()
        let document = NoteMarkdownImporter.richText(from: """
        # 把想法，留在手边

        ## 今天的灵感
        好的工具让记录更简单，不打断正在做的事。

        ## 下一步
        - [x] 收集这周的用户反馈
        - [ ] 明天下午三点，讨论新的交互方案
        - [ ] 把语音整理成清晰的行动清单

        ## 留一点空间
        灵感、会议要点、喜欢的一句话，都可以先记下来。
        """
        )
        session.update(document: document, cursorLocation: document.length)
        try session.flush()
        repository.move(try XCTUnwrap(session.currentNote), to: work)

        func snapshot(_ view: NSView, _ filename: String) throws {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appending(path: filename))
        }
        let root = RootNoteView(session: session, allNotes: repository.allNotes, searchNotes: repository.search,
            allFolders: repository.allFolders, createFolderAction: { _ in }, renameFolderAction: { _, _ in },
            deleteFolderAction: { _ in }, moveNoteAction: { _, _ in }, activateEditor: {},
            drawerVisibilityChanged: { _ in }, setWindowLocked: { _ in }, showAISettings: {})
        let host = NSHostingView(rootView: root)
        let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 730, height: 460),
            styleMask: NotePanelController.windowStyleMask.union(.nonactivatingPanel), backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200))
        window.makeKey()
        let sidebarKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        NSApp.sendEvent(sidebarKey)
        try await Task.sleep(for: .milliseconds(220))
        try snapshot(try XCTUnwrap(window.contentView?.superview), "overview.png")

        let notes = try repository.allNotes()
        let folders = try repository.allFolders()
        let searchHost = NSHostingView(rootView: NoteSearchPanel(notes: notes, folders: folders, theme: .system,
            search: repository.search, select: { _, _ in }, close: {}))
        let searchWindow = NSPanel(contentRect: NSRect(x: 120, y: 120, width: 480, height: 380),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        searchWindow.appearance = NSAppearance(named: .aqua)
        searchWindow.contentView = searchHost
        searchWindow.makeKeyAndOrderFront(nil)
        defer { searchWindow.orderOut(nil); searchWindow.contentView = nil }
        try await Task.sleep(for: .milliseconds(180))
        try snapshot(searchHost, "search.png")

        let defaultsName = "QuickNote-Readme-Pip-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        pet.setSoundEnabled(false)
        pet.setEnabled(true)
        pet.move(to: NSPoint(x: 500, y: 450), save: false)
        pet.notify("灵感来了？", detail: "说给我听，也可以拖进来。")
        try await Task.sleep(for: .milliseconds(200))
        try snapshot(try XCTUnwrap(pet.petPanel.contentView), "pip.png")
        let bubble = try XCTUnwrap(NSApp.windows.first { $0.title == "小胖鸟状态" && $0.isVisible })
        try snapshot(try XCTUnwrap(bubble.contentView), "pip-bubble.png")

        let voice = DesktopPetVoiceController(session: session, allNotes: repository.allNotes, pet: pet,
            showSettings: {}, openNote: { _ in }, analyze: { _, _ in
                AITextResult(text: "明天下午三点，和设计同事讨论新版搜索。\n\n先确认关闭按钮的点击范围，再检查键盘操作，最后记录需要调整的细节。", providerName: "演示结果")
            }, confirmSending: { _ in false })
        voice.show(startImmediately: false)
        defer { voice.close() }
        voice.recorder.start()
        voice.recorder.receiveRecognition("明天下午三点和设计同事讨论新版搜索，先确认关闭按钮点击范围再检查键盘操作最后记录需要调整的细节", isFinal: true, error: nil, token: voice.recorder.generation)
        try await Task.sleep(for: .milliseconds(240))
        let voiceWindow = try XCTUnwrap(NSApp.windows.first { $0.title == "说给小鸟听" && $0.isVisible })
        try snapshot(try XCTUnwrap(voiceWindow.contentView), "voice.png")
        XCTAssertFalse(voice.isWorking)
        XCTAssertEqual(session.document.string, document.string)
    }
}
