import AppKit
import SwiftUI
import Carbon
import Security
import XCTest
@testable import QuickNote

private final class UndoableTestTextView: NSTextView {
    private let testUndoManager = UndoManager()

    override var undoManager: UndoManager? { testUndoManager }
}

final class AppShellTests: XCTestCase {
    @MainActor
    func testNoteNavigationMatchesGroupsAndStaysStableAcrossAutosave() {
        let folder = NoteFolder(name: "项目")
        let a = NoteRecord(), b = NoteRecord(), c = NoteRecord(), d = NoteRecord()
        c.folderID = folder.id
        var order = NoteNavigationOrder()
        order.refresh(notes: [a, b, c], folders: [folder], reset: true)
        XCTAssertEqual(order.ids, [c.id, a.id, b.id])
        XCTAssertEqual(order.neighbor(of: a.id, offset: -1), c.id)
        XCTAssertEqual(order.neighbor(of: a.id, offset: 1), b.id)
        XCTAssertNil(order.neighbor(of: c.id, offset: -1))
        XCTAssertNil(order.neighbor(of: b.id, offset: 1))
        order.refresh(notes: [b, a, c], folders: [folder], reset: false)
        XCTAssertEqual(order.ids, [c.id, a.id, b.id], "保存更新排序，不能让往返导航跳动")
        b.deletedAt = .now
        order.refresh(notes: [d, a, c, b], folders: [folder], reset: false)
        XCTAssertEqual(order.ids, [c.id, a.id, d.id])
        XCTAssertNil(order.neighbor(of: b.id, offset: 1))
        order.refresh(notes: [d, a, c], folders: [folder], reset: true)
        XCTAssertEqual(order.ids, [c.id, d.id, a.id])
        order.refresh(notes: [], folders: [], reset: false)
        XCTAssertNil(order.neighbor(of: a.id, offset: 1))
    }

    @MainActor
    func testNavigationButtonsAcceptFirstClickAcrossEntireTarget() async throws {
        var offsets: [Int] = []
        let view = NSHostingView(rootView: NoteNavigationControls(previousTitle: "上一条", nextTitle: "下一条", navigate: { offsets.append($0) }))
        view.frame = NSRect(x: 0, y: 0, width: 68, height: 30)
        let window = NSPanel(contentRect: NSRect(x: 300, y: 300, width: 68, height: 30),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        for point in [NSPoint(x: 2, y: 2), NSPoint(x: 33, y: 15), NSPoint(x: 35, y: 15), NSPoint(x: 66, y: 28)] {
            let hit = try XCTUnwrap(view.hitTest(point))
            XCTAssertTrue(hit.acceptsFirstMouse(for: nil), "窗口未激活时也应一次点击生效：\(type(of: hit))")
            XCTAssertFalse(hit.mouseDownCanMoveWindow, "按钮区域不能被当作拖动窗口")
            let button = try XCTUnwrap(hit as? NSButton, "整个命中区域由按钮处理")
            button.performClick(nil)
        }
        XCTAssertEqual(offsets, [-1, -1, 1, 1])
        view.rootView = NoteNavigationControls(previousTitle: nil, nextTitle: "下一条", navigate: { offsets.append($0) })
        view.layoutSubtreeIfNeeded()
        let first = try XCTUnwrap(view.hitTest(NSPoint(x: 2, y: 2)) as? NSButton)
        XCTAssertFalse(first.isEnabled, "到达首条仍然禁止继续向上切换")
    }

    @MainActor
    func testNoteNavigationControlsStayCompactAndRender() async throws {
        let view = NSHostingView(rootView: NoteNavigationControls(previousTitle: "会议纪要", nextTitle: "项目素材", navigate: { _ in }))
        view.frame = NSRect(x: 0, y: 0, width: 68, height: 30)
        let window = NSPanel(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(view.fittingSize.width, 68)
        XCTAssertLessThanOrEqual(view.fittingSize.height, 30)
    }

    @MainActor
    func testPetTouchDialogueStaysVisibleBesideHoverActions() throws {
        let name = "QuickNote-Pet-Dialogue-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        pet.setSoundEnabled(false)
        pet.setEnabled(true)
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        pet.move(to: NSPoint(x: screen.midX, y: screen.midY), save: false)
        let pointer = NSPoint(x: pet.petPanel.frame.midX, y: pet.petPanel.frame.midY)
        pet.updateQuickActions(at: pointer)
        XCTAssertTrue(try XCTUnwrap(pet.petPanel.contentView).accessibilityPerformPress())
        XCTAssertEqual(pet.message, "嘿，我在呢")
        let bubble = try XCTUnwrap(NSApp.windows.first { window in
            window.contentView?.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "嘿，我在呢" } == true
        })
        XCTAssertTrue(bubble.isVisible, "靠近小鸟后点击，不能让对白被快捷入口隐藏")
        XCTAssertFalse(bubble.frame.intersects(pet.quickActionsPanel.frame))
        pet.updateQuickActions(at: pointer)
        XCTAssertTrue(bubble.isVisible)
    }

    @MainActor
    func testPetStatusRemainsVisibleWhenVoiceDisablesFileDrops() throws {
        let name = "QuickNote-Pet-Status-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        pet.setSoundEnabled(false)
        pet.canReceiveDrop = { false } // Recording blocks a second input, not its status bubble.
        pet.quickActionsSuppressed = true
        pet.setEnabled(true)
        let id = pet.begin(message: "正在录音", detail: "本机转写，不上传录音")
        let bubble = try XCTUnwrap(NSApp.windows.first { window in
            window.contentView?.subviews.compactMap { $0 as? NSTextField }
                .contains(where: { $0.stringValue == "正在录音" }) == true
        })
        XCTAssertTrue(bubble.isVisible)
        XCTAssertFalse(bubble.canBecomeKey)
        pet.finish(id, message: "录音已停止", clip: "attention")
        XCTAssertTrue(bubble.isVisible)
        XCTAssertEqual(pet.message, "录音已停止")
        pet.received()
        XCTAssertTrue(bubble.isVisible)
        XCTAssertEqual(pet.message, "收好啦")
        pet.setEnabled(false)
        XCTAssertFalse(bubble.isVisible)
    }

    @MainActor
    func testPetArcKeepsSmallFixedGapsAtEveryScale() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        for side: CGFloat in [50, 100, 150] {
            let pet = NSRect(x: 600, y: 300, width: side, height: side)
            let buttons = DesktopPetController.quickActionFrames(near: pet, in: screen)
            let bounds = DesktopPetController.quickActionsFrame(near: pet, in: screen)
            XCTAssertLessThanOrEqual(bounds.height, 134, "不能随桌宠放大而拉开按钮间距")
            XCTAssertLessThanOrEqual(buttons[1].midX - pet.midX, 80, "应贴近小鸟而非透明画布外侧")
            for index in 0..<2 {
                let distance = hypot(buttons[index].midX - buttons[index + 1].midX,
                                     buttons[index].midY - buttons[index + 1].midY)
                XCTAssertGreaterThanOrEqual(distance, 40)
                XCTAssertLessThanOrEqual(distance, 48)
            }
        }
    }

    @MainActor
    func testPetActionsFormAnArcAndFocusWithoutMovingHitTargets() throws {
        let name = "QuickNote-Arc-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        pet.setEnabled(true)
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        pet.move(to: NSPoint(x: screen.midX, y: screen.midY), save: false)
        pet.updateQuickActions(at: NSPoint(x: pet.petPanel.frame.midX, y: pet.petPanel.frame.midY))
        let buttons = try XCTUnwrap(pet.quickActionsPanel.contentView).subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 3)
        XCTAssertGreaterThan(buttons[0].frame.midY, buttons[1].frame.midY)
        XCTAssertGreaterThan(buttons[1].frame.midY, buttons[2].frame.midY)
        XCTAssertGreaterThan(buttons[1].frame.midX, buttons[0].frame.midX)
        let frames = buttons.map(\.frame)
        for index in buttons.indices {
            let frame = buttons[index].frame.offsetBy(dx: pet.quickActionsPanel.frame.minX, dy: pet.quickActionsPanel.frame.minY)
            pet.updateQuickActions(at: NSPoint(x: frame.midX, y: frame.midY))
            XCTAssertFalse(pet.quickActionsPanel.ignoresMouseEvents)
            XCTAssertEqual(buttons.map(\.frame), frames)
            XCTAssertGreaterThan(buttons[index].layer?.transform.m11 ?? 0, 1)
            XCTAssertEqual(buttons[index].layer?.opacity ?? 0, 1)
            for other in buttons.indices where other != index {
                XCTAssertLessThan(buttons[other].layer?.opacity ?? 1, 0.6)
            }
        }
        pet.updateQuickActions(at: NSPoint(x: pet.petPanel.frame.midX, y: pet.petPanel.frame.midY))
        XCTAssertTrue(pet.quickActionsPanel.ignoresMouseEvents, "透明画布不能挡住小鸟的点击和拖动")
        XCTAssertTrue(buttons.allSatisfy { $0.layer?.opacity == 1 })
    }

    @MainActor
    func testDesktopPetDoesNotExposePermanentActionButtons() throws {
        let name = "QuickNote-Hover-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        XCTAssertTrue(try XCTUnwrap(pet.petPanel.contentView).subviews.compactMap { $0 as? NSButton }.isEmpty)
    }

    @MainActor
    func testDesktopPetHoverActionsStayOnScreenWithoutMovingBird() {
        for screen in [NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: -1280, y: -100, width: 1280, height: 800)] {
            for side: CGFloat in [50, 100, 150] {
                for x in [screen.minX, screen.midX, screen.maxX - side] {
                    for y in [screen.minY, screen.maxY - side] {
                        let pet = NSRect(x: x, y: y, width: side, height: side)
                        let actions = DesktopPetController.quickActionsFrame(near: pet, in: screen)
                        XCTAssertTrue(screen.contains(actions))
                        let buttons = DesktopPetController.quickActionFrames(near: pet, in: screen)
                        for (index, button) in buttons.enumerated() {
                            XCTAssertTrue(actions.contains(button.insetBy(dx: -3, dy: -3)), "悬停放大不能被裁切")
                            for other in buttons.dropFirst(index + 1) { XCTAssertFalse(button.intersects(other)) }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func testDesktopPetHoverBridgeAndAnimationReversalDoNotFlicker() async throws {
        let name = "QuickNote-Hover-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        pet.setEnabled(true)
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        pet.move(to: NSPoint(x: screen.minX + 100, y: screen.minY + 100), save: false)
        let original = pet.petPanel.frame
        let birdPoint = NSPoint(x: original.midX, y: original.midY)
        pet.updateQuickActions(at: NSPoint(x: original.minX - 5, y: original.midY))
        XCTAssertTrue(pet.quickActionsExpanded)
        let actions = pet.quickActionsPanel.frame
        try await Task.sleep(for: .milliseconds(240))
        let quickView = try XCTUnwrap(pet.quickActionsPanel.contentView)
        let bitmap = try XCTUnwrap(quickView.bitmapImageRepForCachingDisplay(in: quickView.bounds))
        quickView.cacheDisplay(in: quickView.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/quicknote-hover-actions.png"))
        for x in stride(from: original.midX, through: actions.maxX - 12, by: 4) {
            pet.updateQuickActions(at: NSPoint(x: x, y: original.midY))
            XCTAssertTrue(pet.quickActionsExpanded)
            XCTAssertEqual(pet.petPanel.frame, original)
            XCTAssertEqual(pet.quickActionsPanel.frame, actions)
        }
        let outside = NSPoint(x: actions.maxX + 70, y: actions.maxY + 70)
        pet.updateQuickActions(at: outside)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(pet.quickActionsExpanded, "离开缓冲期内不能立即消失")
        pet.updateQuickActions(at: NSPoint(x: actions.midX, y: actions.midY))
        try await Task.sleep(for: .milliseconds(360))
        XCTAssertTrue(pet.quickActionsExpanded, "移到按钮后，之前的收起任务必须失效")
        pet.updateQuickActions(at: outside)
        try await Task.sleep(for: .milliseconds(350))
        pet.updateQuickActions(at: birdPoint)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(pet.quickActionsPanel.isVisible, "退出动画被反转后，旧回调不能隐藏新展开的按钮")
        pet.updateQuickActions(at: outside)
        try await Task.sleep(for: .milliseconds(560))
        XCTAssertFalse(pet.quickActionsPanel.isVisible)
        XCTAssertTrue(pet.quickActionsPanel.ignoresMouseEvents)
        pet.updateQuickActions(at: birdPoint)
        pet.setEnabled(false)
        XCTAssertFalse(pet.quickActionsPanel.isVisible)
        XCTAssertFalse(pet.quickActionsExpanded)
    }

    @MainActor
    func testDesktopPetHoverButtonsDispatchOnlyTheirExistingActions() throws {
        let name = "QuickNote-Hover-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        pet.setEnabled(true)
        let root = try XCTUnwrap(pet.quickActionsPanel.contentView)
        let buttons = root.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.map { $0.accessibilityLabel() }, ["语音便签", "打开便签", "AI 设置"])
        var invoked: [DesktopPetController.Action] = []
        pet.onAction = { action, _ in invoked.append(action) }
        for button in buttons {
            let bird = pet.petPanel.frame
            pet.updateQuickActions(at: NSPoint(x: bird.minX - 300, y: bird.minY - 300))
            pet.updateQuickActions(at: NSPoint(x: bird.midX, y: bird.midY))
            XCTAssertTrue(button.isEnabled)
            button.performClick(nil)
            XCTAssertFalse(pet.quickActionsExpanded)
            XCTAssertTrue(pet.quickActionsPanel.ignoresMouseEvents)
            pet.updateQuickActions(at: NSPoint(x: bird.midX, y: bird.midY))
            XCTAssertFalse(pet.quickActionsExpanded, "选择功能后，不在原地重新弹出")
        }
        XCTAssertEqual(invoked, [.voice, .openNote, .settings])
    }

    @MainActor
    func testDesktopPetOffersDropAndSoundControls() throws {
        let name = "QuickNote-Pet-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        let view = try XCTUnwrap(pet.petPanel.contentView)
        for type in [NSPasteboard.PasteboardType.fileURL, .png, .tiff, .string, .URL] {
            XCTAssertTrue(view.registeredDraggedTypes.contains(type))
        }
        XCTAssertNotNil(pet.makeMenu().item(withTitle: "互动音效"))
    }

    @MainActor
    func testDesktopPetDoesNotRequireAnOpenNoteWindow() throws {
        let name = "QuickNote-Pet-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        pet.setEnabled(true)
        pet.setVisible(true)
        XCTAssertTrue(pet.isPresented, "桌宠不能依赖打开的便签窗口")
        pet.setEnabled(false)
        XCTAssertFalse(pet.isPresented)
    }

    @MainActor
    func testDesktopPetTracksConcurrentTasksWithoutStaleCompletion() {
        var activity = DesktopPetActivity()
        let first = UUID(), second = UUID()
        activity.begin(first, message: "正在思考…", detail: "文字分析 · 便签 A")
        activity.begin(second, message: "正在排版…", detail: "便签 B")
        XCTAssertEqual(activity.current?.detail, "便签 B")
        XCTAssertTrue(activity.finish(first))
        XCTAssertEqual(activity.current?.detail, "便签 B")
        XCTAssertFalse(activity.finish(first))
        XCTAssertTrue(activity.finish(second))
        XCTAssertNil(activity.current)
        activity.begin(first, message: "正在思考…", detail: "便签 A")
        activity.begin(second, message: "正在排版…", detail: "便签 B")
        activity.finish(second)
        XCTAssertEqual(activity.current?.detail, "便签 A")
    }

    @MainActor
    func testDesktopPetLayoutClampsOnMultipleAndDisconnectedScreens() {
        let screen = NSRect(x: -1000, y: 20, width: 1000, height: 700)
        let other = NSRect(x: 0, y: 0, width: 1000, height: 700)
        for origin in [NSPoint(x: -1300, y: -100), NSPoint(x: 4000, y: 1400)] {
            let pet = DesktopPetController.clamped(NSRect(origin: origin, size: NSSize(width: 80, height: 80)), in: screen)
            XCTAssertTrue(screen.contains(pet))
            XCTAssertTrue(screen.contains(DesktopPetController.bubbleFrame(near: pet, in: screen)))
        }
        let displaced = NSRect(x: 4000, y: 100, width: 80, height: 80)
        XCTAssertEqual(DesktopPetController.closestScreen(to: displaced, screens: [screen, other]), other)
        XCTAssertEqual(DesktopPetController.closestScreen(to: displaced, screens: [screen]), screen)
        XCTAssertLessThanOrEqual(Double(DesktopPetController.idlePauseSeconds.upperBound), 1.5)
    }

    @MainActor
    func testDesktopPetResourcesAndDisableStopPlayback() throws {
        let name = "QuickNote-Pet-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        XCTAssertFalse(pet.isEnabled)
        XCTAssertEqual(pet.clips.count, 8)
        for clip in pet.clips {
            XCTAssertEqual(clip.frameDurationsMs.count, 9)
            for direction in ["left", "right"] {
                for frame in 0..<9 { XCTAssertNotNil(pet.image(clip: clip.id, direction: direction, frame: frame)) }
            }
        }
        let window = NSPanel(contentRect: NSRect(x: 150, y: 150, width: 520, height: 520),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        pet.setEnabled(true)
        pet.setVisible(true)
        let id = pet.begin(message: "正在思考…", detail: "测试便签")
        XCTAssertTrue(pet.isPresented)
        XCTAssertNil(pet.petPanel.parent)
        XCTAssertTrue(pet.petPanel.isVisible)
        XCTAssertEqual(pet.petPanel.level, .statusBar)
        XCTAssertFalse(pet.petPanel.canBecomeKey)
        XCTAssertFalse(pet.petPanel.canHide)
        XCTAssertFalse(pet.petPanel.ignoresMouseEvents)
        XCTAssertTrue(pet.petPanel.collectionBehavior.contains(.canJoinAllSpaces))
        window.orderOut(nil)
        XCTAssertTrue(pet.petPanel.isVisible)
        XCTAssertEqual(pet.message, "正在思考…")
        pet.finish(id, message: "已停止", clip: "attention")
        XCTAssertEqual(pet.message, "已停止")
        pet.setVisible(false)
        XCTAssertFalse(pet.isPresented)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        XCTAssertFalse(pet.hasScheduledPlayback)
        pet.setEnabled(false)
        XCTAssertFalse(defaults.bool(forKey: DesktopPetController.enabledKey))
        pet.stop()
    }

    @MainActor
    func testDesktopPetMenuDispatchHideAndPositionMemory() async throws {
        let name = "QuickNote-Pet-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        pet.setEnabled(true)
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        pet.move(to: NSPoint(x: visible.minX + 100, y: visible.minY + 100), save: true)
        let saved = pet.petPanel.frame.origin
        pet.move(to: NSPoint(x: CGFloat.nan, y: 5), save: true)
        XCTAssertEqual(pet.petPanel.frame.origin, saved)
        var performed: [DesktopPetController.Action] = []
        pet.onAction = { action, _ in performed.append(action) }
        let menu = pet.makeMenu()
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["打开便签", "新建便签", "截图识别…", "分析选中文字…", "AI 设置…", "语音便签…", "桌宠大小", "互动音效", "隐藏桌宠"])
        for index in 0..<DesktopPetController.Action.allCases.count { menu.performActionForItem(at: index) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(performed, DesktopPetController.Action.allCases)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "隐藏桌宠"))
        XCTAssertFalse(pet.isPresented)
        XCTAssertFalse(pet.hasScheduledPlayback)
        pet.setEnabled(true)
        XCTAssertEqual(pet.petPanel.frame.origin, saved)
        pet.stop()
        let relaunched = DesktopPetController(defaults: defaults)
        defer { relaunched.stop() }
        relaunched.start()
        XCTAssertTrue(relaunched.isPresented)
        XCTAssertEqual(relaunched.petPanel.frame.origin, saved)
    }

    @MainActor
    func testDesktopPetSizeMenuResizesCanvasAndPersists() throws {
        let name = "QuickNote-Pet-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        XCTAssertEqual(pet.petPanel.frame.width, 100)
        pet.setEnabled(true)
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        pet.move(to: NSPoint(x: screen.maxX - 100, y: screen.maxY - 100), save: true)
        let sizes = try XCTUnwrap(pet.makeMenu().item(withTitle: "桌宠大小")?.submenu)
        XCTAssertEqual(sizes.items.map(\.tag), [50, 100, 150])
        for (index, points) in [(0, 50.0), (1, 100.0), (2, 150.0)] {
            sizes.performActionForItem(at: index)
            XCTAssertEqual(pet.petPanel.frame.width, points)
            XCTAssertEqual(pet.petPanel.contentView?.frame.size, NSSize(width: points, height: points))
            XCTAssertTrue(screen.contains(pet.petPanel.frame))
            let refreshed = try XCTUnwrap(pet.makeMenu().item(withTitle: "桌宠大小")?.submenu)
            XCTAssertEqual(refreshed.items.filter { $0.state == .on }.map(\.tag), [Int(points)])
        }
        let restored = DesktopPetController(defaults: defaults)
        defer { restored.stop() }
        restored.start()
        XCTAssertEqual(restored.petPanel.frame.width, 150)
        XCTAssertEqual(restored.petPanel.frame.origin, pet.petPanel.frame.origin)
        restored.setScale(10)
        XCTAssertEqual(restored.petPanel.frame.width, 150)
        restored.setScale(-1)
        XCTAssertEqual(restored.petPanel.frame.width, 50)
        restored.setScale(.nan)
        restored.setScale(.infinity)
        XCTAssertEqual(restored.petPanel.frame.width, 50)
        defaults.set(99, forKey: DesktopPetController.scaleKey)
        let oversized = DesktopPetController(defaults: defaults)
        defer { oversized.stop() }
        XCTAssertEqual(oversized.petPanel.frame.width, 150, "恢复损坏的偏好也不能突破上限")
    }

    @MainActor
    func testDesktopPetIdleActuallyChangesFramesAfterMenuCloses() async throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let name = "QuickNote-Pet-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        pet.setEnabled(true)
        let view = try XCTUnwrap(pet.petPanel.contentView as? NSImageView)
        let menu = pet.makeMenu()
        pet.menuWillOpen(menu)
        XCTAssertFalse(pet.hasScheduledPlayback)
        pet.menuDidClose(menu)
        let neutral = try XCTUnwrap(view.image?.tiffRepresentation)
        let deadline = ContinuousClock.now + .seconds(2)
        var changed = false
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(40))
            if let frame = view.image?.tiffRepresentation, frame != neutral {
                changed = true
                break
            }
        }
        XCTAssertTrue(changed, "结束菜单操作后应在两秒内出现可见帧变化")
        pet.setEnabled(false)
        XCTAssertFalse(pet.hasScheduledPlayback)
    }

    @MainActor
    func testDesktopPetTouchSoundAndBusyFeedback() async throws {
        let name = "QuickNote-Pet-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        pet.setSoundEnabled(false)
        pet.setEnabled(true)
        XCTAssertTrue(try XCTUnwrap(pet.petPanel.contentView).accessibilityPerformPress())
        XCTAssertEqual(pet.message, "嘿，我在呢")
        pet.reactToTouch()
        XCTAssertEqual(pet.message, "嘿，我在呢", "连续点击不能不停重启反馈")
        let task = pet.begin(message: "正在思考…", detail: "测试便签")
        try await Task.sleep(for: .milliseconds(1050))
        pet.reactToTouch()
        XCTAssertEqual(pet.message, "正在思考…", "摸摸头不覆盖真实任务状态")
        pet.finish(task)
        let restored = DesktopPetController(defaults: defaults)
        defer { restored.stop() }
        XCTAssertFalse(restored.soundEnabled)
        XCTAssertEqual(restored.makeMenu().item(withTitle: "互动音效")?.state, .off)
        let sound = try XCTUnwrap(NSSound(data: DesktopPetController.chirpData()))
        XCTAssertEqual(sound.duration, 0.4, accuracy: 0.02)
    }

    @MainActor
    func testDesktopPetDropDecodesTextImagesAndFilesWithoutChangingBytes() throws {
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("  保存这段文字\n第二行  ", forType: .string)
        let text = try DesktopPetDrop.read(from: board)
        XCTAssertEqual(text.content.string, "  保存这段文字\n第二行  ")
        XCTAssertEqual(text.content.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, EditorTextStyle.body.font)
        XCTAssertNil(text.image)
        board.clearContents()
        board.setString("https://example.com/image.png", forType: .URL)
        let link = try DesktopPetDrop.read(from: board)
        XCTAssertNil(link.image, "网页地址不自动下载")
        XCTAssertEqual(link.content.attribute(.link, at: 0, effectiveRange: nil) as? URL, URL(string: "https://example.com/image.png"))

        let name = "QuickNote-Pet-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        let data = try XCTUnwrap(pet.image(clip: "greeting", direction: "right", frame: 0)?.tiffRepresentation)
        board.clearContents()
        board.setData(data, forType: .tiff)
        let image = try DesktopPetDrop.read(from: board)
        XCTAssertNotNil(image.image)
        let attachment = try XCTUnwrap(image.content.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertEqual(attachment.fileWrapper?.regularFileContents, data)
        XCTAssertEqual(image.content.string, "\u{fffc}\n", "图片独占段落")
        board.clearContents()
        let textItem = NSPasteboardItem(), imageItem = NSPasteboardItem()
        textItem.setString("before", forType: .string)
        imageItem.setData(data, forType: .tiff)
        board.writeObjects([textItem, imageItem])
        let mixed = try DesktopPetDrop.read(from: board)
        XCTAssertEqual(mixed.content.string, "before\n\u{fffc}\n")
        XCTAssertNil(mixed.image, "多项内容不能误当成一张图送去识别")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pet-drop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.txt")
        let bytes = Data("original file bytes".utf8)
        try bytes.write(to: file)
        board.clearContents()
        board.writeObjects([file as NSURL])
        let payload = try DesktopPetDrop.read(from: board)
        let fileAttachment = try XCTUnwrap(payload.content.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertEqual(fileAttachment.fileWrapper?.regularFileContents, bytes)
        XCTAssertEqual(fileAttachment.fileWrapper?.preferredFilename, "sample.txt")
        board.clearContents()
        board.writeObjects([root as NSURL])
        XCTAssertThrowsError(try DesktopPetDrop.read(from: board))
        let largeFile = root.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: largeFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: largeFile)
        try handle.truncate(atOffset: UInt64(DesktopPetDrop.maximumBytes + 1))
        try handle.close()
        board.clearContents()
        board.writeObjects([largeFile as NSURL])
        XCTAssertThrowsError(try DesktopPetDrop.read(from: board))
        board.clearContents()
        board.setData(Data([1, 2, 3]), forType: .png)
        XCTAssertThrowsError(try DesktopPetDrop.read(from: board))
        board.clearContents()
        board.setString(String(repeating: "a", count: 1024 * 1024 + 1), forType: .string)
        XCTAssertThrowsError(try DesktopPetDrop.read(from: board))
        board.clearContents()
        let items = (0..<11).map { index -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString("item \(index)", forType: .string)
            return item
        }
        board.writeObjects(items)
        XCTAssertThrowsError(try DesktopPetDrop.read(from: board))
        board.clearContents()
        let unsupported = NSPasteboardItem()
        unsupported.setData(Data([1]), forType: .init("test.unsupported"))
        let validItem = NSPasteboardItem()
        validItem.setString("valid", forType: .string)
        board.writeObjects([validItem, unsupported])
        XCTAssertThrowsError(try DesktopPetDrop.read(from: board), "不能静默跳过不支持的项")
    }

    @MainActor
    func testAIRoutingDoesNotOptUsersIntoASecondProvider() throws {
        let name = "QuickNote-Privacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AIConfigurationStore(defaults: defaults)
        XCTAssertFalse(store.automaticFallback)
        store.automaticFallback = true
        XCTAssertTrue(store.automaticFallback)
    }

    func testCapabilityOnlyModesAreNotPresentedAsAnalysisFeatures() {
        XCTAssertTrue(AIInputModality.text.availableForAnalysis)
        XCTAssertTrue(AIInputModality.image.availableForAnalysis)
        XCTAssertFalse(AIInputModality.audio.availableForAnalysis)
        XCTAssertFalse(AIInputModality.video.availableForAnalysis)
    }

    @MainActor
    func testSearchExcerptShowsBodyOrTagMatchRatherThanOnlyTitle() {
        let note = NoteRecord()
        note.title = "会议纪要"
        note.plainText = String(repeating: "此前内容。", count: 50) + "🍎 明天交付测试报告。后续安排"
        note.tags = ["交付"]
        XCTAssertTrue(NoteSearchExcerpt.text(for: note, query: "测试报告").contains("测试报告"))
        XCTAssertLessThan(NoteSearchExcerpt.text(for: note, query: "测试报告").count, 100)
        XCTAssertEqual(NoteSearchExcerpt.text(for: note, query: "交付"), "#交付")
    }

    func testFormattingComparisonCountsAttributeChangesWithoutChangingText() {
        let original = NSAttributedString(string: "标题\n正文", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let updated = NSMutableAttributedString(attributedString: original)
        updated.addAttribute(.font, value: NSFont.systemFont(ofSize: 24), range: NSRange(location: 0, length: 2))
        XCTAssertEqual(AIFormattingComparison.changedParagraphCount(before: original, after: updated), 1)
        XCTAssertEqual(AIFormattingComparison.changedParagraphCount(before: original, after: original), 0)
        XCTAssertEqual(original.string, updated.string)
    }

    func testLocalShortcutMappingUsesTheRequestedCommands() {
        XCTAssertEqual(QuickNoteShortcut.resolve(characters: "=", modifiers: .command), .zoomIn)
        XCTAssertEqual(QuickNoteShortcut.resolve(characters: "+", modifiers: [.command, .shift]), .zoomIn)
        XCTAssertEqual(QuickNoteShortcut.resolve(characters: "-", modifiers: .command), .zoomOut)
        XCTAssertEqual(QuickNoteShortcut.resolve(characters: "b", modifiers: .command), .toggleSidebar)
        XCTAssertEqual(QuickNoteShortcut.resolve(characters: "n", modifiers: .command), .newNote)
        XCTAssertEqual(QuickNoteShortcut.resolve(characters: "k", modifiers: .command), .insertLink)
        XCTAssertNil(QuickNoteShortcut.resolve(characters: "b", modifiers: [.command, .option]))
        XCTAssertEqual(QuickNoteShortcut.resolve(characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!), modifiers: [.command, .option]), .previousNote)
        XCTAssertEqual(QuickNoteShortcut.resolve(characters: String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: [.command, .option]), .nextNote)
        XCTAssertNil(QuickNoteShortcut.resolve(characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!), modifiers: .option), "不能抢走文字编辑的移动光标快捷键")
    }

    @MainActor
    func testEditorAppliesAndUndoesValidatedLink() throws {
        let controller = RichTextEditorController()
        let textView = UndoableTestTextView()
        textView.allowsUndo = true
        textView.string = "OpenAI"
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 6))
        controller.connect(textView)

        XCTAssertTrue(controller.applyLink("openai.com"))
        XCTAssertEqual(
            textView.textStorage?.attribute(.link, at: 0, effectiveRange: nil) as? URL,
            URL(string: "https://openai.com")
        )
        controller.undo()
        XCTAssertNil(textView.textStorage?.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertFalse(controller.applyLink("javascript:alert(1)"))
    }

    @MainActor
    func testEditorUndoRestoresLatestTextEdit() throws {
        let controller = RichTextEditorController()
        let textView = UndoableTestTextView()
        textView.allowsUndo = true
        controller.connect(textView)

        textView.insertText("内容", replacementRange: textView.selectedRange())
        controller.refreshUndoAvailability()
        XCTAssertTrue(controller.canUndo)
        controller.undo()

        XCTAssertEqual(textView.string, "")
    }

    @MainActor
    func testEditorUndoRestoresLatestFormattingEditAndSelection() throws {
        let controller = RichTextEditorController()
        let textView = UndoableTestTextView()
        textView.allowsUndo = true
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "标题",
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        ))
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 2))
        controller.connect(textView)

        controller.toggleBold()
        XCTAssertTrue(controller.canUndo)
        controller.undo()

        let font = try XCTUnwrap(textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 2))
    }

    @MainActor
    func testEditorUndoRestoresTypingFormatWithoutSelection() throws {
        let controller = RichTextEditorController()
        let textView = UndoableTestTextView()
        textView.allowsUndo = true
        textView.typingAttributes[.font] = NSFont.systemFont(ofSize: 15)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.connect(textView)

        controller.toggleBold()
        XCTAssertTrue(controller.canUndo)
        let boldFont = try XCTUnwrap(textView.typingAttributes[.font] as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))

        controller.undo()

        let restoredFont = try XCTUnwrap(textView.typingAttributes[.font] as? NSFont)
        XCTAssertFalse(NSFontManager.shared.traits(of: restoredFont).contains(.boldFontMask))
    }

    @MainActor
    func testTextStyleUsesSelectionCapturedBeforePopoverTakesFocus() throws {
        let controller = RichTextEditorController()
        let textView = UndoableTestTextView()
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "第一段\n第二段",
            attributes: [.font: EditorTextStyle.body.font]
        ))
        let selection = (textView.string as NSString).range(of: "第二段")
        textView.setSelectedRange(selection)
        controller.connect(textView)
        controller.captureSelection()
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        controller.applyTextStyle(.heading)

        XCTAssertEqual(
            (textView.textStorage?.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont)?.pointSize,
            EditorTextStyle.heading.font.pointSize
        )
    }

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

    func testTranslationExcludesURLsAndLimitsPronunciation() {
        let instruction = AITextAction.translate.instruction

        XCTAssertTrue(instruction.contains("网址原样保留"))
        XCTAssertTrue(instruction.contains("10 个汉字"))
        XCTAssertTrue(instruction.contains("10 个英文单词"))
    }

    func testTranslationPronunciationLineFindsTextToSpeak() {
        let lines = ["Digital Life", "音标： /ˈdɪdʒɪtl laɪf/"]

        XCTAssertEqual(SelectionResultFormatter.pronunciationKind(for: lines[1])?.languageCode, "en-US")
        XCTAssertEqual(SelectionResultFormatter.pronunciationSource(in: lines, before: 1), "Digital Life")
        XCTAssertNil(SelectionResultFormatter.pronunciationKind(for: "普通译文"))
    }

    func testTranslationRemovesPronunciationWhenSourceExceedsLimit() {
        let result = "Space utilization, read-write efficiency, and management complexity\n音标： /test/"

        XCTAssertEqual(
            SelectionResultFormatter.enforcingPronunciationLimit(
                in: result,
                source: "空间利用率、读写效率和管理复杂度"
            ),
            "Space utilization, read-write efficiency, and management complexity"
        )
        XCTAssertTrue(SelectionResultFormatter.pronunciationIsAllowed(for: "空间利用率"))
    }

    @MainActor
    func testAPIKeysUseOneCanonicalKeychainVault() {
        XCTAssertEqual(AIConfigurationStore.keychainVaultAccount, "profiles.v1")
    }

    func testSelectionActionsHaveNoSecondSendingConfirmation() throws {
        // This is an architectural guard on the UI entry point, not a live model request.
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("QuickNote/Input/SelectionActionController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("aiStore.confirmSending("), "Explicit text actions must not open a second confirmation")
        XCTAssertTrue(source.contains("respond(instruction, source)"), "Only the captured text is passed to analysis")
        XCTAssertTrue(source.contains(".help(state.deliveryNotice)"), "Delivery details remain available without a modal")
    }

    @MainActor
    func testKeychainRetryNeverReopensPasswordPrompt() throws {
        let suite = "QuickNoteTests.KeychainRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reference = UUID().uuidString
        defaults.set(reference, forKey: "ai.slot.2.keychainReference")
        var reads = 0
        let keychain = APIKeyKeychain(copyMatching: { query, _ in
            reads += 1
            XCTAssertEqual((query as NSDictionary)[kSecAttrAccount] as? String, "profile.2.\(reference)")
            var allowed: DarwinBoolean = true
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
            XCTAssertFalse(allowed.boolValue, "重试只能重新检查，不能再次要求用户输入旧钥匙串密码")
            return errSecAuthFailed
        })
        let store = AIConfigurationStore(defaults: defaults, keychain: keychain)
        XCTAssertTrue(store.draft(for: .third).apiKey.isEmpty)
        XCTAssertThrowsError(try store.retryAPIKeyRead(for: .third))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(defaults.string(forKey: "ai.slot.2.keychainReference"), reference)
    }

    @MainActor
    func testKeychainDenialCannotPromptOnReadOrOverwriteOtherProfiles() throws {
        let suite = "QuickNoteTests.KeychainDenial.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var originalInteraction: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&originalInteraction), errSecSuccess)
        var reads = 0, writes = 0
        let keychain = APIKeyKeychain(copyMatching: { _, _ in
            reads += 1
            var allowed: DarwinBoolean = true
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
            XCTAssertFalse(allowed.boolValue, "Passive reads must never display system authorization")
            return errSecInteractionNotAllowed
        }, update: { _, _ in
            writes += 1
            return errSecSuccess
        }, add: { _ in
            writes += 1
            return errSecSuccess
        })
        let store = AIConfigurationStore(defaults: defaults, keychain: keychain)
        for slot in AIProfileSlot.allCases { XCTAssertTrue(store.draft(for: slot).apiKey.isEmpty) }
        var draft = store.draft(for: .third)
        draft.apiKey = "test-only-key"
        XCTAssertThrowsError(try store.save(draft, to: .third))
        XCTAssertEqual(reads, 1, "A denied vault must not be retried by every render")
        XCTAssertEqual(writes, 0, "An unread vault must not be replaced by a partial dictionary")
        XCTAssertNil(defaults.object(forKey: "ai.slot.2.model"))
        var restored: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&restored), errSecSuccess)
        XCTAssertEqual(restored.boolValue, originalInteraction.boolValue)
    }

    @MainActor
    func testKeychainRecoveryIsSlotScopedAndCommitsOnlyAfterSecureInsert() throws {
        let suite = "QuickNoteTests.KeychainRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = AIConfigurationStore.keychainVaultAccount
        let originalVault = Data(#"{"0":"other-test-key","future":"preserve-unknown"}"#.utf8)
        var items = [vault: originalVault]
        var denyVault = true, failInsert = true
        let keychain = APIKeyKeychain(copyMatching: { query, output in
            let account = (query as NSDictionary)[kSecAttrAccount] as! String
            if account == vault && denyVault { return errSecAuthFailed }
            guard let data = items[account] else { return errSecItemNotFound }
            output.pointee = data as CFData
            return errSecSuccess
        }, update: { _, _ in
            XCTFail("Recovery must not update an existing item")
            return errSecAuthFailed
        }, add: { query in
            if failInsert { return errSecInteractionNotAllowed }
            let item = query as NSDictionary
            let account = item[kSecAttrAccount] as! String
            XCTAssertNotEqual(account, vault)
            XCTAssertNil(items[account])
            items[account] = item[kSecValueData] as? Data
            return errSecSuccess
        })
        let store = AIConfigurationStore(defaults: defaults, keychain: keychain)
        var draft = store.draft(for: .third)
        draft.apiKey = "recovered-test-key"
        XCTAssertNotNil(store.keychainIssue(for: .third))
        XCTAssertThrowsError(try store.reconfigure(draft, to: .third))
        XCTAssertNil(defaults.object(forKey: "ai.slot.2.keychainReference"))
        XCTAssertNil(defaults.object(forKey: "ai.slot.2.model"))
        XCTAssertEqual(items.count, 1)
        failInsert = false
        try store.reconfigure(draft, to: .third)
        XCTAssertNil(store.keychainIssue(for: .third))
        XCTAssertEqual(items[vault], originalVault)
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(String(describing: defaults.persistentDomain(forName: suite)).contains(draft.apiKey))
        let reopened = AIConfigurationStore(defaults: defaults, keychain: keychain)
        XCTAssertEqual(reopened.draft(for: .third).apiKey, draft.apiKey)
        XCTAssertNotNil(reopened.keychainIssue(for: .first))
        denyVault = false
        XCTAssertEqual(try reopened.retryAPIKeyRead(for: .first), "other-test-key")
        XCTAssertEqual(items[vault], originalVault)

        // A corrupt but readable vault is not equivalent to an empty one either.
        items[vault] = Data("not-json".utf8)
        let corrupt = AIConfigurationStore(defaults: defaults, keychain: keychain)
        XCTAssertThrowsError(try corrupt.save(draft, to: .first))
        XCTAssertEqual(items.count, 2)
    }

    func testAIConfigurationSupportsAtMostSixAPIConnections() {
        XCTAssertEqual(AIProfileSlot.allCases.map(\.title), (1...6).map { "模型 \($0)" })
        XCTAssertEqual(AIProfileSlot.allCases.count, 6)
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

    @MainActor
    func testInputModalitiesPersistIndependentlyForEachModel() throws {
        let suite = "QuickNoteTests.AIInputModalities.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIConfigurationStore(defaults: defaults)

        store.saveInputModalities([.image, .video], for: .third)

        XCTAssertEqual(store.inputModalities(for: .third), [.text, .image, .video])
        XCTAssertEqual(store.inputModalities(for: .first), [.text])
    }

    @MainActor
    func testModelRoutingKeepsTextAndImagePreferencesIndependent() throws {
        let suite = "QuickNoteTests.AIRouting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIConfigurationStore(defaults: defaults)

        store.setPreferredSlot(.second, for: .text)
        store.setPreferredSlot(.fourth, for: .image)
        store.automaticFallback = false

        XCTAssertEqual(store.preferredSlot(for: .text), .second)
        XCTAssertEqual(store.preferredSlot(for: .image), .fourth)
        XCTAssertFalse(store.automaticFallback)
    }

    func testRouterOnlyFallsBackForTransientOrUnsupportedImageFailures() {
        XCTAssertTrue(AIRouter.shouldFallback(
            after: AIAnalyzerError.server(status: 429, message: "rate limit"),
            modality: .text
        ))
        XCTAssertTrue(AIRouter.shouldFallback(
            after: AIAnalyzerError.server(status: 400, message: "image input is unsupported"),
            modality: .image
        ))
        XCTAssertFalse(AIRouter.shouldFallback(
            after: AIAnalyzerError.server(status: 401, message: "invalid API key"),
            modality: .image
        ))
    }

    func testScreenshotImageIsDownscaledBeforeUpload() throws {
        let image = NSImage(size: NSSize(width: 2_400, height: 1_200))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let data = try XCTUnwrap(ScreenshotImageProcessor.pngData(from: image))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))

        XCTAssertEqual(bitmap.pixelsWide, 2_200)
        XCTAssertEqual(bitmap.pixelsHigh, 1_100)
    }

    func testScreenshotProcessorReadsImageFromServicePasteboard() throws {
        let pasteboard = NSPasteboard(name: .init("QuickNoteTests.ImageService.\(UUID().uuidString)"))
        let image = NSImage(size: NSSize(width: 32, height: 24))
        pasteboard.clearContents()

        XCTAssertTrue(pasteboard.writeObjects([image]))
        XCTAssertNotNil(ScreenshotImageProcessor.image(from: pasteboard))
    }

    func testSelectionResultPanelGrowsWithContentAndStopsBeforeClipping() {
        let short = SelectionPanelLayout.resultHeight(for: "简短解释")
        let medium = SelectionPanelLayout.resultHeight(for: String(repeating: "容器化部署说明。", count: 30))
        let long = SelectionPanelLayout.resultHeight(for: String(repeating: "很长的分析内容。", count: 300))

        XCTAssertEqual(short, 300)
        XCTAssertGreaterThan(medium, short)
        XCTAssertEqual(long, 390)
    }

    func testSelectionSourcePreviewRemainsResizableWhenResultIsVisible() {
        XCTAssertEqual(SelectionPanelLayout.sourcePreviewMaximumHeight, .infinity)
    }

    func testAllSidebarNotesUseTheSameLeadingIndent() {
        XCTAssertEqual(NoteDrawerLayout.noteLeadingIndent, 24)
        XCTAssertEqual(NoteDrawerLayout.noteRowHeight, 28)
        XCTAssertEqual(NoteDrawerLayout.folderRowHeight, NoteDrawerLayout.noteRowHeight)
    }

    func testNoteThemesOfferFiveChoicesAndFallBackToSystem() {
        XCTAssertEqual(NoteTheme.allCases.map(\.rawValue), [
            "system", "paper", "sage", "lavender", "midnight", "blue",
        ])
        XCTAssertEqual(NoteTheme.resolved(from: "missing"), .system)
        XCTAssertEqual(NoteTheme.system.accentColor, .secondaryLabelColor)
        XCTAssertTrue(NoteTheme.midnight.overridesDocumentTextColor)
        XCTAssertFalse(NoteTheme.blue.overridesDocumentTextColor)
    }

    func testSelectionSourceFormatterRestoresBulletLineBreaks() {
        let source = "它在产品栈里的位置 • Pydantic AI：负责 Agent Loop • AI Gateway：负责模型入口"

        XCTAssertEqual(
            SelectionSourceFormatter.normalized(source),
            "它在产品栈里的位置\n• Pydantic AI：负责 Agent Loop\n• AI Gateway：负责模型入口"
        )
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

    @MainActor
    func testSelectionResultFormatterPreservesExplicitHeadingAndEmphasis() throws {
        let result = SelectionResultFormatter.richText(
            from: "# Agent 框架\n## 背景\n1. Pydantic AI\n**Open Stack（开放栈）**：说明",
            asDocumentStart: true
        )

        XCTAssertEqual(result.string, "Agent 框架\n背景\n1. Pydantic AI\nOpen Stack（开放栈）：说明")
        let title = try XCTUnwrap(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(title, EditorTextStyle.title.font)
        for text in ["1. Pydantic AI"] {
            let location = (result.string as NSString).range(of: text).location
            let font = try XCTUnwrap(result.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font, EditorTextStyle.body.font, text)
        }
        let heading = (result.string as NSString).range(of: "背景").location
        XCTAssertEqual((result.attribute(.font, at: heading, effectiveRange: nil) as? NSFont)?.pointSize,
                       EditorTextStyle.heading.font.pointSize)
        let emphasis = (result.string as NSString).range(of: "Open Stack").location
        let font = try XCTUnwrap(result.attribute(.font, at: emphasis, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, EditorTextStyle.body.font.pointSize)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @MainActor
    func testSelectionResultFormatterDoesNotAddAnotherLargeTitleMidNote() throws {
        let result = SelectionResultFormatter.richText(
            from: "# 补充内容\n**重点** *说明* `代码`\n[链接](https://example.com)\n1. 编号\n正文",
            asDocumentStart: false
        )

        XCTAssertEqual(result.string, "补充内容\n重点 说明 代码\n链接\n1. 编号\n正文")
        XCTAssertEqual((result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize,
                       EditorTextStyle.heading.font.pointSize)
        let bodyLocation = (result.string as NSString).range(of: "正文").location
        XCTAssertEqual(result.attribute(.font, at: bodyLocation, effectiveRange: nil) as? NSFont,
                       EditorTextStyle.body.font)
        let codeLocation = (result.string as NSString).range(of: "代码").location
        XCTAssertTrue((result.attribute(.font, at: codeLocation, effectiveRange: nil) as? NSFont)?
            .fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        let linkLocation = (result.string as NSString).range(of: "链接").location
        XCTAssertEqual(result.attribute(.link, at: linkLocation, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com"))
    }

    func testAIResponseSanitizerRemovesPrivateReasoningBlocks() {
        XCTAssertEqual(
            AIResponseSanitizer.cleaned("<think>internal reasoning</think>\n最终答案"),
            "最终答案"
        )
    }

    func testAITextPromptPreservesCompleteBoundaryInput() throws {
        for text in ["", "  第一行\n第二行 🐦  ", String(repeating: "🐦", count: 11_999) + "末"] {
            XCTAssertEqual(
                try AITextAnalyzer.prompt(instruction: "测试任务", text: text),
                "测试任务\n\n<材料>\n\(text)\n</材料>"
            )
        }
    }

    func testAITextPromptRejectsOversizeInput() {
        let text = String(repeating: "鸟", count: 12_000) + "不能丢失的结尾"
        XCTAssertThrowsError(try AITextAnalyzer.prompt(instruction: "测试任务", text: text)) { error in
            XCTAssertTrue(error.localizedDescription.contains("12,000"))
            XCTAssertTrue(error.localizedDescription.contains("分段"))
            XCTAssertFalse(AIRouter.shouldFallback(after: error, modality: .text))
        }
    }

    func testAICompletionRejectsReasoningOnlyResponses() {
        for json in [
            #"{"choices":[{"message":{"reasoning_content":"私有推理"},"finish_reason":"stop"}]}"#,
            #"{"choices":[{"message":{"content":null,"reasoning_content":"私有推理"}}]}"#,
            #"{"choices":[{"message":{"content":"","reasoning_content":"私有推理"}}]}"#,
        ] {
            XCTAssertThrowsError(try OpenAICompatibleClient.decodeCompletion(from: Data(json.utf8)))
        }
    }

    func testAICompletionRejectsIncompleteFinishReasons() {
        for reason in ["length", "content_filter", "tool_calls", "function_call", "unknown"] {
            let json = #"{"choices":[{"message":{"content":"不可导入的部分结果"},"finish_reason":"\#(reason)"}]}"#
            XCTAssertThrowsError(try OpenAICompatibleClient.decodeCompletion(from: Data(json.utf8)), reason) { error in
                XCTAssertFalse(AIRouter.shouldFallback(after: error, modality: .text))
            }
        }
    }

    func testAICompletionPreservesSanitizedFinalContent() throws {
        for finishReason in ["", #", "finish_reason":"stop""#, #", "finish_reason":null"#] {
            let json = #"{"choices":[{"message":{"content":" <think>隐藏推理</think>\n最终答案 ","reasoning_content":"不得使用"}\#(finishReason)}]}"#
            XCTAssertEqual(try OpenAICompatibleClient.decodeCompletion(from: Data(json.utf8)), "最终答案")
        }
    }

    func testAICompletionRejectsMissingFinalContent() {
        for json in [
            #"{"choices":[]}"#,
            #"{"choices":[{"message":{"content":" \n "},"finish_reason":"stop"}]}"#,
            #"{"choices":[{"message":{"content":"<think>只有推理</think>"},"finish_reason":"stop"}]}"#,
            #"{"choices":[{"message":{"tool_calls":[{"type":"function","function":{"name":"save","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[{"message":{"content":null,"tool_calls":[]}}]}"#,
        ] {
            XCTAssertThrowsError(try OpenAICompatibleClient.decodeCompletion(from: Data(json.utf8)))
        }
    }

    func testLegacyFontsNormalizeToLightHierarchyWithoutFlatteningBodyBold() throws {
        let document = NSMutableAttributedString(
            string: "标题\n",
            attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .bold)]
        )
        document.append(NSAttributedString(
            string: "正文",
            attributes: [.font: NSFont.systemFont(ofSize: 15)]
        ))
        document.append(NSAttributedString(
            string: "重点",
            attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .bold)]
        ))
        document.append(NSAttributedString(
            string: "异体",
            attributes: [.font: NSFont(name: "Times New Roman", size: 13)!]
        ))

        let result = NoteFontNormalizer.normalized(document)
        let title = try XCTUnwrap(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let body = try XCTUnwrap(result.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)
        let bold = try XCTUnwrap(result.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)
        let alternate = try XCTUnwrap(result.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)

        XCTAssertEqual(title.pointSize, EditorTextStyle.title.font.pointSize)
        XCTAssertFalse(title.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(body.pointSize, 13)
        XCTAssertEqual(body.fontName, EditorTextStyle.body.font.fontName)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(alternate.fontName, EditorTextStyle.body.font.fontName)
    }

    @MainActor
    func testSelectionResultFormatterReplacesDashHierarchyWithLabelsAndBullets() throws {
        let result = SelectionResultFormatter.richText(
            from: "- 含义：用于构建 Agent\n- 关键术语：\n  - Agent Loop：主循环\n    - 子步骤",
            asDocumentStart: false
        )

        XCTAssertEqual(
            result.string,
            "含义：用于构建 Agent\n关键术语：\n• Agent Loop：主循环\n◦ 子步骤"
        )
        let labelFont = try XCTUnwrap(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(labelFont, EditorTextStyle.body.font)
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
