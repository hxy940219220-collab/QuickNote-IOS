import XCTest
@testable import QuickNote

final class AppShellTests: XCTestCase {
    func testConfiguredDoubleCommandIntervalIsThreeTenthsOfASecond() {
        XCTAssertEqual(AppConfiguration.doubleCommandInterval, 0.300, accuracy: 0.001)
    }
}
