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

    func testWindowLockUsesElevatedSystemLevelOnlyWhileLocked() {
        XCTAssertEqual(NotePanelController.windowLevel(isLocked: false), .normal)
        XCTAssertEqual(NotePanelController.windowLevel(isLocked: true), .statusBar)
    }

    func testRailFrameCentersFittedContentAlongScreenEdge() {
        let visibleFrame = NSRect(x: 1_920, y: 48, width: 1_440, height: 900)
        let railFrame = EdgeRailController.railFrame(
            in: visibleFrame,
            contentSize: NSSize(width: 18, height: 31)
        )

        XCTAssertEqual(railFrame, NSRect(x: 1_924, y: 482.5, width: 18, height: 31))
        XCTAssertEqual(railFrame.midY, visibleFrame.midY)
    }

    func testEdgeRailCollapsesAndCapsExpandedItemsAtSix() {
        XCTAssertEqual(EdgeRailView.collapsedSize, NSSize(width: 8, height: 40))
        XCTAssertEqual(
            EdgeRailView.expandedSize(noteCount: 9),
            NSSize(width: 18, height: 124)
        )
    }

    func testEdgeRailPreviewFrameStaysBesideRailAndInsideScreen() {
        let frame = EdgeRailController.previewFrame(
            beside: NSRect(x: 4, y: 420, width: 18, height: 60),
            pointerY: 899,
            contentSize: NSSize(width: 120, height: 26),
            in: NSRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertEqual(frame, NSRect(x: 30, y: 874, width: 120, height: 26))
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
