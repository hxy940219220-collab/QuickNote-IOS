import XCTest
@testable import QuickNote

final class AppShellTests: XCTestCase {
    func testConfiguredDoubleCommandIntervalIsThreeTenthsOfASecond() {
        XCTAssertEqual(AppConfiguration.doubleCommandInterval, 0.300, accuracy: 0.001)
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
