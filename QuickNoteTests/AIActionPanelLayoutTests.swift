import AppKit
import Security
import SwiftData
import SwiftUI
import XCTest
@testable import QuickNote

@MainActor
final class AIActionPanelLayoutTests: XCTestCase {
    func testSelectionDragHitRegionsProtectTextAndAllowHeaderAndWhitespace() {
        let bounds = CGRect(x: 0, y: 0, width: 360, height: 300)
        let summary = CGRect(x: 12, y: 226, width: 336, height: 28)
        let input = CGRect(x: 12, y: 160, width: 336, height: 26)
        let result = CGRect(x: 12, y: 80, width: 336, height: 60)
        let controls = CGRect(x: 294, y: 272, width: 54, height: 22)
        let protected = [summary, input, result, controls]

        XCTAssertTrue(SelectionPanelDragLayout.canDrag(at: CGPoint(x: 42, y: 285), in: bounds, protectedRegions: protected))
        XCTAssertTrue(SelectionPanelDragLayout.canDrag(at: CGPoint(x: 5, y: 145), in: bounds, protectedRegions: protected))
        for rect in protected {
            XCTAssertFalse(SelectionPanelDragLayout.canDrag(at: CGPoint(x: rect.midX, y: rect.midY),
                                                            in: bounds, protectedRegions: protected))
        }
        XCTAssertFalse(SelectionPanelDragLayout.canDrag(at: CGPoint(x: -1, y: 120), in: bounds, protectedRegions: protected))
    }

    func testSelectionDragFrameClampsOnEitherDisplay() throws {
        let primary = CGRect(x: 0, y: 25, width: 1440, height: 825)
        let secondary = CGRect(x: -1080, y: -170, width: 1080, height: 760)
        let size = CGSize(width: 360, height: 260)
        let grab = CGPoint(x: 45, y: 238)
        let first = try XCTUnwrap(SelectionPanelDragLayout.frame(
            pointer: CGPoint(x: 1435, y: 30), grabOffset: grab, size: size, visibleFrame: primary
        ))
        XCTAssertTrue(primary.contains(first))
        XCTAssertEqual(first.maxX, primary.maxX, accuracy: 0.5)
        XCTAssertEqual(first.minY, primary.minY, accuracy: 0.5)

        let second = try XCTUnwrap(SelectionPanelDragLayout.frame(
            pointer: CGPoint(x: -1060, y: 580), grabOffset: grab, size: size, visibleFrame: secondary
        ))
        XCTAssertTrue(secondary.contains(second))
        XCTAssertEqual(second.minX, secondary.minX, accuracy: 0.5)
        XCTAssertEqual(second.maxY, secondary.maxY, accuracy: 0.5)
    }

    func testSelectionPanelRemainsVisibleWhenDraggedAndReanchorsForNewSelection() async throws {
        let fixture = try PanelFixture()
        defer { fixture.cleanUp() }
        let pointer = NSEvent.mouseLocation
        let screen = try XCTUnwrap(NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main)
        let primary = try XCTUnwrap(NSScreen.screens.first)
        let visible = screen.visibleFrame
        let text = "社区菜园将于周六开放，志愿者在入口集合。"
        var anchor = CGRect(x: visible.midX - 125, y: visible.midY + 80, width: 250, height: 22)
        let controller = SelectionActionController(
            session: fixture.session, allNotes: fixture.repository.allNotes, showSettings: {},
            aiStore: fixture.store, readSelection: { _ in
                SelectedTextCapture(text: text, accessibilityBounds: CGRect(
                    x: anchor.minX - primary.frame.minX, y: primary.frame.maxY - anchor.maxY,
                    width: anchor.width, height: anchor.height
                ))
            }
        )
        controller.captureSelection(from: ProcessInfo.processInfo.processIdentifier)
        let panel = try visiblePanel("文字分析")
        let host = try XCTUnwrap(panel.contentView as? NSHostingView<SelectionActionView>)
        defer {
            host.rootView.close()
            panel.contentView = nil
            panel.close()
        }
        panel.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(130))
        let original = panel.frame
        let horizontal: CGFloat = original.midX < visible.midX ? 190 : -190
        let vertical: CGFloat = original.minY - visible.minY > 130 ? -112 : 112
        try drag(panel, from: CGPoint(x: 47, y: original.height - 19),
                 by: CGVector(dx: horizontal, dy: vertical))
        let moved = panel.frame
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(visible.contains(moved))
        XCTAssertGreaterThan(hypot(moved.minX - original.minX, moved.minY - original.minY), 40)
        if let output = try screenshotDirectory() {
            try writeMovedPanel(host, frame: moved, anchor: anchor, text: text,
                                file: output.appending(path: "selection-dragged.png"))
        }

        anchor.origin.y += 96
        controller.captureSelection(from: ProcessInfo.processInfo.processIdentifier)
        let height = SelectionPanelLayout.contentHeight(
            source: text, expanded: false, result: "", isLoading: false, notice: "", showsQuestion: true
        )
        let expected = try XCTUnwrap(SelectionPanelLayout.frame(
            selectionRect: anchor, pointer: NSEvent.mouseLocation, screen: visible, contentHeight: height
        ))
        XCTAssertNotEqual(panel.frame.origin, moved.origin)
        XCTAssertEqual(panel.frame.minX, expected.minX, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, expected.minY, accuracy: 1)
    }

    func testScreenshotContentHeightsForIdleGeneratingAndResult() {
        let previewHeight: CGFloat = 170
        let available: CGFloat = 580
        let idle = ScreenshotPanelLayout.contentHeight(previewHeight: previewHeight, phase: .idle, availableHeight: available)
        let generating = ScreenshotPanelLayout.contentHeight(previewHeight: previewHeight, phase: .running, availableHeight: available)
        let result = ScreenshotPanelLayout.contentHeight(
            previewHeight: previewHeight, phase: .result, resultHeight: 240, availableHeight: available
        )
        let overflowing = ScreenshotPanelLayout.contentHeight(
            previewHeight: previewHeight, phase: .result, resultHeight: 20_000, availableHeight: available
        )
        XCTAssertEqual(idle, 268, "待输入状态只预留预览、控件和边距")
        XCTAssertEqual(generating, 328)
        XCTAssertEqual(result, 549)
        XCTAssertEqual(overflowing, available)
        XCTAssertEqual(ScreenshotPanelLayout.contentHeight(
            previewHeight: previewHeight, phase: .result, resultHeight: 240, availableHeight: 760, manualHeight: 700
        ), 700, "用户尺寸可超过自动高度上限")
    }

    func testScreenshotFrameGrowsDownwardAndClampsToTheScreen() {
        let visible = CGRect(x: -800, y: 25, width: 800, height: 600)
        let idle = CGRect(x: -756, y: 390, width: 710, height: 195)
        let result = ScreenshotPanelLayout.frame(
            current: idle, contentHeight: 350, titlebarHeight: 30, visibleFrame: visible
        )
        XCTAssertEqual(result.maxY, idle.maxY, accuracy: 0.5)
        XCTAssertEqual(result.height, 380, accuracy: 0.5)
        XCTAssertLessThan(result.minY, idle.minY)
        XCTAssertTrue(visible.contains(result))

        let overflowing = ScreenshotPanelLayout.frame(
            current: idle, contentHeight: 1000, titlebarHeight: 30, visibleFrame: visible
        )
        XCTAssertTrue(visible.contains(overflowing))
        XCTAssertLessThanOrEqual(overflowing.height, visible.height)
    }

    func testScreenshotWindowExpandsFromTightIdleToGeneratingAndResult() async throws {
        let fixture = try PanelFixture()
        defer { fixture.cleanUp() }
        let (stream, continuation) = AsyncThrowingStream<AIStreamEvent, Error>.makeStream()
        defer { continuation.finish() }
        let controller = ScreenshotActionController(
            session: fixture.session, allNotes: fixture.repository.allNotes, aiStore: fixture.store,
            showSettings: {}, streamRespond: { _, _ in stream }, confirmSending: { _ in true }
        )
        controller.present(syntheticImage(), pasteboard: fixture.pasteboard)
        let panel = try visiblePanel("图片识别")
        defer { panel.close() }
        panel.appearance = NSAppearance(named: .aqua)
        let host = try XCTUnwrap(panel.contentView as? NSHostingView<ScreenshotActionView>)
        let state = host.rootView.state
        try await Task.sleep(for: .milliseconds(180))
        let idle = panel.frame
        XCTAssertEqual(state.phase, .idle)
        XCTAssertLessThan(idle.height, 390, "使用短横图时待输入窗口不应保留一块结果区")
        let output = try screenshotDirectory()
        if let output {
            try writeWindow(panel, file: output.appending(path: "image-idle.png"))
        }

        host.rootView.analyze()
        continuation.yield(.started(providerName: "Codex（ChatGPT 账号）"))
        try await waitFor { state.phase == .running && panel.frame.height > idle.height }
        let generating = panel.frame
        XCTAssertEqual(generating.maxY, idle.maxY, accuracy: 1)
        let text = "**集合时间**为周六上午 09:30，**地点**在社区菜园入口。请带水瓶和园艺手套。志愿者会在入口处等候，到场后先签到，再一同入园。"
        continuation.yield(.delta(text))
        continuation.yield(.completed(.init(text: text, providerName: "Codex（ChatGPT 账号）")))
        continuation.finish()
        try await waitFor { state.phase == .result && panel.frame.height > generating.height }
        let result = panel.frame
        XCTAssertEqual(result.maxY, idle.maxY, accuracy: 1)
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(result) })
        if let output {
            try await Task.sleep(for: .milliseconds(90))
            try writeWindow(panel, file: output.appending(path: "image-result.png"))
        }
    }

    func testScreenshotResultsKeepTheUserResizedWindowSize() async throws {
        let fixture = try PanelFixture()
        defer { fixture.cleanUp() }
        let (stream, continuation) = AsyncThrowingStream<AIStreamEvent, Error>.makeStream()
        defer { continuation.finish() }
        let controller = ScreenshotActionController(
            session: fixture.session, allNotes: fixture.repository.allNotes, aiStore: fixture.store,
            showSettings: {}, streamRespond: { _, _ in stream }, confirmSending: { _ in true }
        )
        controller.present(syntheticImage(), pasteboard: fixture.pasteboard)
        let panel = try visiblePanel("图片识别")
        defer { panel.close() }
        let view = try XCTUnwrap(panel.contentView as? NSHostingView<ScreenshotActionView>).rootView

        controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: panel))
        let requested = CGSize(width: panel.frame.width - 30, height: panel.frame.height + 54)
        panel.setContentSize(requested)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
        let manualSize = panel.frame.size
        XCTAssertEqual(manualSize.width, requested.width, accuracy: 1)
        view.analyze()
        continuation.yield(.started(providerName: "合成模型"))
        try await waitFor { view.state.phase == .running }
        XCTAssertEqual(panel.frame.size, manualSize)

        let text = String(repeating: "示例段落，用来填满结果区。\n\n", count: 80)
        continuation.yield(.completed(.init(text: text, providerName: "合成模型")))
        continuation.finish()
        try await waitFor { view.state.phase == .result }
        XCTAssertEqual(panel.frame.size, manualSize)
    }

    private func visiblePanel(_ title: String) throws -> NSPanel {
        try XCTUnwrap(NSApp.windows.first { $0.title == title && $0.isVisible } as? NSPanel)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "等待窗口或生成状态更新超时")
    }

    private func drag(_ panel: NSPanel, from localPoint: CGPoint, by movement: CGVector) throws {
        let press = panel.convertPoint(toScreen: localPoint)
        let destination = CGPoint(x: press.x + movement.dx, y: press.y + movement.dy)
        for (kind, point) in [(NSEvent.EventType.leftMouseDown, press), (.leftMouseDragged, destination),
                              (.leftMouseUp, destination)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: kind, location: panel.convertPoint(fromScreen: point), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: kind == .leftMouseUp ? 0 : 1
            ))
            panel.sendEvent(event)
        }
    }

    private func screenshotDirectory() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["QUICKNOTE_PANEL_FOLLOWUP_SCREENSHOTS"] else { return nil }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func syntheticImage() -> NSImage {
        NSImage(size: CGSize(width: 620, height: 168), flipped: true) { rect in
            let green = NSColor(srgbRed: 0.12, green: 0.35, blue: 0.24, alpha: 1)
            NSColor(srgbRed: 0.93, green: 0.97, blue: 0.94, alpha: 1).setFill()
            rect.fill()
            ("社区菜园开放日" as NSString).draw(at: CGPoint(x: 24, y: 23), withAttributes: [
                .font: NSFont.systemFont(ofSize: 32, weight: .bold), .foregroundColor: green
            ])
            ("周六 09:30  ·  菜园入口" as NSString).draw(at: CGPoint(x: 26, y: 75), withAttributes: [
                .font: NSFont.systemFont(ofSize: 23, weight: .medium), .foregroundColor: green
            ])
            ("请带水瓶、园艺手套，并在入口签到。" as NSString).draw(at: CGPoint(x: 26, y: 119), withAttributes: [
                .font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.darkGray
            ])
            return true
        }
    }

    private func bitmap(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func writeWindow(_ panel: NSPanel, file: URL) throws {
        let view = try XCTUnwrap(panel.contentView?.superview ?? panel.contentView)
        try XCTUnwrap(bitmap(view).representation(using: .png, properties: [:])).write(to: file)
    }

    private func writeMovedPanel(_ view: NSView, frame: CGRect, anchor: CGRect, text: String, file: URL) throws {
        let panel = try bitmap(view)
        let area = frame.union(anchor).insetBy(dx: -28, dy: -22).integral
        let scene = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(area.width) * 2, pixelsHigh: Int(area.height) * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: scene))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1).setFill()
        CGRect(origin: .zero, size: area.size).fill()
        let source = anchor.offsetBy(dx: -area.minX, dy: -area.minY)
        NSColor(srgbRed: 0.81, green: 0.89, blue: 1, alpha: 1).setFill()
        NSBezierPath(roundedRect: source, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(in: source.insetBy(dx: 6, dy: 2), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.darkGray
        ])
        let panelArea = frame.offsetBy(dx: -area.minX, dy: -area.minY)
        NSBezierPath(roundedRect: panelArea, xRadius: 14, yRadius: 14).addClip()
        panel.draw(in: panelArea)
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(scene.representation(using: .png, properties: [:])).write(to: file)
    }
}

@MainActor
private struct PanelFixture {
    let defaultsName = "QuickNote.PanelFollowup.\(UUID())"
    let folder = FileManager.default.temporaryDirectory.appending(path: "PanelFollowup-\(UUID())")
    let defaults: UserDefaults
    let pasteboard: NSPasteboard
    let store: AIConfigurationStore
    let repository: NoteRepository
    let session: NoteSession
    private let container: ModelContainer

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        pasteboard = NSPasteboard(name: .init(defaultsName))
        store = AIConfigurationStore(defaults: defaults,
            keychain: APIKeyKeychain(copyMatching: { _, _ in errSecItemNotFound }))
        container = try ModelContainer(for: NoteRecord.self, NoteFolder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        repository = NoteRepository(context: container.mainContext)
        session = NoteSession(repository: repository, documents: NoteDocumentStore(root: folder))
    }

    func cleanUp() {
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: folder)
    }
}
