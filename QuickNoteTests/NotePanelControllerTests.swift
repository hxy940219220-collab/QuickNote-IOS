import AppKit
import SwiftUI
import XCTest
@testable import QuickNote

@MainActor
final class NotePanelControllerTests: XCTestCase {
    func testPanelFrameCentersWithinVisibleFrameWithNonZeroOrigin() {
        let visibleFrame = NSRect(x: 1_920, y: 48, width: 1_440, height: 900)

        let frame = NotePanelController.panelFrame(in: visibleFrame)

        XCTAssertEqual(frame, NSRect(x: 2_380, y: 238, width: 520, height: 520))
    }

    func testReopeningKeepsUserPosition() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let movedFrame = NSRect(x: 160, y: 120, width: 520, height: 520)

        XCTAssertEqual(
            NotePanelController.presentationFrame(
                current: movedFrame,
                hasBeenPositioned: true,
                in: visibleFrame
            ),
            movedFrame
        )
    }

    func testDrawerExpandsOutsideToTheLeftWithoutShrinkingEditor() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let current = NSRect(x: 460, y: 190, width: 520, height: 520)

        let expanded = NotePanelController.drawerFrame(
            from: current,
            opening: true,
            in: visibleFrame
        )

        XCTAssertEqual(expanded, NSRect(x: 250, y: 190, width: 730, height: 520))
        XCTAssertEqual(expanded.maxX, current.maxX)
    }

    func testWindowLockUsesFloatingLevelOnlyWhileLocked() {
        XCTAssertEqual(NotePanelController.windowLevel(isLocked: false), .normal)
        XCTAssertEqual(NotePanelController.windowLevel(isLocked: true), .floating)
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
