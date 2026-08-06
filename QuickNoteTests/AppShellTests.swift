import XCTest
@testable import QuickNote

final class AppShellTests: XCTestCase {
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
