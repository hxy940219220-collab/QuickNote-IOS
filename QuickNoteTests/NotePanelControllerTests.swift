import AppKit
import XCTest
@testable import QuickNote

@MainActor
final class NotePanelControllerTests: XCTestCase {
    func testPanelFrameCentersWithinVisibleFrameWithNonZeroOrigin() {
        let visibleFrame = NSRect(x: 1_920, y: 48, width: 1_440, height: 900)

        let frame = NotePanelController.panelFrame(in: visibleFrame)

        XCTAssertEqual(frame, NSRect(x: 2_430, y: 238, width: 420, height: 520))
    }

    func testRevealFrameScalesAroundPanelCenter() {
        let frame = NSRect(x: 100, y: 200, width: 420, height: 520)

        let revealFrame = NotePanelController.revealFrame(from: frame)

        XCTAssertEqual(revealFrame, NSRect(x: 112, y: 215, width: 396, height: 490))
    }
}
