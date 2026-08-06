import Carbon
import XCTest
@testable import QuickNote

final class AppShellTests: XCTestCase {
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

    func testTranslationRequestsPronunciationForBothTargetLanguages() {
        XCTAssertTrue(AITextAction.translate.instruction.contains("拼音"))
        XCTAssertTrue(AITextAction.translate.instruction.contains("IPA"))
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

    func testSelectionResultPanelGrowsWithContentAndStopsBeforeClipping() {
        let short = SelectionPanelLayout.resultHeight(for: "简短解释")
        let medium = SelectionPanelLayout.resultHeight(for: String(repeating: "容器化部署说明。", count: 30))
        let long = SelectionPanelLayout.resultHeight(for: String(repeating: "很长的分析内容。", count: 300))

        XCTAssertEqual(short, 300)
        XCTAssertGreaterThan(medium, short)
        XCTAssertEqual(long, 390)
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
