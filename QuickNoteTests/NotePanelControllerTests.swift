import AppKit
import SwiftUI
import XCTest
@testable import QuickNote

@MainActor
final class NotePanelControllerTests: XCTestCase {
    func testPanelFrameCentersWithinVisibleFrameWithNonZeroOrigin() {
        let visibleFrame = NSRect(x: 1_920, y: 48, width: 1_440, height: 900)

        let frame = NotePanelController.panelFrame(in: visibleFrame)

        XCTAssertEqual(frame, NSRect(x: 2_430, y: 238, width: 420, height: 520))
    }

    func testCollapsedFrameUsesLeftRailAsAnimationOrigin() {
        let visibleFrame = NSRect(x: 1_920, y: 48, width: 1_440, height: 900)

        let collapsedFrame = NotePanelController.collapsedFrame(in: visibleFrame)

        XCTAssertEqual(collapsedFrame, NSRect(x: 1_924, y: 489, width: 18, height: 18))
    }

    func testRailFrameCentersFittedContentOnPanelAnimationOrigin() {
        let visibleFrame = NSRect(x: 1_920, y: 48, width: 1_440, height: 900)
        let railFrame = EdgeRailController.railFrame(
            in: visibleFrame,
            contentSize: NSSize(width: 18, height: 31)
        )
        let collapsedFrame = NotePanelController.collapsedFrame(in: visibleFrame)

        XCTAssertEqual(railFrame, NSRect(x: 1_924, y: 482.5, width: 18, height: 31))
        XCTAssertEqual(railFrame.midX, collapsedFrame.midX)
        XCTAssertEqual(railFrame.midY, collapsedFrame.midY)
    }

    func testWindowStyleSupportsStandardCloseMinimizeAndZoomButtons() {
        let style = NotePanelController.windowStyleMask

        XCTAssertTrue(style.contains(.closable))
        XCTAssertTrue(style.contains(.miniaturizable))
        XCTAssertTrue(style.contains(.resizable))
    }

    func testCloseButtonRoutesThroughDismissHandler() {
        let controller = NotePanelController(rootView: EmptyView())
        var dismissed = false
        controller.onDismiss = { dismissed = true }

        XCTAssertFalse(controller.windowShouldClose(NSWindow()))
        XCTAssertTrue(dismissed)
    }
}
