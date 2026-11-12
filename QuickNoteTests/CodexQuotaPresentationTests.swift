import Foundation
import XCTest
@testable import QuickNote

final class CodexQuotaPresentationTests: XCTestCase {
    private let fiveHour = CodexRateLimitWindow(usedPercent: 17, resetsAt: nil)
    private let weekly = CodexRateLimitWindow(usedPercent: 32.5, resetsAt: Date(timeIntervalSince1970: 1_800_000_000))

    func testSuccessfulQuotaDisplaysBothReturnedWindowsInOrder() {
        let limits = CodexRateLimits(fiveHour: fiveHour, weekly: weekly)

        XCTAssertEqual(CodexQuotaPresentation(state: .loaded, limits: limits), .usage([
            .init(period: .fiveHour, window: fiveHour),
            .init(period: .weekly, window: weekly)
        ]))
    }

    func testSuccessfulQuotaOmitsEitherMissingWindow() {
        XCTAssertEqual(CodexQuotaPresentation(state: .loaded, limits: .init(fiveHour: nil, weekly: weekly)),
                       .usage([.init(period: .weekly, window: weekly)]))
        XCTAssertEqual(CodexQuotaPresentation(state: .loaded, limits: .init(fiveHour: fiveHour, weekly: nil)),
                       .usage([.init(period: .fiveHour, window: fiveHour)]))
    }

    func testSuccessfulEmptyQuotaAndIdleHideTheSection() {
        XCTAssertEqual(CodexQuotaPresentation(state: .loaded, limits: .init(fiveHour: nil, weekly: nil)), .hidden)
        XCTAssertEqual(CodexQuotaPresentation(state: .loaded, limits: nil), .hidden)
        XCTAssertEqual(CodexQuotaPresentation(state: .idle, limits: nil), .hidden)
    }

    func testQuotaLoadingRetainsKnownRowsWithoutAddingPlaceholders() {
        XCTAssertEqual(CodexQuotaPresentation(state: .loading, limits: nil), .loading([]))
        XCTAssertEqual(CodexQuotaPresentation(state: .loading, limits: .init(fiveHour: nil, weekly: weekly)),
                       .loading([.init(period: .weekly, window: weekly)]))
    }

    func testQuotaFailurePreservesReasonWithoutShowingStaleUsage() {
        let limits = CodexRateLimits(fiveHour: fiveHour, weekly: weekly)

        XCTAssertEqual(CodexQuotaPresentation(state: .failed("连接已超时"), limits: limits),
                       .failed("连接已超时"))
    }
}
