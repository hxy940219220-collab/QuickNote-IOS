import AppKit
import Carbon
import XCTest
@testable import QuickNote

private final class UndoableTestTextView: NSTextView {
    private let testUndoManager = UndoManager()

    override var undoManager: UndoManager? { testUndoManager }
}

final class AppShellTests: XCTestCase {
    @MainActor
    func testEditorUndoRestoresLatestTextEdit() throws {
        let controller = RichTextEditorController()
        let textView = UndoableTestTextView()
        textView.allowsUndo = true
        controller.connect(textView)

        textView.insertText("内容", replacementRange: textView.selectedRange())
        controller.refreshUndoAvailability()
        XCTAssertTrue(controller.canUndo)
        controller.undo()

        XCTAssertEqual(textView.string, "")
    }

    @MainActor
    func testEditorUndoRestoresLatestFormattingEditAndSelection() throws {
        let controller = RichTextEditorController()
        let textView = UndoableTestTextView()
        textView.allowsUndo = true
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "标题",
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        ))
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 2))
        controller.connect(textView)

        controller.toggleBold()
        XCTAssertTrue(controller.canUndo)
        controller.undo()

        let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 2))
    }

    @MainActor
    func testEditorUndoRestoresTypingFormatWithoutSelection() throws {
        let controller = RichTextEditorController()
        let textView = UndoableTestTextView()
        textView.allowsUndo = true
        textView.typingAttributes[.font] = NSFont.systemFont(ofSize: 15)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.connect(textView)

        controller.toggleBold()
        XCTAssertTrue(controller.canUndo)
        let boldFont = try XCTUnwrap(textView.typingAttributes[.font] as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))

        controller.undo()

        let restoredFont = try XCTUnwrap(textView.typingAttributes[.font] as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: restoredFont).contains(.boldFontMask))
    }

    func testChineseCalendarDetailsForKnownDate() throws {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let date = try XCTUnwrap(
            gregorian.date(from: DateComponents(year: 2026, month: 8, day: 6))
        )

        XCTAssertEqual(CalendarText.toolbarDate(for: date, timeZone: gregorian.timeZone), "8月6日")
        XCTAssertEqual(CalendarText.fullDate(for: date, timeZone: gregorian.timeZone), "2026年8月6日")
        XCTAssertEqual(CalendarText.weekday(for: date, timeZone: gregorian.timeZone), "星期四")
        XCTAssertEqual(CalendarText.lunarDate(for: date, timeZone: gregorian.timeZone), "农历 六月廿四")

        let grid = CalendarText.monthGrid(containing: date, timeZone: gregorian.timeZone)
        XCTAssertEqual(grid.count, 42)
        XCTAssertEqual(CalendarText.fullDate(for: try XCTUnwrap(grid.first), timeZone: gregorian.timeZone), "2026年7月26日")
        XCTAssertEqual(CalendarText.fullDate(for: try XCTUnwrap(grid.last), timeZone: gregorian.timeZone), "2026年9月5日")
    }

    @MainActor
    func testMonitorDoesNotStartWhenInputMonitoringIsDenied() {
        let monitor = CommandEventMonitor()

        XCTAssertFalse(
            monitor.start(onDoubleCommand: {}, ensureListenAccess: { false })
        )
    }

    func testDisabledEventTapSignalsRequireRecovery() {
        XCTAssertTrue(CommandEventMonitor.requiresTapRecovery(for: .tapDisabledByTimeout))
        XCTAssertTrue(CommandEventMonitor.requiresTapRecovery(for: .tapDisabledByUserInput))
        XCTAssertFalse(CommandEventMonitor.requiresTapRecovery(for: .flagsChanged))
    }

    func testSelectionHotKeyIsOptionSpace() {
        XCTAssertEqual(CommandEventMonitor.selectionHotKeyCode, 49)
        XCTAssertEqual(CommandEventMonitor.selectionHotKeyModifiers, UInt32(optionKey))
    }

    func testProviderPresetsBuildOpenAICompatibleChatURLs() throws {
        for provider in AIProvider.allCases {
            let configuration = AIConfiguration(
                provider: provider,
                baseURL: provider.defaultBaseURL,
                model: provider.defaultModel,
                apiKey: "test"
            )
            let url = try XCTUnwrap(configuration.chatCompletionsURL)
            XCTAssertTrue(url.absoluteString.hasSuffix("/chat/completions"), provider.name)
            XCTAssertFalse(url.absoluteString.contains("//chat/completions"), provider.name)
        }
    }

    func testTranslationExcludesURLsAndLimitsPronunciation() {
        let instruction = AITextAction.translate.instruction

        XCTAssertTrue(instruction.contains("网址原样保留"))
        XCTAssertTrue(instruction.contains("10 个汉字"))
        XCTAssertTrue(instruction.contains("10 个英文单词"))
    }

    func testTranslationPronunciationLineFindsTextToSpeak() {
        let lines = ["Digital Life", "音标： /ˈdɪdʒɪtl laɪf/"]

        XCTAssertEqual(SelectionResultFormatter.pronunciationKind(for: lines[1])?.languageCode, "en-US")
        XCTAssertEqual(SelectionResultFormatter.pronunciationSource(in: lines, before: 1), "Digital Life")
        XCTAssertNil(SelectionResultFormatter.pronunciationKind(for: "普通译文"))
    }

    func testTranslationRemovesPronunciationWhenSourceExceedsLimit() {
        let result = "Space utilization, read-write efficiency, and management complexity\n音标： /test/"

        XCTAssertEqual(
            SelectionResultFormatter.enforcingPronunciationLimit(
                in: result,
                source: "空间利用率、读写效率和管理复杂度"
            ),
            "Space utilization, read-write efficiency, and management complexity"
        )
        XCTAssertTrue(SelectionResultFormatter.pronunciationIsAllowed(for: "空间利用率"))
    }

    @MainActor
    func testAPIKeysUseOneCanonicalKeychainVault() {
        XCTAssertEqual(AIConfigurationStore.keychainVaultAccount, "profiles.v1")
    }

    func testAIConfigurationFillsSidebarWithNineModelSlots() {
        XCTAssertEqual(AIProfileSlot.allCases.map(\.title), (1...9).map { "模型 \($0)" })
        XCTAssertEqual(AIProfileSlot.allCases.count, 9)
    }

    @MainActor
    func testModelSlotNamesCanBeRenamedAndReset() throws {
        let suite = "QuickNoteTests.AIProfileName.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIConfigurationStore(defaults: defaults)

        store.rename(.fourth, to: "  工作模型  ")
        XCTAssertEqual(store.displayName(for: .fourth), "工作模型")
        store.rename(.fourth, to: "  ")
        XCTAssertEqual(store.displayName(for: .fourth), "模型 4")
    }

    @MainActor
    func testActivatingModelReplacesThePreviousActiveSlot() throws {
        let suite = "QuickNoteTests.ActiveAIProfile.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIConfigurationStore(defaults: defaults)
        store.activeSlot = .first

        XCTAssertEqual(store.activate(.third), .third)
        XCTAssertEqual(store.activeSlot, .third)
    }

    @MainActor
    func testInputModalitiesPersistIndependentlyForEachModel() throws {
        let suite = "QuickNoteTests.AIInputModalities.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIConfigurationStore(defaults: defaults)

        store.saveInputModalities([.image, .video], for: .third)

        XCTAssertEqual(store.inputModalities(for: .third), [.text, .image, .video])
        XCTAssertEqual(store.inputModalities(for: .first), [.text])
    }

    func testSelectionResultPanelGrowsWithContentAndStopsBeforeClipping() {
        let short = SelectionPanelLayout.resultHeight(for: "简短解释")
        let medium = SelectionPanelLayout.resultHeight(for: String(repeating: "容器化部署说明。", count: 30))
        let long = SelectionPanelLayout.resultHeight(for: String(repeating: "很长的分析内容。", count: 300))

        XCTAssertEqual(short, 300)
        XCTAssertGreaterThan(medium, short)
        XCTAssertEqual(long, 390)
    }

    func testSelectionSourcePreviewRemainsResizableWhenResultIsVisible() {
        XCTAssertEqual(SelectionPanelLayout.sourcePreviewMaximumHeight, .infinity)
    }

    func testAllSidebarNotesUseTheSameLeadingIndent() {
        XCTAssertEqual(NoteDrawerLayout.noteLeadingIndent, 20)
    }

    func testNoteThemesOfferFiveChoicesAndFallBackToSystem() {
        XCTAssertEqual(NoteTheme.allCases.map(\.rawValue), [
            "system", "paper", "sage", "lavender", "midnight", "blue",
        ])
        XCTAssertEqual(NoteTheme.resolved(from: "missing"), .system)
        XCTAssertEqual(NoteTheme.system.accentColor, .secondaryLabelColor)
        XCTAssertTrue(NoteTheme.midnight.overridesDocumentTextColor)
        XCTAssertFalse(NoteTheme.blue.overridesDocumentTextColor)
    }

    func testSelectionSourceFormatterRestoresBulletLineBreaks() {
        let source = "它在产品栈里的位置 • Pydantic AI：负责 Agent Loop • AI Gateway：负责模型入口"

        XCTAssertEqual(
            SelectionSourceFormatter.normalized(source),
            "它在产品栈里的位置\n• Pydantic AI：负责 Agent Loop\n• AI Gateway：负责模型入口"
        )
    }

    func testSelectionResultFormatterRendersMarkdownWithoutSourceMarkers() {
        let result = SelectionResultFormatter.plainText(
            from: "**测试用例**\n\n```swift\nlet passed = true\n```"
        )

        XCTAssertFalse(result.contains("**"))
        XCTAssertFalse(result.contains("```"))
        XCTAssertTrue(result.contains("测试用例"))
        XCTAssertTrue(result.contains("let passed = true"))
    }

    func testSelectionResultFormatterUsesOneBodySizeAfterTheTitle() throws {
        let result = SelectionResultFormatter.richText(
            from: "# Agent 框架\n## 背景\n1. Pydantic AI\n**Open Stack（开放栈）**：说明",
            asDocumentStart: true
        )

        XCTAssertEqual(result.string, "Agent 框架\n背景\n1. Pydantic AI\nOpen Stack（开放栈）：说明")
        let title = try XCTUnwrap(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(title.pointSize, 26)
        for text in ["背景", "1. Pydantic AI", "Open Stack"] {
            let location = (result.string as NSString).range(of: text).location
            let font = try XCTUnwrap(result.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, 15, text)
        }
        let boldLocation = (result.string as NSString).range(of: "Open Stack").location
        let bold = try XCTUnwrap(result.attribute(.font, at: boldLocation, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testSelectionResultFormatterDoesNotAddAnotherLargeTitleMidNote() throws {
        let result = SelectionResultFormatter.richText(
            from: "# 补充内容\n正文",
            asDocumentStart: false
        )

        for location in [0, (result.string as NSString).range(of: "正文").location] {
            let font = try XCTUnwrap(result.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, 15)
        }
    }

    func testSelectionResultFormatterReplacesDashHierarchyWithLabelsAndBullets() throws {
        let result = SelectionResultFormatter.richText(
            from: "- 含义：用于构建 Agent\n- 关键术语：\n  - Agent Loop：主循环\n    - 子步骤",
            asDocumentStart: false
        )

        XCTAssertEqual(
            result.string,
            "含义：用于构建 Agent\n关键术语：\n• Agent Loop：主循环\n◦ 子步骤"
        )
        let labelFont = try XCTUnwrap(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(labelFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testConfiguredDoubleCommandIntervalAllowsAComfortableDoubleTap() {
        XCTAssertEqual(AppConfiguration.doubleCommandInterval, 0.500, accuracy: 0.001)
    }

    @MainActor
    func testLaunchAndDockReopenPresentWithoutToggling() {
        var presentations = 0
        let lifecycle = AppPresentationLifecycle {
            presentations += 1
        }

        lifecycle.applicationDidLaunch()
        XCTAssertEqual(presentations, 1)

        XCTAssertTrue(lifecycle.applicationShouldHandleReopen())
        XCTAssertEqual(presentations, 2)

        XCTAssertTrue(lifecycle.applicationShouldHandleReopen())
        XCTAssertEqual(presentations, 3)
    }
}
