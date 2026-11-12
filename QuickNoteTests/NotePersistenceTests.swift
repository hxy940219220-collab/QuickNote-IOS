import AppKit
import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import QuickNote

@MainActor
final class NotePersistenceTests: XCTestCase {
    func testStyleDropdownShortViewportKeyboardAndReduceMotion() async throws {
        let viewport = NSRect(x: 90, y: 150, width: 260, height: 220)
        let toolbarFrame = NSRect(x: 100, y: 250, width: 192, height: 32)
        let anchor = NSRect(x: 106, y: 253, width: 38, height: 26)
        let placement = try XCTUnwrap(SelectionDropdownPlacement.make(toolbar: toolbarFrame, anchor: anchor, viewport: viewport))
        XCTAssertTrue(viewport.contains(placement.frame))
        XCTAssertFalse(placement.frame.intersects(toolbarFrame))
        XCTAssertLessThan(placement.frame.height, 152, "高度不足时缩短滚动列表，而不是遮盖功能按键")
        XCTAssertEqual(SelectionDropdownMotion.duration(opening: true, reduceMotion: true), 0)
        XCTAssertEqual(SelectionDropdownMotion.duration(opening: false, reduceMotion: true), 0)
        var reduced = true
        var chosen: EditorTextStyle?
        let parent = NSPanel(contentRect: toolbarFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFrontRegardless()
        let dropdown = SelectionStyleDropdown(reduceMotion: { reduced }, onChoose: { chosen = $0 })
        defer { dropdown.hide(); parent.orderOut(nil) }
        dropdown.show(parent: parent, anchor: anchor, viewport: viewport, selected: .body)
        XCTAssertTrue(dropdown.window.isVisible)
        XCTAssertEqual(dropdown.window.alphaValue, 1)
        XCTAssertNil(dropdown.window.contentView?.layer?.mask)
        let scroll = try XCTUnwrap(dropdown.window.contentView?.descendant(ofType: NSScrollView.self))
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, scroll.contentSize.height)
        XCTAssertTrue(dropdown.handleKey(125))
        XCTAssertTrue(dropdown.handleKey(36))
        XCTAssertEqual(chosen, .monospaced)
        XCTAssertFalse(dropdown.window.isVisible)
        reduced = false
        dropdown.show(parent: parent, anchor: anchor, viewport: viewport, selected: .body)
        let reveal = try XCTUnwrap(dropdown.window.contentView?.layer?.mask?.animation(forKey: "selection.dropdown.reveal"))
        XCTAssertEqual(reveal.duration, 0.18)
        XCTAssertFalse(dropdown.window.frame.intersects(toolbarFrame))
        XCTAssertTrue(dropdown.handleKey(53))
        XCTAssertTrue(dropdown.window.ignoresMouseEvents)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(dropdown.window.isVisible)
    }

    func testStyleDropdownStaysOutsideToolbarAndSurvivesRapidRetoggle() async throws {
        let controller = RichTextEditorController()
        let original = NSAttributedString(string: "示例标题\n选中这一段文字\n其它正文",
            attributes: [.font: EditorTextStyle.body.font])
        var saved = original
        let host = NSHostingView(rootView: RichTextEditor(document: original, cursorLocation: 0,
            controller: controller, onChange: { saved = NSAttributedString(attributedString: $0); _ = $1 }, onActivate: {}))
        let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 520, height: 420),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        let text = try XCTUnwrap(host.descendant(ofType: QuickNoteTextView.self))
        window.makeFirstResponder(text)
        let selection = (text.string as NSString).range(of: "选中这一段文字")
        text.setSelectedRange(selection)
        controller.showSelectionToolbar()
        let bar = try XCTUnwrap(window.childWindows?.first { $0.identifier?.rawValue == "quicknote.selection-format" })
        let styleButton = try XCTUnwrap(bar.contentView?.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "文字样式" })
        guard !(styleButton is NSPopUpButton) else {
            XCTFail("系统弹出菜单会围绕当前项展开，无法保证不覆盖功能按键")
            return
        }
        styleButton.performClick(nil)
        let dropdown = try XCTUnwrap(bar.childWindows?.first { $0.identifier?.rawValue == "quicknote.selection-styles" })
        XCTAssertFalse(dropdown.frame.intersects(bar.frame), "展开动画开始时就不能盖住工具栏")
        XCTAssertLessThanOrEqual(dropdown.frame.maxY, bar.frame.minY - 6)
        try await Task.sleep(for: .milliseconds(230))
        XCTAssertTrue(dropdown.isVisible)
        XCTAssertEqual(dropdown.alphaValue, 1, accuracy: 0.01)
        styleButton.performClick(nil)
        XCTAssertTrue(dropdown.ignoresMouseEvents, "收起中的面板不能拦截点击")
        styleButton.performClick(nil)
        try await Task.sleep(for: .milliseconds(230))
        XCTAssertTrue(dropdown.isVisible, "旧的收起回调不能隐藏重新展开的面板")
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let rows = buttons(in: try XCTUnwrap(dropdown.contentView))
        XCTAssertEqual(rows.count, 5)
        let output = FileManager.default.temporaryDirectory.appending(path: "quicknote-format-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let content = try XCTUnwrap(dropdown.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appending(path: "selection-style-dropdown.png"))
        try XCTUnwrap(rows.first { $0.accessibilityLabel() == "小标题" }).performClick(nil)
        try await Task.sleep(for: .milliseconds(170))
        XCTAssertFalse(dropdown.isVisible)
        XCTAssertTrue(bar.isVisible)
        XCTAssertEqual((saved.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont)?.pointSize, 18)
        XCTAssertEqual(text.selectedRange(), selection)
        let viewport = window.convertToScreen(text.convert(text.visibleRect, to: nil))
        bar.setFrameOrigin(NSPoint(x: viewport.minX + 8, y: viewport.minY + 4))
        styleButton.performClick(nil)
        XCTAssertGreaterThanOrEqual(dropdown.frame.minY, bar.frame.maxY + 6, "底部空间不足时应向上展开")
        XCTAssertFalse(dropdown.frame.intersects(bar.frame))
        XCTAssertTrue(viewport.contains(dropdown.frame))
        XCTAssertTrue(window.firstResponder === text)
        controller.dismissSelectionToolbar()
        XCTAssertFalse(dropdown.isVisible)
        XCTAssertEqual(saved.string, original.string)
    }

    func testSelectionToolbarFormatsWithoutTakingFocusAndDismissesOnEscapeAndCollapse() async throws {
        let controller = RichTextEditorController()
        let original = NSAttributedString(string: "示例便签\n选中这几个字\n保留普通正文",
            attributes: [.font: EditorTextStyle.body.font])
        var saved = original
        let host = NSHostingView(rootView: RichTextEditor(document: original, cursorLocation: 0,
            controller: controller, onChange: { saved = NSAttributedString(attributedString: $0); _ = $1 }, onActivate: {}))
        let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 520, height: 400),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(120))
        let text = try XCTUnwrap(host.descendant(ofType: QuickNoteTextView.self))
        let selection = (text.string as NSString).range(of: "选中这几个字")
        window.makeFirstResponder(text)
        func completeSelection() throws {
            text.setSelectedRange(selection)
            controller.showSelectionToolbar()
        }
        try completeSelection()
        try await Task.sleep(for: .milliseconds(100))
        let bar = try XCTUnwrap(window.childWindows?.first { $0.identifier?.rawValue == "quicknote.selection-format" },
            "key=\(window.isKeyWindow), focused=\(window.firstResponder === text), selection=\(text.selectedRange()), anchor=\(text.firstRect(forCharacterRange: selection, actualRange: nil)), visible=\(text.visibleRect), viewport=\(window.convertToScreen(text.convert(text.visibleRect, to: nil)))")
        XCTAssertTrue(bar.isVisible)
        XCTAssertLessThanOrEqual(bar.frame.height, 36)
        let viewport = window.convertToScreen(text.convert(text.visibleRect, to: nil))
        XCTAssertTrue(viewport.contains(bar.frame), "浮条必须限制在当前正文的可见范围内")
        XCTAssertTrue(window.firstResponder === text)
        let picker = try XCTUnwrap(bar.contentView?.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "文字样式" })
        XCTAssertFalse(picker is NSPopUpButton)
        XCTAssertLessThanOrEqual(picker.frame.width, 48, "正文只需容纳两个字，不要预留长菜单宽度")
        XCTAssertLessThanOrEqual(bar.frame.width, 210)
        picker.performClick(nil)
        let styleWindow = try XCTUnwrap(bar.childWindows?.first { $0.identifier?.rawValue == "quicknote.selection-styles" })
        XCTAssertFalse(styleWindow.frame.intersects(bar.frame))
        func styleButtons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(styleButtons)
        }
        try XCTUnwrap(styleButtons(try XCTUnwrap(styleWindow.contentView)).first { $0.accessibilityLabel() == "小标题" }).performClick(nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual((saved.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont)?.pointSize, 18)
        XCTAssertEqual(text.selectedRange(), selection)
        let bold = try XCTUnwrap(bar.contentView?.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "粗体" })
        bold.performClick(nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue((saved.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont)?
            .fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertTrue(window.firstResponder === text)
        try completeSelection()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(bar.isVisible)
        let highlight = try XCTUnwrap(bar.contentView?.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "背景填充" })
        highlight.performClick(nil)
        XCTAssertNil(saved.attribute(.backgroundColor, at: selection.location, effectiveRange: nil), "先展示颜色，不应直接修改文字")
        let palette = try XCTUnwrap(bar.childWindows?.first { $0.identifier?.rawValue == "quicknote.selection-fill" })
        let colors = try XCTUnwrap(palette.contentView).subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(colors.count, 6)
        XCTAssertTrue(viewport.contains(palette.frame))
        let blue = try XCTUnwrap(colors.first { $0.accessibilityLabel() == "背景填充：蓝色" })
        let paletteOutput = FileManager.default.temporaryDirectory.appending(path: "quicknote-format-ui")
        try FileManager.default.createDirectory(at: paletteOutput, withIntermediateDirectories: true)
        let paletteView = try XCTUnwrap(palette.contentView)
        let paletteBitmap = try XCTUnwrap(paletteView.bitmapImageRepForCachingDisplay(in: paletteView.bounds))
        paletteView.cacheDisplay(in: paletteView.bounds, to: paletteBitmap)
        try XCTUnwrap(paletteBitmap.representation(using: .png, properties: [:]))
            .write(to: paletteOutput.appending(path: "selection-fill-palette.png"))
        blue.performClick(nil)
        let applied = try XCTUnwrap(saved.attribute(.backgroundColor, at: selection.location, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(applied, NSColor.systemBlue.withAlphaComponent(0.28))
        XCTAssertFalse(palette.isVisible)
        XCTAssertTrue(window.firstResponder === text)
        highlight.performClick(nil)
        XCTAssertEqual(blue.state, .on, "打开色板时应标明当前填充色")
        try XCTUnwrap(colors.first { $0.accessibilityLabel() == "无填充" }).performClick(nil)
        XCTAssertNil(saved.attribute(.backgroundColor, at: selection.location, effectiveRange: nil))
        let output = FileManager.default.temporaryDirectory.appending(path: "quicknote-format-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let content = try XCTUnwrap(bar.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appending(path: "selection-toolbar.png"))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        highlight.performClick(nil)
        XCTAssertTrue(palette.isVisible)
        text.keyDown(with: escape)
        XCTAssertFalse(bar.isVisible)
        XCTAssertFalse(palette.isVisible, "收起快捷栏时也必须关闭颜色面板")
        try completeSelection()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(bar.isVisible, "focused=\(window.firstResponder === text), ownerVisible=\(window.isVisible), range=\(text.selectedRange()), anchor=\(text.firstRect(forCharacterRange: selection, actualRange: nil)), barFrame=\(bar.frame)")
        text.setSelectedRange(NSRange(location: selection.location, length: 0))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(bar.isVisible)
        XCTAssertEqual(saved.string, original.string)
        let shiftRight = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .shift, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: String(UnicodeScalar(NSRightArrowFunctionKey)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!), isARepeat: false, keyCode: 124))
        text.keyDown(with: shiftRight)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(bar.isVisible, "键盘选中文字也应出现快捷栏")
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: text.enclosingScrollView?.contentView)
        XCTAssertFalse(bar.isVisible)
        try completeSelection()
        text.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(bar.isVisible, "输入法组字不能被浮条打断")
        text.unmarkText()
        try completeSelection()
        controller.clearUndoHistory()
        XCTAssertFalse(bar.isVisible, "切换文档时不能保留旧选区的浮条")
        try completeSelection()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(bar.isVisible, "切换到其他应用时应收起")
    }

    func testCompactSelectionToolbarTodoRoundTripPreservesWordsAndSymmetricTargets() async throws {
        let controller = RichTextEditorController()
        let original = NSAttributedString(string: "第一项\n第二项\n不修改",
            attributes: [.font: EditorTextStyle.body.font])
        var saved = original
        let host = NSHostingView(rootView: RichTextEditor(document: original, cursorLocation: 0,
            controller: controller, onChange: { saved = NSAttributedString(attributedString: $0); _ = $1 }, onActivate: {}))
        let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 520, height: 400),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        let text = try XCTUnwrap(host.descendant(ofType: QuickNoteTextView.self))
        window.makeFirstResponder(text)
        let selection = NSRange(location: 0, length: 7)
        text.setSelectedRange(selection)
        controller.showSelectionToolbar()
        let bar = try XCTUnwrap(window.childWindows?.first { $0.identifier?.rawValue == "quicknote.selection-format" })
        let targets = try XCTUnwrap(bar.contentView).subviews.compactMap { $0 as? NSButton }
            .filter { $0.accessibilityLabel() != "文字样式" }.sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(targets.count, 5)
        for target in targets { XCTAssertEqual(target.frame.size, NSSize(width: 26, height: 26)) }
        for pair in zip(targets, targets.dropFirst()) { XCTAssertEqual(pair.1.frame.minX - pair.0.frame.maxX, 2) }
        let todo = try XCTUnwrap(targets.first { $0.accessibilityLabel() == "待办" })
        todo.performClick(nil)
        XCTAssertEqual(saved.string, "\u{FFFC} 第一项\n\u{FFFC} 第二项\n不修改")
        XCTAssertEqual(saved.attachmentCount, 2)
        XCTAssertEqual(todo.state, .on)
        XCTAssertTrue(window.firstResponder === text)
        todo.performClick(nil)
        XCTAssertEqual(saved.string, original.string)
        XCTAssertEqual(saved.attachmentCount, 0)
        XCTAssertEqual(text.selectedRange(), selection)
        let output = FileManager.default.temporaryDirectory.appending(path: "quicknote-format-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let content = try XCTUnwrap(bar.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appending(path: "selection-toolbar-compact.png"))
    }

    func testStylePopoverAppliesHeadingToSelectedParagraphThroughWholeRowClicks() async throws {
        let fixture = try sessionEditorFixture()
        let session = fixture.session
        try session.createAndOpen()
        session.update(document: NSAttributedString(string: "示例标题\n需要放大的文字\n普通正文",
            attributes: [.font: EditorTextStyle.body.font]), cursorLocation: 0)
        let controller = RichTextEditorController()
        let host = NSHostingView(rootView: RichTextEditor(document: session.document, cursorLocation: 0,
            controller: controller, onChange: fixture.update, onActivate: {}))
        let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 730, height: 520),
            styleMask: NotePanelController.windowStyleMask, backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        fixture.addUICleanup {
            controller.dismissSelectionToolbar()
            host.descendant(ofType: NSTextView.self)?.delegate = nil
            window.orderOut(nil)
            window.contentView = nil
        }
        try await Task.sleep(for: .milliseconds(180))
        let text = try XCTUnwrap(host.descendant(ofType: QuickNoteTextView.self))
        let selected = (text.string as NSString).range(of: "需要放大的文字")
        window.makeFirstResponder(text)
        text.setSelectedRange(selected)
        func click(_ point: NSPoint, in view: NSView) throws {
            let target = try XCTUnwrap(view.window)
            let location = view.convert(point, to: nil)
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                modifierFlags: [], timestamp: 1, windowNumber: target.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 0))
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                modifierFlags: [], timestamp: 0.9, windowNumber: target.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.postEvent(up, atStart: true)
            target.sendEvent(down)
        }
        controller.captureSelection()
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentViewController = NSHostingController(rootView: NoteFormatPopover(controller: controller,
            toggleChecklist: {}, chooseFiles: {}))
        popover.show(relativeTo: NSRect(x: 150, y: 100, width: 100, height: 20), of: host, preferredEdge: .maxY)
        fixture.addUICleanup {
            popover.close()
            popover.contentViewController = nil
        }
        try await Task.sleep(for: .milliseconds(200))
        let content = try XCTUnwrap(popover.contentViewController?.view)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let output = FileManager.default.temporaryDirectory.appending(path: "quicknote-format-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appending(path: "style-popover.png"))
        for (style, fromTop) in [(EditorTextStyle.subheading, CGFloat(112)), (.heading, 85), (.body, 137)] {
            try click(NSPoint(x: content.bounds.width - 30,
                y: content.isFlipped ? fromTop : content.bounds.height - fromTop), in: content)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual((text.textStorage?.attribute(.font, at: selected.location, effectiveRange: nil) as? NSFont)?.pointSize,
                           style.font.pointSize, "样式操作必须改变原选区的字号")
            XCTAssertEqual(text.selectedRange(), selected)
            XCTAssertEqual((session.document.attribute(.font, at: selected.location, effectiveRange: nil) as? NSFont)?.pointSize,
                           style.font.pointSize, "字号必须同步到保存模型")
        }
        popover.close()
        XCTAssertEqual(text.string, "示例标题\n需要放大的文字\n普通正文")
    }

    func testNativePlaceholderHidesDuringIMECompositionAndReturnsAfterClearing() throws {
        let host = NSHostingView(rootView: RichTextEditor(document: NSAttributedString(), cursorLocation: 0,
            controller: RichTextEditorController(), onChange: { _, _ in }, onActivate: {}))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 180)
        host.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(host.descendant(ofType: QuickNoteTextView.self))
        let placeholder = try XCTUnwrap(text.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "开始记录…" }, "提示文字应由原生编辑器管理")
        XCTAssertFalse(placeholder.isHidden)
        text.setMarkedText("da", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(text.hasMarkedText())
        XCTAssertTrue(placeholder.isHidden, "拼音尚未提交时就必须隐藏提示，不能等待文档保存")
        text.unmarkText()
        text.string = ""
        text.didChangeText()
        XCTAssertFalse(placeholder.isHidden)
        XCTAssertNil(placeholder.hitTest(NSPoint(x: 2, y: 2)), "占位提示不能拦截正文点击")
    }

    func testStandardSpacingResetsImportedLineMetricsAndOversizedBlankParagraphs() throws {
        let text = ProductUndoTextView()
        let content = "标题\n\n正文\n\n下一段"
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 24
        style.paragraphSpacing = 28
        style.lineHeightMultiple = 2.4
        style.minimumLineHeight = 48
        style.maximumLineHeight = 72
        style.lineSpacing = 16
        style.headIndent = 12
        let document = NSMutableAttributedString(string: content,
            attributes: [.font: EditorTextStyle.body.font, .paragraphStyle: style])
        document.addAttribute(.font, value: EditorTextStyle.title.font,
                              range: NSRange(location: 0, length: 4))
        text.textStorage?.setAttributedString(document)
        text.setSelectedRange(NSRange(location: 0, length: document.length))
        let controller = RichTextEditorController()
        controller.connect(text)
        text.undoManager?.beginUndoGrouping()
        controller.applyParagraphSpacing(before: 0, after: 4)
        text.undoManager?.endUndoGrouping()
        XCTAssertEqual(text.string, content, "调整间距不能删除用户空行")
        for location in [0, 3, 4, 7] {
            let actual = try XCTUnwrap(text.textStorage?.attribute(.paragraphStyle, at: location,
                effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(actual.paragraphSpacingBefore, 0)
            XCTAssertEqual(actual.paragraphSpacing, 4)
            XCTAssertEqual(actual.lineSpacing, 1)
            XCTAssertEqual(actual.lineHeightMultiple, 0)
            XCTAssertEqual(actual.minimumLineHeight, 0)
            XCTAssertEqual(actual.maximumLineHeight, 0)
            XCTAssertEqual(actual.headIndent, 12, "保留段落缩进")
        }
        XCTAssertEqual((text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize,
                       EditorTextStyle.title.font.pointSize, "不能把真实标题改成正文")
        XCTAssertEqual((text.textStorage?.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.pointSize,
                       EditorTextStyle.body.font.pointSize, "空行不应继续撑着大标题字号")
        controller.undo()
        XCTAssertEqual(text.attributedString(), document, "还原间距应能完整撤销")
    }

    func testRenderRefinedSidebarAndEditorWithSampleData() async throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "quicknote-editor-refinements")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let notes = ["产品设计讨论", "下周行动计划", "新便签", "随手记下的灵感"].map { title in
            let note = NoteRecord(); note.title = title; return note
        }
        notes[0].isPinned = true
        notes[1].isPinned = true
        let folder = NoteFolder(name: "工作资料")
        notes[1].folderID = folder.id
        notes[2].folderID = folder.id
        let sidebar = NoteDrawerView(notes: notes, folders: [folder], selectedID: notes[2].id,
            select: { _ in }, create: {}, createFolder: { _ in }, renameFolder: { _, _ in },
            deleteFolder: { _ in }, move: { _, _ in }, togglePin: { _ in }, delete: { _ in },
            theme: .system, showSearch: {}, editTags: { _ in })
        let controller = RichTextEditorController()
        let document = NSMutableAttributedString(string: "灵感随手记\n\n先收集想法，再整理成行动。\n\n下一步：讨论新的交互方案。",
            attributes: [.font: EditorTextStyle.body.font])
        document.addAttribute(.font, value: EditorTextStyle.title.font, range: NSRange(location: 0, length: 6))
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            RichTextEditor(document: document, cursorLocation: 0, controller: controller,
                onChange: { _, _ in }, onActivate: {})
        })
        let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 710, height: 460),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200))
        let text = try XCTUnwrap(host.descendant(ofType: QuickNoteTextView.self))
        text.setSelectedRange(NSRange(location: 0, length: document.length))
        controller.applyParagraphSpacing(before: 0, after: 4)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appending(path: "sidebar-and-spacing.png"))
    }

    func testStandardSpacingResetsTrailingEmptyParagraphTypingMetrics() throws {
        let text = QuickNoteTextView()
        text.string = "标题\n"
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        let inherited = NSMutableParagraphStyle()
        inherited.lineHeightMultiple = 3
        inherited.minimumLineHeight = 60
        inherited.paragraphSpacingBefore = 20
        text.typingAttributes = [.font: EditorTextStyle.title.font, .paragraphStyle: inherited]
        let controller = RichTextEditorController()
        controller.connect(text)
        controller.applyParagraphSpacing(before: 0, after: 4)
        let result = try XCTUnwrap(text.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(result.minimumLineHeight, 0)
        XCTAssertEqual(result.lineHeightMultiple, 0)
        XCTAssertEqual(result.paragraphSpacing, 4)
        XCTAssertEqual((text.typingAttributes[.font] as? NSFont)?.pointSize, EditorTextStyle.body.font.pointSize)
    }

    func testSidebarUsesReferenceGroupsAndLightweightPinnedShortcuts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "QuickNote/Views/NoteDrawerView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func noteRow"))
        let end = try XCTUnwrap(source.range(of: "private var unfiledNotes", range: start.upperBound..<source.endIndex))
        let row = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(source.contains("sectionHeading(\"置顶\""))
        XCTAssertTrue(source.contains("ForEach(pinnedNotes)"))
        XCTAssertFalse(row.contains("Image(systemName: \"pin.fill\")"))
        XCTAssertFalse(row.contains("Circle()"))
        XCTAssertTrue(row.contains("systemName: pinnedShortcut ? \"pin\" : \"doc.text\""))
    }

    func testSidebarFolderHierarchyUsesWholeRowExpansionWithoutDisclosureArrow() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "QuickNote/Views/NoteDrawerView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func folderRow"))
        let end = try XCTUnwrap(source.range(of: "private func noteRow", range: start.upperBound..<source.endIndex))
        let row = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(row.contains("systemName: \"folder\""))
        XCTAssertFalse(row.contains("chevron."), "文件夹行无需额外的展开箭头")
        XCTAssertTrue(row.contains("toggleFolder(folder)"))
        XCTAssertTrue(row.contains(".overlay(alignment: .trailing)"), "菜单覆盖在整行按钮上，不应切走展开的点击区域")
        XCTAssertTrue(row.contains(".accessibilityValue(expandedFolders.contains(folder.id)"))
        XCTAssertTrue(row.contains("weight: .regular"))
        XCTAssertTrue(source.contains("sectionHeading(\"文件夹\""))
        XCTAssertTrue(source.contains("LazyVStack(alignment: .leading, spacing: 6)"),
                      "折叠分组之间只留一个小间距，不能保留空白行")
        XCTAssertGreaterThanOrEqual(NoteDrawerLayout.folderNoteLeadingIndent, 28)
    }

    func testSidebarSearchHasCompactHeightAndRetainsClearTarget() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "QuickNote/Views/NoteDrawerView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var searchField:"))
        let end = try XCTUnwrap(source.range(of: "private var libraryList:", range: start.upperBound..<source.endIndex))
        let field = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(field.contains(".frame(height: 26)"))
        XCTAssertTrue(field.contains(".frame(width: 22, height: 22)"), "清除按钮不能因为缩矮而失去点击区域")
    }

    func testEditorUsesOnlyOneLayerOfHorizontalWhitespace() {
        XCTAssertEqual(NoteChrome.editorInsets.width, 0,
                       "外侧已经保留 24pt 布局边距，不应在原生编辑器里再叠加 12pt 留白")
    }

    func testCompactCalendarNativeLayoutAndSamplePreviews() throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "quicknote-density-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let calendar = Calendar(identifier: .gregorian)
        for (month, maximumHeight) in [(10, CGFloat(266)), (8, CGFloat(298)), (2, CGFloat(234))] {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: 19)))
            let host = NSHostingView(rootView: CalendarPopoverView(selectedDate: .constant(date))
                .background(Color(nsColor: .windowBackgroundColor)))
            let size = host.fittingSize
            XCTAssertEqual(size.width, 244, accuracy: 0.5)
            XCTAssertLessThanOrEqual(size.height, maximumHeight, "日历只为实际周数分配高度")
            let window = NSPanel(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appending(path: "calendar-2026-\(month).png"))
        }
    }

    func testSidebarWiresPrivateNativeDragAndFolderDropTargets() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "QuickNote/Views/NoteDrawerView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".onDrag { SidebarDragReference"))
        XCTAssertTrue(source.contains(".dropDestination(for: NoteDragReference.self)"))
        XCTAssertTrue(source.contains(".visibility(.ownProcess)"), "拖动只传应用内笔记引用，不能导出正文")
        XCTAssertTrue(source.contains("NoteDrawerDrop.move("))
    }

    func testFolderRenameHasHoverMenuWithoutBlockingWholeRowAndKeepsDropTarget() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "QuickNote/Views/NoteDrawerView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func folderRow"))
        let end = try XCTUnwrap(source.range(of: "private func noteRow", range: start.upperBound..<source.endIndex))
        let row = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(row.contains(".accessibilityLabel(\"编辑文件夹\")"), "文件夹操作不能只藏在右键菜单")
        XCTAssertTrue(row.contains("FolderInlineNameEditor("))
        XCTAssertTrue(source.contains("@State private var hoveredFolderID: UUID?"))
        XCTAssertTrue(row.contains(".onHover"))
        XCTAssertTrue(row.contains(".opacity(hoveredFolderID == folder.id ? 0.75 : 0)"))
        XCTAssertTrue(row.contains(".allowsHitTesting(hoveredFolderID == folder.id)"), "隐藏的菜单不能拦截整行展开")
        XCTAssertFalse(source.contains(".sheet(item: $editingFolder)"), "编辑名称应在文件夹行内完成")
        XCTAssertTrue(row.contains(".onDrop(of: [SidebarDragReference.contentType]"))
        XCTAssertTrue(row.contains("toggleFolder(folder)"), "单击文件夹仍用于展开，不应变成改名")
    }

    func testFolderInlineEditorWiresSaveCancelAndValidationWithoutChangingNameOnTyping() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "QuickNote/Views/NoteDrawerView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("struct FolderInlineNameEditor: View"))
        XCTAssertTrue(source.contains(".onSubmit(submit)"))
        XCTAssertTrue(source.contains(".onExitCommand(perform: cancel)"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"保存文件夹名称\")"))
        XCTAssertTrue(source.contains(".accessibilityLabel(\"取消重命名\")"))
    }

    func testSidebarIsCountFreeCompactAndUsesMatchingFolderMenus() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "QuickNote/Views/NoteDrawerView.swift"), encoding: .utf8)
        XCTAssertLessThanOrEqual(NoteDrawerLayout.noteRowHeight, 28)
        XCTAssertFalse(source.contains("count: pinnedNotes.count"))
        XCTAssertFalse(source.contains("count: visibleFolders.count"))
        XCTAssertFalse(source.contains("count: unfiledNotes.count"))
        XCTAssertFalse(source.contains("Text(\"\\(notes(in: folder).count)\")"))
        XCTAssertFalse(source.contains("Button(\"标签…\")"))
        let start = try XCTUnwrap(source.range(of: "private func folderRow"))
        let end = try XCTUnwrap(source.range(of: "private func noteRow", range: start.upperBound..<source.endIndex))
        let row = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(row.contains("folderActions(folder)"))
        XCTAssertTrue(row.contains("systemName: \"ellipsis\""))
        XCTAssertFalse(row.contains("systemName: \"pencil\""))
    }

    func testInlineFolderRenameFocusEnterValidationAndEscapeWithSampleData() async throws {
        let container = try ModelContainer(for: NoteRecord.self, NoteFolder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repository = NoteRepository(context: container.mainContext)
        let folder = try repository.createFolder(named: "工作资料")
        _ = try repository.createFolder(named: "会议纪要")
        try repository.save()
        var saved = 0, cancelled = 0
        let host = NSHostingView(rootView: FolderInlineNameEditor(initialName: folder.name, save: { name in
            try repository.rename(folder, to: name)
            try repository.save()
            saved += 1
        }, cancel: { cancelled += 1 }).frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: NoteChrome.sidebar)))
        let window = NSPanel(contentRect: NSRect(x: 200, y: 200, width: 160, height: 90),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "文件夹改名验证（示例数据）"
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; withExtendedLifetime(container) {} }
        try await Task.sleep(for: .milliseconds(160))
        let field = try XCTUnwrap(host.descendant(ofType: NSTextField.self))
        XCTAssertEqual(field.stringValue, "工作资料")
        XCTAssertTrue(try XCTUnwrap(window.firstResponder as? NSTextView).isFieldEditor, "进入改名后自动聚焦")
        func draft(_ value: String) async throws {
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            try await Task.sleep(for: .milliseconds(50))
        }
        func key(_ value: String, code: UInt16) async throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code))
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(50))
        }
        let output = FileManager.default.temporaryDirectory.appending(path: "quicknote-folder-rename-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func snapshot(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appending(path: name))
        }
        try snapshot("inline-name.png")
        try await draft("会议纪要")
        XCTAssertEqual(folder.name, "工作资料", "打字只更新草稿，未保存前不能更改分类")
        try await key("\r", code: 36)
        XCTAssertEqual(saved, 0)
        XCTAssertEqual(folder.name, "工作资料")
        XCTAssertEqual(field.stringValue, "会议纪要", "重名时保留用户草稿供修改")
        try snapshot("duplicate-name.png")
        try await draft("  项目归档  ")
        try await key("\r", code: 36)
        XCTAssertEqual(saved, 1)
        XCTAssertEqual(folder.name, "项目归档")
        try await draft("未保存草稿")
        try await key("\u{1b}", code: 53)
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(saved, 1)
        XCTAssertEqual(folder.name, "项目归档", "Esc 不得提交草稿")
        XCTAssertLessThanOrEqual(host.fittingSize.width, 160, "编辑不能撑大紧凑侧栏")
    }

    func testNativeNoteDragTransferContainsOnlyAnIDAndRoundTrips() async throws {
        let note = NoteRecord()
        note.title = "仅限本地的标题"
        note.plainText = "不应被拖动导出的正文"
        let reference = NoteDragReference(id: note.id)
        let encoded = try JSONEncoder().encode(reference)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id"])
        XCTAssertEqual(try JSONDecoder().decode(NoteDragReference.self, from: encoded).id, note.id)
        if #available(macOS 15.2, *) {
            XCTAssertTrue(NoteDragReference.exportedContentTypes(visibility: .ownProcess).contains(NoteDragReference.contentType))
            let data = try await reference.exported(as: NoteDragReference.contentType)
            let restored = try await NoteDragReference(importing: data, contentType: NoteDragReference.contentType)
            XCTAssertEqual(restored.id, note.id)
        }
    }

    func testNativeSidebarItemProvidersKeepEntityKindsPrivateAndRoundTrip() async throws {
        for kind in [SidebarDragReference.Kind.note, .folder] {
            let reference = SidebarDragReference(id: UUID(), kind: kind)
            let provider = reference.itemProvider()
            XCTAssertTrue(SidebarDropDelegate.accepts([provider], kinds: [.note, .folder]))
            XCTAssertEqual(SidebarDropDelegate.accepts([provider], kinds: [.note]), kind == .note)
            let restored: SidebarDragReference = try await withCheckedThrowingContinuation { continuation in
                provider.loadTransferable(type: SidebarDragReference.self) { continuation.resume(with: $0) }
            }
            XCTAssertEqual(restored.id, reference.id)
            XCTAssertEqual(restored.kind, kind)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reference)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), kind == .note ? Set(["id"]) : Set(["id", "kind"]))
            provider.suggestedName = nil
            XCTAssertTrue(SidebarDropDelegate.accepts([provider], kinds: [.note, .folder]), "平台丢失预览提示时不能破坏私有引用拖放")
        }
        XCTAssertFalse(SidebarDropDelegate.accepts([], kinds: [.note, .folder]))
        XCTAssertFalse(SidebarDropDelegate.accepts([NSItemProvider(object: "普通文字" as NSString)], kinds: [.note, .folder]))
        let note = NoteRecord()
        XCTAssertFalse(NoteDrawerDrop.move([SidebarDragReference(id: note.id, kind: .folder)], notes: [note], to: NoteFolder(name: "示例")) { _, _ in
            XCTFail("文件夹引用不能被当成便签移动")
        })
    }

    func testNoteDropMovesExistingNoteWithoutChangingTextPinOrSelectionMetadata() {
        let note = NoteRecord()
        note.isPinned = true
        note.title = "测试账号"
        note.plainText = "保留所有内容"
        note.cursorLocation = 3
        let folder = NoteFolder(name: "工作资料")
        let originalID = note.id
        var moves = 0
        XCTAssertTrue(NoteDrawerDrop.move([NoteDragReference(id: note.id)], notes: [note], to: folder) { item, destination in
            XCTAssertTrue(item === note)
            item.folderID = destination?.id
            moves += 1
        })
        XCTAssertEqual(moves, 1)
        XCTAssertEqual(note.id, originalID)
        XCTAssertEqual(note.folderID, folder.id)
        XCTAssertTrue(note.isPinned)
        XCTAssertEqual(note.plainText, "保留所有内容")
        XCTAssertEqual(note.cursorLocation, 3)
        XCTAssertTrue(NoteDrawerDrop.move([NoteDragReference(id: note.id)], notes: [note], to: nil) { item, destination in
            item.folderID = destination?.id
        })
        XCTAssertNil(note.folderID)
    }

    func testNoteDropRejectsStaleDeletedAndUnchangedReferencesAndDeduplicates() {
        let note = NoteRecord(), deleted = NoteRecord()
        deleted.deletedAt = .now
        let folder = NoteFolder(name: "工作资料")
        var movedIDs: [UUID] = []
        let move: (NoteRecord, NoteFolder?) -> Void = { item, destination in
            movedIDs.append(item.id); item.folderID = destination?.id
        }
        XCTAssertFalse(NoteDrawerDrop.move([], notes: [note], to: folder, using: move))
        XCTAssertFalse(NoteDrawerDrop.move([NoteDragReference(id: UUID()), NoteDragReference(id: deleted.id)],
            notes: [note, deleted], to: folder, using: move))
        XCTAssertFalse(NoteDrawerDrop.move([NoteDragReference(id: note.id)], notes: [note], to: nil, using: move))
        XCTAssertTrue(movedIDs.isEmpty)
        let reference = NoteDragReference(id: note.id)
        XCTAssertTrue(NoteDrawerDrop.move([reference, reference], notes: [note, note], to: folder, using: move))
        XCTAssertEqual(movedIDs, [note.id])
        XCTAssertFalse(NoteDrawerDrop.move([reference], notes: [note], to: folder, using: move))
        XCTAssertEqual(movedIDs, [note.id])
    }

    func testDropFolderAssignmentSurvivesReopenWithoutDuplicatingOrRewritingDocument() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "QuickNote-Drop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "library.store")
        let store = NoteDocumentStore(root: root.appending(path: "Documents"))
        let id: UUID, folderID: UUID
        do {
            let container = try ModelContainer(for: NoteRecord.self, NoteFolder.self,
                configurations: ModelConfiguration(url: url))
            let repository = NoteRepository(context: container.mainContext)
            let note = repository.createNote()
            let folder = try repository.createFolder(named: "工作资料")
            id = note.id; folderID = folder.id
            note.isPinned = true
            note.plainText = "拖放归档的内容"
            try store.save(NSAttributedString(string: note.plainText), id: id)
            XCTAssertTrue(NoteDrawerDrop.move([NoteDragReference(id: id)], notes: try repository.allNotes(), to: folder) {
                repository.move($0, to: $1)
            })
            try repository.rename(folder, to: "项目归档")
            try repository.save()
        }
        let reopened = try ModelContainer(for: NoteRecord.self, NoteFolder.self,
            configurations: ModelConfiguration(url: url))
        let reopenedRepository = NoteRepository(context: reopened.mainContext)
        let notes = try reopenedRepository.allNotes()
        XCTAssertEqual(try reopenedRepository.allFolders().map(\.name), ["项目归档"], "重开后保留分类名称")
        XCTAssertEqual(notes.map(\.id), [id])
        XCTAssertEqual(notes.first?.folderID, folderID)
        XCTAssertEqual(notes.first?.isPinned, true)
        XCTAssertEqual(try store.load(id: id).string, "拖放归档的内容")
    }

    func testSearchDismissalUsesFullHitAreaAndOutsideBackdrop() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let drawer = try String(contentsOf: root.appending(path: "QuickNote/Views/NoteDrawerView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(drawer.range(of: "Button(action: close)"))
        let end = try XCTUnwrap(drawer.range(of: ".help(\"关闭搜索", range: start.upperBound..<drawer.endIndex))
        let closeButton = String(drawer[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(closeButton.contains("frame(width: 34, height: 34)"))
        XCTAssertTrue(closeButton.contains("contentShape(Rectangle())"))
        XCTAssertFalse(drawer.contains(".sheet(isPresented: $searchPresented)"))
        let app = try String(contentsOf: root.appending(path: "QuickNote/Views/RootNoteView.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains(".onTapGesture(perform: close)"), "搜索背景应拦截并关闭，不能穿透到正文")
        XCTAssertTrue(app.contains(".disabled(searchPresented)"), "搜索期间不能误操作底层便签")
    }

    func testStandardSpacingAndSimplifiedPetSettings() throws {
        let text = QuickNoteTextView()
        text.textStorage?.setAttributedString(NSAttributedString(string: "正文"))
        RichTextEditorController().applyDefaultParagraphSpacing(in: text)
        let style = try XCTUnwrap(text.textStorage?.attribute(.paragraphStyle, at: 0,
            effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.paragraphSpacingBefore, 0)
        XCTAssertEqual(style.paragraphSpacing, 4)
        XCTAssertEqual((text.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.paragraphSpacing, 4)

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appending(path: "QuickNote/Views/RootNoteView.swift"), encoding: .utf8)
        let panel = try XCTUnwrap(settings.range(of: "private struct QuickNoteSettingsView"))
        let panelEnd = try XCTUnwrap(settings.range(of: "private struct NoteMCPSettingsView",
            range: panel.upperBound..<settings.endIndex))
        let content = String(settings[panel.lowerBound..<panelEnd.lowerBound])
        let pet = try XCTUnwrap(content.range(of: "settingsRow(\"桌宠陪伴\", systemImage: \"pawprint\")"))
        let theme = try XCTUnwrap(content.range(of: "settingsButton(\"便签主题\""))
        XCTAssertLessThan(pet.lowerBound, theme.lowerBound)
        XCTAssertFalse(content.contains("Pip"), "设置菜单使用通用的桌宠名称")
        XCTAssertFalse(content.contains("本机增强识别"))
        let voice = try String(contentsOf: root.appending(path: "QuickNote/Input/DesktopPetVoice.swift"), encoding: .utf8)
        XCTAssertFalse(voice.contains("voice.offlineRefinement.enabled"))
        XCTAssertTrue(voice.contains("if VoiceOfflineRecognition.isAvailable {"))
    }

    func testDrawerSearchMatchesPersistentReferenceField() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "QuickNote/Views/NoteDrawerView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("TextField(\"筛选便签\""))
        XCTAssertTrue(source.contains("NoteDrawerSearch.matches"))
        XCTAssertTrue(source.contains("private var searchField:"))
    }

    func testReferenceChromeKeepsCompactSidebarAndMainColumnToolbar() throws {
        XCTAssertEqual(NotePanelController.drawerWidth, 210)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "QuickNote/Views/RootNoteView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("private var sidebarColumn:"))
        XCTAssertTrue(source.contains("private var editorToolbar:"))
        XCTAssertTrue(source.contains("displayScale: NoteChrome.editorDisplayScale"))
        XCTAssertTrue(source.contains("Text(\"AI\")"))
        XCTAssertTrue(source.contains(".padding(.horizontal, 24)"))
    }

    func testCompactChromeUsesNativeHelpInsteadOfOverlappingTooltipOverlay() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "QuickNote/Views/RootNoteView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("private struct QuickNoteTooltip"))
        XCTAssertFalse(source.contains(".quickNoteTooltip(label"))
        XCTAssertTrue(source.contains(".help(label)"))
        XCTAssertLessThanOrEqual(NoteChrome.toolbarHeight, 32)
    }

    func testCompactSidebarHeadingCannotBeCompressedByTotalCount() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "QuickNote/Views/NoteDrawerView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var header:"))
        let end = try XCTUnwrap(source.range(of: "private var searchField:", range: start.upperBound..<source.endIndex))
        let header = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(header.contains("Text(\"全部便签\")"))
        XCTAssertTrue(header.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertFalse(header.contains("notes.count"))
        let search = try XCTUnwrap(header.range(of: "Image(systemName: \"text.magnifyingglass\")"))
        let folder = try XCTUnwrap(header.range(of: "Image(systemName: \"folder.badge.plus\")"))
        let note = try XCTUnwrap(header.range(of: "Image(systemName: \"square.and.pencil\")"))
        XCTAssertLessThan(search.lowerBound, folder.lowerBound)
        XCTAssertLessThan(folder.lowerBound, note.lowerBound)
        XCTAssertTrue(header.contains(".help(\"全文搜索（⌘⇧F）· 查找所有便签的正文\")"))
        XCTAssertTrue(header.contains(".accessibilityLabel(\"全文搜索\")"))
    }

    func testEditorDoesNotReserveBlankFooterForPageNavigation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "QuickNote/Views/RootNoteView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains(".safeAreaInset(edge: .bottom"))
        XCTAssertTrue(source.contains(".overlay(alignment: .bottomTrailing)"))
        XCTAssertFalse(source.contains(".padding(.vertical, 20)"))
    }

    func testUnspecifiedTextColorUsesThemeWithoutChangingStoredOrExplicitColors() throws {
        let document = NSMutableAttributedString(string: "默认文字 自定义文字",
            attributes: [.font: EditorTextStyle.body.font])
        let custom = (document.string as NSString).range(of: "自定义文字")
        document.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: custom)
        let host = NSHostingView(rootView: RichTextEditor(document: document, cursorLocation: 0,
            controller: RichTextEditorController(), onChange: { _, _ in }, onActivate: {}, textColor: .systemPink))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 180)
        host.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(host.descendant(ofType: QuickNoteTextView.self))
        let manager = try XCTUnwrap(text.layoutManager)
        XCTAssertEqual(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor,
                       NSColor.systemPink, "默认字色应跟随界面主题，不能固定为黑字")
        XCTAssertNil(text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        XCTAssertNil(manager.temporaryAttribute(.foregroundColor, atCharacterIndex: custom.location, effectiveRange: nil))
        XCTAssertEqual(text.textStorage?.attribute(.foregroundColor, at: custom.location, effectiveRange: nil) as? NSColor,
                       NSColor.systemBlue, "保留用户明确指定的字色")
    }

    func testReferenceSidebarSearchMatchesTitleBodyAndTagsWithoutMutatingNotes() {
        let note = NoteRecord()
        note.title = "设计讨论"
        note.plainText = "下周进行prototype评审"
        note.tags = ["灵感", "工作"]
        XCTAssertTrue(NoteDrawerSearch.matches(note, query: "  设计  "))
        XCTAssertTrue(NoteDrawerSearch.matches(note, query: "PROTOTYPE"))
        XCTAssertTrue(NoteDrawerSearch.matches(note, query: "灵感"))
        XCTAssertTrue(NoteDrawerSearch.matches(note, query: "  "))
        XCTAssertFalse(NoteDrawerSearch.matches(note, query: "不存在"))
        XCTAssertEqual(note.title, "设计讨论")
        XCTAssertEqual(note.plainText, "下周进行prototype评审")
    }

    func testRenderReferenceRootWithLiveSearchAndCompactLayoutWithoutChangingDocument() async throws {
        let container = try ModelContainer(for: NoteRecord.self, NoteFolder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repository = NoteRepository(context: container.mainContext)
        let documents = NoteDocumentStore(root: FileManager.default.temporaryDirectory
            .appending(path: "QuickNote-Reference-\(UUID())"))
        let session = NoteSession(repository: repository, documents: documents)
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        let folder = try repository.createFolder(named: "工作资料")
        let sampleTitles = ["产品设计", "下周行动计划", "随手灵感", "会议纪要", "迭代清单"]
            + (6...22).map { "示例便签 \($0)" }
        for (index, title) in sampleTitles.enumerated() {
            let note = repository.createNote()
            note.title = title
            note.isPinned = index < 2
        }
        try session.createAndOpen()
        let sample = NSMutableAttributedString(string: "vibe coding\n把灵感随手记下，让想法有处可去。\n先展示成果，再说明为什么值得尝试。\n设计保持简洁，功能触手可及。\n参考好的案例，找到适合自己的工作方式。\n\n下一步：整理本周的行动清单。",
            attributes: [.font: EditorTextStyle.body.font])
        sample.addAttribute(.font, value: NSFont.systemFont(ofSize: 24, weight: .bold), range: NSRange(location: 0, length: 11))
        sample.append(NSAttributedString(string: "\n\n", attributes: [.font: EditorTextStyle.body.font]))
        let table = NSTextTable()
        table.numberOfColumns = 3
        for row in 0..<24 {
            for column in 0..<3 {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setWidth(4, type: .absoluteValueType, for: .padding)
                block.setBorderColor(.separatorColor)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                sample.append(NSAttributedString(string: "样例 \(row + 1)·\(column + 1)\n",
                    attributes: [.font: EditorTextStyle.body.font, .paragraphStyle: style]))
            }
        }
        session.update(document: sample, cursorLocation: 0)
        try session.flush()
        let baseline = NSAttributedString(attributedString: session.document)
        let root = RootNoteView(session: session, allNotes: repository.allNotes, searchNotes: repository.search,
            allFolders: repository.allFolders, createFolderAction: { _ in }, renameFolderAction: { _, _ in },
            deleteFolderAction: { _ in }, moveNoteAction: { _, _ in }, activateEditor: {},
            drawerVisibilityChanged: { _ in }, setWindowLocked: { _ in }, showAISettings: {})
        let host = NSHostingView(rootView: root.transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        })
        let window = NSPanel(contentRect: NSRect(x: 70, y: 70, width: 730, height: 520),
            styleMask: NotePanelController.windowStyleMask.union(.nonactivatingPanel), backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let output = FileManager.default.temporaryDirectory.appending(path: "quicknote-reference-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func snapshot(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let view = try XCTUnwrap(window.contentView?.superview)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appending(path: name))
        }
        func toggleSidebar() throws {
            window.makeKey()
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
            NSApp.sendEvent(key)
        }
        try await Task.sleep(for: .milliseconds(180))
        try toggleSidebar()
        try await Task.sleep(for: .milliseconds(220))
        try snapshot("reference-main.png")
        let text = try XCTUnwrap(host.descendant(ofType: QuickNoteTextView.self))
        XCTAssertEqual(text.enclosingScrollView?.magnification ?? 0, NoteChrome.editorDisplayScale, accuracy: 0.001)
        XCTAssertEqual(text.textContainerInset, NoteChrome.editorInsets)
        XCTAssertEqual(text.enclosingScrollView?.magnification, 1, "保持原便签字号，不自动放大")
        let editorFrame = try XCTUnwrap(text.enclosingScrollView).convert(text.enclosingScrollView!.bounds, to: host)
        XCTAssertGreaterThanOrEqual(editorFrame.minX, NotePanelController.drawerWidth + 24,
                                   "正文必须与分隔线之间保留真实布局边距")
        let textStart = text.convert(NSPoint(x: text.textContainerOrigin.x + (text.textContainer?.lineFragmentPadding ?? 0), y: 0), to: host).x
        XCTAssertLessThanOrEqual(textStart - NotePanelController.drawerWidth - 1, 30,
                                "正文离分隔线只需一层适度边距，不能叠加留白")
        XCTAssertGreaterThanOrEqual(editorFrame.height, host.bounds.height - NoteChrome.toolbarHeight - 1,
                                    "底部不能再为翻页控件牺牲正文和表格的可视高度")
        XCTAssertEqual(session.document, baseline, "显示布局不得重写正文格式")
        let nativeClose = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let closeFrame = nativeClose.convert(nativeClose.bounds, to: host)
        let closeCenterFromTop = host.isFlipped ? closeFrame.midY : host.bounds.maxY - closeFrame.midY
        XCTAssertEqual(closeCenterFromTop, NoteChrome.toolbarHeight / 2, accuracy: 3,
                       "顶部操作需与原生红黄绿按钮对齐")
        let headingWidth = ("全部便签" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)]).width
        XCTAssertLessThanOrEqual(headingWidth, NotePanelController.drawerWidth - 20 - 16 - 72 - 16,
                                "紧凑侧栏仍应完整容纳标题和操作")
        func pageButtons(in view: NSView) -> [NSButton] {
            let here = (view as? NSButton).map { button in
                ["上一条便签", "下一条便签"].contains(button.accessibilityLabel() ?? "") ? [button] : []
            } ?? []
            return here + view.subviews.flatMap { pageButtons(in: $0) }
        }
        let buttons = pageButtons(in: host)
        XCTAssertEqual(buttons.count, 2)
        let pager = buttons.reduce(NSRect.null) { $0.union($1.convert($1.bounds, to: nil)) }
        let scroll = try XCTUnwrap(text.enclosingScrollView)
        let scrollFrame = scroll.convert(scroll.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(pager.minX, scrollFrame.maxX, "翻页只能占右侧留白，不能覆盖正文或表格")
        text.scrollRangeToVisible(NSRange(location: sample.length - 2, length: 1))
        try await Task.sleep(for: .milliseconds(80))
        let manager = try XCTUnwrap(text.layoutManager)
        let textContainer = try XCTUnwrap(text.textContainer)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: sample.length - 2, length: 1), actualCharacterRange: nil)
        var finalCell = manager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        finalCell.origin.y += text.textContainerOrigin.y
        XCTAssertLessThanOrEqual(finalCell.maxY, text.visibleRect.maxY + 1, "最后一行表格应能完整滚入可视区")
        try snapshot("chrome-table-bottom.png")
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))
        let field = try XCTUnwrap(searchField(in: host, placeholder: "筛选便签"))
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        editor.insertText("灵感", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(field.stringValue, "灵感")
        try snapshot("reference-filtered.png")
        try sendSearchKey("\r", code: 36, to: window)
        let seededSearch = try await waitForSearchCondition {
            self.searchField(in: host)?.stringValue == "灵感" &&
                (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        XCTAssertTrue(seededSearch, "侧栏筛选框回车应打开全文搜索并带入输入词")
        try sendSearchKey("\u{1B}", code: 53, to: window)
        let closed = try await waitForSearchCondition { self.searchField(in: host) == nil }
        XCTAssertTrue(closed)
        window.makeFirstResponder(text)
        try toggleSidebar()
        try await Task.sleep(for: .milliseconds(220))
        window.setContentSize(NSSize(width: 520, height: 420))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, 520)
        try snapshot("reference-compact.png")
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(80))
        try snapshot("chrome-compact-dark.png")
        XCTAssertEqual(session.document, baseline)
        XCTAssertEqual(try repository.allFolders().map(\.id), [folder.id])
    }

    func testSearchPanelFocusSearchKeyboardAndRender() async throws {
        let folder = NoteFolder(name: "项目资料")
        let first = NoteRecord(), second = NoteRecord()
        first.title = "产品设计讨论"; first.folderID = folder.id; first.updatedAt = .now
        second.title = "下周行动计划"; second.updatedAt = .distantPast; second.folderID = folder.id
        second.plainText = "确定下一步行动并记录负责人。\n\n周五复盘时检查行动进度。"
        let noteEditor = QuickNoteTextView()
        noteEditor.string = second.plainText
        let controller = RichTextEditorController()
        controller.connect(noteEditor)
        var selected: UUID?
        var selectedQuery = ""
        var selectedMatchRange: NSRange?
        var closed = false
        var searched = ""
        let root = NoteSearchPanel(notes: [second, first], folders: [folder], theme: .system,
            search: { query in searched = query; return [second] },
            select: { note, query, snippet in
                selected = note.id
                selectedQuery = query
                selectedMatchRange = snippet?.matchRange
                if note.id == second.id, snippet != nil {
                    XCTAssertTrue(controller.revealSearchMatch(snippet, query: query))
                }
            }, close: { closed = true }, size: CGSize(width: 560, height: 420))
        let view = NSHostingView(rootView: root)
        let window = NSPanel(contentRect: NSRect(x: 180, y: 180, width: 560, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let focused = try await waitForSearchCondition { (window.firstResponder as? NSTextView)?.isFieldEditor == true }
        XCTAssertTrue(focused)
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView, "打开即聚焦搜索输入")
        XCTAssertTrue(fieldEditor.isFieldEditor)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize.width, 560, accuracy: 1)
        XCTAssertLessThan(view.fittingSize.height, 420)
        func press(_ characters: String, code: UInt16) throws {
            try sendSearchKey(characters, code: code, to: window)
        }
        try press("\r", code: 36)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(selected, first.id, "默认按最近更新排序，回车打开第一条")
        try press(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        try press(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        try press("\r", code: 36)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(selected, second.id, "向下到末条后不越界")
        try press(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126)
        try press(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126)
        try press("\r", code: 36)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(selected, first.id, "向上到首条后不越界")
        fieldEditor.insertText("行动", replacementRange: NSRange(location: 0, length: fieldEditor.string.utf16.count))
        let searchUpdated = try await waitForSearchCondition { searched == "行动" }
        XCTAssertTrue(searchUpdated)
        let body = second.plainText as NSString
        let firstHit = body.range(of: "行动")
        let secondHit = body.range(of: "行动", options: .backwards)
        XCTAssertNotEqual(firstHit, secondHit)
        try press("\r", code: 36)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(selected, second.id)
        XCTAssertEqual(selectedQuery, "行动", "沿用原有正文匹配定位")
        XCTAssertEqual(selectedMatchRange, firstHit)
        XCTAssertEqual(noteEditor.selectedRange(), firstHit)
        try press(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        try press("\r", code: 36)
        let selectedSecond = try await waitForSearchCondition { selectedMatchRange == secondHit }
        XCTAssertTrue(selectedSecond, "向下应选中同一便签的第二个片段")
        XCTAssertEqual(noteEditor.selectedRange(), secondHit, "回车应定位到第二处，不回退到第一处")
        try press(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126)
        try press("\r", code: 36)
        let selectedFirst = try await waitForSearchCondition { selectedMatchRange == firstHit }
        XCTAssertTrue(selectedFirst, "向上应返回第一个片段")
        XCTAssertEqual(noteEditor.selectedRange(), firstHit)
        try press("\u{1b}", code: 53)
        let dismissed = try await waitForSearchCondition { closed }
        XCTAssertTrue(dismissed)
    }

    func testFullTextSearchRendersBodyTitleOnlyAndEmptyStates() async throws {
        let folder = NoteFolder(name: "项目资料")
        let plan = NoteRecord()
        plan.title = "下周安排"
        plan.folderID = folder.id
        plan.plainText = "下周安排\n周一确认行动清单和负责人。\n\n周五复盘时检查行动进度。\n\n会后把行动记录归档。"
        let summary = NoteRecord()
        summary.title = "会议纪要"
        summary.plainText = "会议纪要\n产品、设计和研发同步了本周行动。"
        let review = NoteRecord()
        review.title = "复盘计划"
        review.folderID = folder.id
        review.plainText = "复盘计划\n周五下午同步本周进度。"
        let notes = [plan, summary, review]
        let output = URL(fileURLWithPath: "/tmp/QuickNoteSearchRedesignScreenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for (query, filename) in [("行动", "body-results.png"), ("复盘计划", "title-only.png"), ("不存在词", "no-results.png")] {
            var completedQuery: String?
            let panel = NoteSearchPanel(notes: notes, folders: [folder], theme: .system,
                search: { term in
                    completedQuery = term
                    return notes.filter { NoteDrawerSearch.matches($0, query: term) }
                }, select: { _, _, _ in }, close: {}, size: CGSize(width: 560, height: 420), initialQuery: query)
            let view = NSHostingView(rootView: panel)
            let window = NSPanel(contentRect: NSRect(x: 180, y: 180, width: 560, height: 420),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = view
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            defer {
                window.makeFirstResponder(nil)
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }

            let ready = try await waitForSearchCondition {
                completedQuery == query && self.searchField(in: view)?.stringValue == query &&
                    (window.firstResponder as? NSTextView)?.isFieldEditor == true
            }
            XCTAssertTrue(ready, "截图应使用已经执行查询的真实搜索面板")
            view.layoutSubtreeIfNeeded()
            let fittingSize = view.fittingSize
            XCTAssertEqual(fittingSize.width, 560, accuracy: 1)
            XCTAssertGreaterThan(fittingSize.height, 0)
            XCTAssertLessThan(fittingSize.height, 420, "少量结果或无结果时面板应按内容收紧")
            window.setContentSize(NSSize(width: fittingSize.width, height: ceil(fittingSize.height)))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appending(path: filename))
        }
    }

    func testBodyUsesRegularWeightAndUnboldDoesNotRestoreLight() {
        let regular = NSFont.systemFont(ofSize: 13, weight: .regular)
        XCTAssertEqual(EditorTextStyle.body.font, regular)
        let text = NSTextView()
        let controller = RichTextEditorController()
        controller.connect(text)
        text.typingAttributes[.font] = NSFont.systemFont(ofSize: 13, weight: .bold)
        controller.toggleBold()
        XCTAssertEqual(text.typingAttributes[.font] as? NSFont, regular)
    }

    func testSavedLightBodyMigratesOnceWithoutChangingOtherFormatting() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteDocumentStore(root: root)
        let id = UUID()
        let light = NSFont.systemFont(ofSize: 13, weight: .light)
        let source = NSMutableAttributedString(string: "正文 abc\n", attributes: [.font: light])
        source.append(NSAttributedString(string: "标题\n", attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .bold)]))
        source.append(NSAttributedString(string: "自定字体\n", attributes: [.font: NSFont(name: "HelveticaNeue-Light", size: 15)!]))
        source.append(NSAttributedString(string: "链接", attributes: [.font: light, .link: URL(string: "https://example.com")!]))
        let wrapper = try source.fileWrapper(from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        for marker in ["QuickNote-format-version", "QuickNote-heading-version"] {
            wrapper.addRegularFile(withContents: Data("1".utf8), preferredFilename: marker)
        }
        let url = root.appending(path: "\(id.uuidString).rtfd")
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        let originalBytes = try Data(contentsOf: url.appending(path: "TXT.rtf"))
        let before = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
        let loaded = try store.load(id: id)
        XCTAssertEqual(loaded.string, source.string)
        let body = try XCTUnwrap(loaded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(NSFontManager.shared.weight(of: body), NSFontManager.shared.weight(of: NSFont.systemFont(ofSize: 13)))
        for word in ["标题", "自定字体"] {
            let at = (source.string as NSString).range(of: word).location
            XCTAssertEqual(loaded.attribute(.font, at: at, effectiveRange: nil) as? NSFont, before.attribute(.font, at: at, effectiveRange: nil) as? NSFont)
        }
        XCTAssertNotNil(loaded.attribute(.link, at: loaded.length - 1, effectiveRange: nil))
        XCTAssertEqual(try Data(contentsOf: url.appending(path: "TXT.rtf")), originalBytes, "只读打开不覆写文件")
        let customized = NSMutableAttributedString(attributedString: loaded)
        customized.addAttribute(.font, value: light, range: NSRange(location: 0, length: 2))
        try store.save(customized, id: id)
        let reopened = try store.load(id: id)
        let chosen = try XCTUnwrap(reopened.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(NSFontManager.shared.weight(of: chosen), NSFontManager.shared.weight(of: light), "迁移后手动选细体应保留")
    }

    func testQuickNavigationWorksWithSidebarClosedAndPreservesDraft() async throws {
        let (container, repository, documents, session) = try safetyFixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        try session.appendPlainText("会议纪要")
        let first = try XCTUnwrap(session.currentNote)
        try session.createAndOpen()
        try session.appendPlainText("项目素材")
        let second = try XCTUnwrap(session.currentNote)
        let root = RootNoteView(session: session, allNotes: repository.allNotes, searchNotes: repository.search,
            allFolders: repository.allFolders, createFolderAction: { _ in }, renameFolderAction: { _, _ in },
            deleteFolderAction: { _ in }, moveNoteAction: { _, _ in }, activateEditor: {},
            drawerVisibilityChanged: { _ in XCTFail("快速切换不应展开侧栏") }, setWindowLocked: { _ in }, showAISettings: {})
        let view = NSHostingView(rootView: root)
        let window = NSPanel(contentRect: NSRect(x: 150, y: 150, width: 520, height: 300),
                             styleMask: NotePanelController.windowStyleMask.union(.nonactivatingPanel), backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(160))
        view.layoutSubtreeIfNeeded()
        window.makeFirstResponder(try XCTUnwrap(view.descendant(ofType: NSTextView.self)))
        window.makeKey()
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertLessThanOrEqual(view.fittingSize.width, 520)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/quicknote-navigation-toolbar.png"))
        session.update(document: NSAttributedString(string: "项目素材\n还未自动保存的内容"), cursorLocation: 0)
        func key(_ code: UInt16, _ scalar: Int) throws {
            window.makeKey()
            let value = String(UnicodeScalar(scalar)!)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: value,
                charactersIgnoringModifiers: value, isARepeat: false, keyCode: code))
            XCTAssertTrue(event.window === window)
            NSApp.sendEvent(event)
        }
        try key(124, NSRightArrowFunctionKey)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(session.currentNote?.id, first.id)
        XCTAssertEqual(try documents.load(id: second.id).string, "项目素材\n还未自动保存的内容")
        try key(123, NSLeftArrowFunctionKey)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(session.currentNote?.id, second.id)
        XCTAssertEqual(session.document.string, "项目素材\n还未自动保存的内容")
        try session.flush()
        window.orderOut(nil)
        window.contentView = nil
        try await Task.sleep(for: .milliseconds(80))
    }

    func testSearchShortcutWithSidebarClosedFocusesSearchAndEscapeRestoresEditorSelection() async throws {
        let (container, repository, documents, session) = try safetyFixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        try session.appendPlainText("合成便签\n这里有一段正文用于搜索。")
        let root = RootNoteView(session: session, allNotes: repository.allNotes, searchNotes: repository.search,
            allFolders: repository.allFolders, createFolderAction: { _ in }, renameFolderAction: { _, _ in },
            deleteFolderAction: { _ in }, moveNoteAction: { _, _ in }, activateEditor: {},
            drawerVisibilityChanged: { _ in XCTFail("搜索快捷键不应展开侧栏") },
            setWindowLocked: { _ in }, showAISettings: {})
        let host = NSHostingView(rootView: root)
        let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 520, height: 520),
                             styleMask: NotePanelController.windowStyleMask,
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer {
            try? session.flush()
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(160))
        let editor = try XCTUnwrap(host.descendant(ofType: QuickNoteTextView.self))
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.isKeyWindow)

        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        try sendSearchKey("F", code: 3, modifiers: [.command, .shift], to: window)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(searchField(in: host), "中文预编辑期间应把按键交还输入法")
        editor.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(editor.hasMarkedText())
        try session.flush()
        let compositionCommitted = try await waitForSearchCondition {
            editor.string.hasPrefix("中") && editor.string == session.document.string
        }
        XCTAssertTrue(compositionCommitted)

        try sendSearchKey("f", code: 3, modifiers: .command, to: window)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(searchField(in: host), "⌘F 不再由 QuickNote 的全文搜索接管")
        XCTAssertTrue(window.firstResponder === editor)
        let savedSelection = NSRange(location: 1, length: 3)
        editor.setSelectedRange(savedSelection)
        XCTAssertEqual(editor.selectedRange(), savedSelection)
        try sendSearchKey("F", code: 3, modifiers: [.command, .shift], to: window)
        let opened = try await waitForSearchCondition {
            self.searchField(in: host) != nil && (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        XCTAssertTrue(opened, "侧栏收起时 ⌘⇧F 仍应打开并聚焦全文搜索")
        let field = try XCTUnwrap(searchField(in: host))
        let frame = field.convert(field.bounds, to: host)
        let centerFromTop = host.isFlipped ? frame.midY - host.bounds.minY : host.bounds.maxY - frame.midY
        XCTAssertLessThan(centerFromTop, 100, "搜索头部应靠近窗口顶部")
        XCTAssertEqual(editor.selectedRange(), savedSelection)
        window.makeKey()
        XCTAssertTrue(window.isKeyWindow, "Esc 应发送给活动的搜索窗口")
        try sendSearchKey("\u{1B}", code: 53, to: window)
        let dismissed = try await waitForSearchCondition {
            self.searchField(in: host) == nil && window.firstResponder === editor
        }
        XCTAssertTrue(dismissed, "Esc 应关闭搜索并还原编辑器焦点")
        XCTAssertNil(searchField(in: host))
        XCTAssertTrue(window.firstResponder === editor, "窗口为 key：\(window.isKeyWindow)")
        XCTAssertEqual(editor.selectedRange(), savedSelection)
    }

    func testSearchShortcutDoesNotTriggerModifierOnlyScreenshot() {
        XCTAssertNil(QuickNoteShortcut.resolve(characters: "f", modifiers: .command))
        XCTAssertNil(QuickNoteShortcut.resolve(characters: "F", modifiers: [.command, .capsLock]))
        XCTAssertEqual(QuickNoteShortcut.resolve(characters: "F", modifiers: [.command, .shift]), .searchNotes)
        XCTAssertEqual(QuickNoteShortcut.resolve(characters: "F", modifiers: [.command, .shift, .capsLock]), .searchNotes)
        XCTAssertEqual(QuickNoteShortcut.resolve(characters: "b", modifiers: [.command]), .toggleSidebar)
        XCTAssertNil(QuickNoteShortcut.resolve(characters: "F", modifiers: [.command, .shift, .option]))
        var screenshot = CommandShiftDetector()
        XCTAssertFalse(screenshot.observe(.modifiersChanged(commandDown: true, shiftDown: true, hasOtherModifiers: false)))
        XCTAssertTrue(screenshot.isTracking)
        XCTAssertFalse(screenshot.observe(.otherInput))
        XCTAssertFalse(screenshot.observe(.modifiersChanged(commandDown: false, shiftDown: false, hasOtherModifiers: false)))
    }

    func testQuestionSuffixSuggestsAskForBothQuestionMarks() {
        XCTAssertTrue(NoteSearchMode.suggestsAsking(for: "活动时间？ "))
        XCTAssertTrue(NoteSearchMode.suggestsAsking(for: "When is it?"))
        XCTAssertFalse(NoteSearchMode.suggestsAsking(for: "有个问题？明天再问"))
        XCTAssertFalse(NoteSearchMode.suggestsAsking(for: ""))
    }

    func testAskModeTabKeepsQuestionAndRestoresEditorOnEscape() async throws {
        let (container, repository, documents, session) = try safetyFixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        try session.appendPlainText("合成便签\n活动地点在会议室。")
        let suiteName = "QuickNoteTests.searchMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let ask = NoteAskController(search: { _, _ in .init(mode: .keyword, hits: []) },
            sourceLocation: { _ in nil }, resolveModel: { _ in
                NoteAskModel(destination: "本机", isAvailable: false, confirm: { true },
                    start: { _, _ in AsyncThrowingStream { $0.finish() } })
            }, retrievalDelay: .zero)
        let root = RootNoteView(session: session, allNotes: repository.allNotes, searchNotes: repository.search,
            allFolders: repository.allFolders, createFolderAction: { _ in }, renameFolderAction: { _, _ in },
            deleteFolderAction: { _ in }, moveNoteAction: { _, _ in }, activateEditor: {},
            drawerVisibilityChanged: { _ in }, setWindowLocked: { _ in }, showAISettings: {},
            askController: ask)
        let host = NSHostingView(rootView: root.defaultAppStorage(defaults))
        let window = NSPanel(contentRect: NSRect(x: 100, y: 100, width: 520, height: 520),
                             styleMask: NotePanelController.windowStyleMask,
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer {
            try? session.flush()
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(160))
        let editor = try XCTUnwrap(host.descendant(ofType: QuickNoteTextView.self))
        XCTAssertTrue(window.makeFirstResponder(editor))
        let selection = NSRange(location: 1, length: 3)
        editor.setSelectedRange(selection)
        try sendSearchKey("F", code: 3, modifiers: [.command, .shift], to: window)
        let opened = try await waitForSearchCondition {
            self.searchField(in: host) != nil && (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        XCTAssertTrue(opened)
        let field = try XCTUnwrap(searchField(in: host))
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        fieldEditor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                                  replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(fieldEditor.hasMarkedText())
        try sendSearchKey("\t", code: 48, to: window)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(searchField(in: host, placeholder: "向便签提问"))
        XCTAssertNotEqual(defaults.string(forKey: "noteSearch.mode"), NoteSearchMode.ask.rawValue)

        field.selectText(nil)
        let focusedField = try XCTUnwrap(window.firstResponder as? NSTextView)
        focusedField.unmarkText()
        focusedField.insertText("活动地点？", replacementRange: NSRange(location: 0, length: focusedField.string.utf16.count))
        let queryReady = try await waitForSearchCondition { field.stringValue == "活动地点？" }
        XCTAssertTrue(queryReady)
        try sendSearchKey("\t", code: 48, to: window)
        let asked = try await waitForSearchCondition {
            self.searchField(in: host, placeholder: "向便签提问")?.stringValue == "活动地点？" &&
                (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        XCTAssertTrue(asked)
        XCTAssertEqual(defaults.string(forKey: "noteSearch.mode"), NoteSearchMode.ask.rawValue)

        try sendSearchKey("\t", code: 48, to: window)
        let returnedToSearch = try await waitForSearchCondition {
            self.searchField(in: host)?.stringValue == "活动地点？"
        }
        XCTAssertTrue(returnedToSearch, "Tab 搜索应保留同一输入")
        try sendSearchKey("\t", code: 48, to: window)
        let returnedToAsk = try await waitForSearchCondition {
            self.searchField(in: host, placeholder: "向便签提问")?.stringValue == "活动地点？"
        }
        XCTAssertTrue(returnedToAsk)

        window.makeKey()
        try sendSearchKey("\u{1B}", code: 53, to: window)
        let dismissed = try await waitForSearchCondition { window.firstResponder === editor }
        XCTAssertTrue(dismissed)
        XCTAssertEqual(editor.selectedRange(), selection)
        try sendSearchKey("F", code: 3, modifiers: [.command, .shift], to: window)
        let reopened = try await waitForSearchCondition {
            self.searchField(in: host, placeholder: "向便签提问") != nil &&
                (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        XCTAssertTrue(reopened, "快捷键再次打开时恢复上次使用的提问模式")
    }

    func testImportPickerRequiresTitleOnlyForNewNote() throws {
        let existing = NoteRecord()
        existing.title = "已有便签"
        DispatchQueue.main.async {
            guard let window = NSApp.modalWindow, let view = window.contentView else {
                XCTFail("没有显示导入选择器")
                NSApp.abortModal()
                return
            }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let views = descendants(view)
            guard let title = views.compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "为这批内容起个标题" }),
                  let destination = views.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles.contains("新建便签") }),
                  let save = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "导入" }) else {
                XCTFail("缺少标题、目标或确认操作")
                NSApp.abortModal()
                return
            }
            XCTAssertFalse(save.isEnabled)
            destination.selectItem(at: 1)
            NSApp.sendAction(destination.action!, to: destination.target, from: destination)
            XCTAssertTrue(save.isEnabled)
            XCTAssertTrue(title.isHidden)
            destination.selectItem(at: 0)
            NSApp.sendAction(destination.action!, to: destination.target, from: destination)
            XCTAssertFalse(save.isEnabled)
            XCTAssertFalse(title.isHidden)
            title.stringValue = "项目素材"
            title.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: title))
            XCTAssertTrue(save.isEnabled)
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/quicknote-import-title.png"))
            }
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
        }
        let choice = try XCTUnwrap(NoteImportPicker.choose(notes: [existing], defaultID: nil, revision: nil))
        XCTAssertEqual(choice.position, .newNote)
        XCTAssertEqual(choice.newTitle, "项目素材")
    }

    func testImportPickerPreselectsTheIntendedNoteWhenTitlesMatch() throws {
        let first = NoteRecord()
        let second = NoteRecord()
        first.title = "同名便签"
        second.title = first.title

        DispatchQueue.main.async {
            if NSApp.modalWindow == nil {
                XCTFail("没有显示导入选择器")
                NSApp.abortModal()
            } else {
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
            }
        }

        let choice = try XCTUnwrap(NoteImportPicker.choose(
            notes: [first, second], defaultID: first.id, revision: 7,
            preselectedDestination: AIResultDestination(id: second.id, title: second.title)
        ))
        XCTAssertEqual(choice.noteID, second.id)
        XCTAssertEqual(choice.position, .end)
    }

    func testLegacyUnstyledImagesHaveVisibleGapOnScreen() throws {
        let document = NSMutableAttributedString()
        for color in [NSColor.systemBlue, NSColor.systemTeal] {
            let image = NSImage(size: NSSize(width: 240, height: 64))
            image.lockFocus()
            color.setFill()
            NSRect(x: 0, y: 0, width: 240, height: 64).fill()
            image.unlockFocus()
            let wrapper = FileWrapper(regularFileWithContents: try XCTUnwrap(image.tiffRepresentation))
            wrapper.preferredFilename = "image.tiff"
            document.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            document.append(NSAttributedString(string: "\n"))
        }
        let scroll = QuickNoteTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 280, height: 220)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        let data = try document.data(from: NSRange(location: 0, length: document.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let reopened = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                              documentAttributes: nil)
        text.textStorage?.setAttributedString(reopened)
        RichTextEditorController().prepareFileAttachments(in: text, normalizeImportedContent: false)
        let layout = try XCTUnwrap(text.layoutManager)
        let container = try XCTUnwrap(text.textContainer)
        layout.ensureLayout(for: container)
        let first = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: NSRange(location: 0, length: 1), actualCharacterRange: nil), in: container)
        let second = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: NSRange(location: 2, length: 1), actualCharacterRange: nil), in: container)
        XCTAssertGreaterThanOrEqual(second.minY - first.maxY, 12)
        XCTAssertEqual(text.string, document.string, "修复老便签只补样式，不增加空行")
    }

    func testNamedMediaImportSeparatesBlocksAndRejectsEmptyTitleBeforeCreating() throws {
        let (container, repository, documents, session) = try safetyFixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        let content = NSMutableAttributedString()
        for name in ["one.png", "two.mov", "three.aiff"] {
            let wrapper = FileWrapper(regularFileWithContents: Data(name.utf8))
            wrapper.preferredFilename = name
            content.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            content.append(NSAttributedString(string: "\n"))
        }
        let count = try repository.allNotes().count
        XCTAssertThrowsError(try session.importContent(content, into: nil, at: .newNote, title: " \n "))
        XCTAssertEqual(try repository.allNotes().count, count)
        _ = try session.importContent(content, into: nil, at: .newNote, title: " 项目素材 ")
        let note = try XCTUnwrap(session.currentNote)
        XCTAssertEqual(note.title, "项目素材")
        XCTAssertEqual(session.document.string, "项目素材\n" + content.string)
        try session.importContent(content, into: note.id, at: .end)
        let saved = try documents.load(id: note.id)
        var names: [String] = []
        saved.enumerateAttribute(.attachment, in: NSRange(location: 0, length: saved.length)) { value, range, _ in
            guard let attachment = value as? NSTextAttachment, let wrapper = attachment.fileWrapper else { return }
            let name = wrapper.preferredFilename ?? wrapper.filename ?? ""
            names.append(name)
            XCTAssertTrue(["one.png", "two.mov", "three.aiff"].map { Data($0.utf8) }.contains(wrapper.regularFileContents ?? Data()))
            let style = saved.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertGreaterThanOrEqual(style?.paragraphSpacing ?? 0, 12)
        }
        XCTAssertEqual(names.count, 6)
        XCTAssertEqual((saved.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 24)
    }

    func testPlainAISectionHeadingsHaveHierarchyWithoutChangingWords() throws {
        let source = "截图核心内容总结\n\n一、仍未确认完整上线的事项\n闭环不完整：待办完成后需要写回 ERP。\n\n二、最终判断\n当前平台仍有需要完善的功能。"
        let result = NoteMarkdownImporter.richText(from: source, asDocumentStart: false)
        let string = result.string as NSString
        XCTAssertEqual(result.string, source)
        for title in ["截图核心内容总结", "一、仍未确认完整上线的事项", "二、最终判断"] {
            let font = try XCTUnwrap(result.attribute(.font, at: string.range(of: title).location, effectiveRange: nil) as? NSFont)
            XCTAssertGreaterThan(font.pointSize, EditorTextStyle.body.font.pointSize)
        }
        let body = try XCTUnwrap(result.attribute(.font, at: string.range(of: "闭环不完整").location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(body, EditorTextStyle.body.font)
    }

    func testHeadingDefaultsPreserveListsCodeLinksAndManualFormatting() {
        let text = "1. 普通任务\n2. 另一个任务\n\n一、列表项\n二、列表项\n\n```\n一、代码示例\n代码内容\n```\n\n一、链接标题\n链接说明\n\n二、自定字号\n正文\n"
        let source = NSMutableAttributedString(string: text, attributes: [.font: EditorTextStyle.body.font])
        source.addAttribute(.link, value: URL(string: "https://example.com")!, range: (text as NSString).range(of: "一、链接标题"))
        source.addAttribute(.font, value: NSFont.systemFont(ofSize: 31), range: (text as NSString).range(of: "二、自定字号"))
        source.append(NSAttributedString(attachment: NSTextAttachment()))
        let result = NoteHeadingNormalizer.normalized(source, promoteFirstLine: true)
        XCTAssertTrue(result.isEqual(to: source), "普通列表、代码、链接、手动字号与附件不参与自动标题识别")
        let title = NoteHeadingNormalizer.normalized(NSAttributedString(string: "新的便签\n这里是正文。"), promoteFirstLine: true)
        XCTAssertEqual((title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 24)
    }

    func testHeadingMigrationIsReadOnlyAndRespectsSubsequentManualChanges() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteDocumentStore(root: root)
        let id = UUID()
        let source = NSAttributedString(string: "截图核心内容总结\n\n一、工作进展\n这里是正文。", attributes: [.font: EditorTextStyle.body.font])
        let wrapper = try source.fileWrapper(from: NSRange(location: 0, length: source.length),
                                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        wrapper.addRegularFile(withContents: Data("1".utf8), preferredFilename: "QuickNote-format-version")
        let url = root.appending(path: "\(id).rtfd")
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        let before = try Data(contentsOf: url.appending(path: "TXT.rtf"))
        let migrated = try store.load(id: id)
        XCTAssertEqual(migrated.string, source.string)
        XCTAssertEqual((migrated.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 18)
        XCTAssertEqual(try Data(contentsOf: url.appending(path: "TXT.rtf")), before)
        let manual = NSMutableAttributedString(attributedString: migrated)
        manual.addAttribute(.font, value: EditorTextStyle.body.font, range: NSRange(location: 0, length: manual.length))
        try store.save(manual, id: id)
        let reopened = try store.load(id: id)
        XCTAssertEqual((reopened.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 13,
                       "用户改回正文并保存后，不得重复强制套用标题")
    }

    func testDesktopPetDropRequiresExplicitImport() throws {
        let (container, repository, documents, session) = try safetyFixture()
        defer { withExtendedLifetime(container) {}; try? FileManager.default.removeItem(at: documents.root) }
        try session.createAndOpen()
        let original = try XCTUnwrap(session.currentNote)
        try session.appendPlainText("original")
        try session.createAndOpen()
        let target = try XCTUnwrap(session.currentNote)
        try session.open(original)
        let name = "QuickNote-Pet-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let pet = DesktopPetController(defaults: defaults)
        defer { pet.stop() }
        pet.setSoundEnabled(false)
        pet.setEnabled(true)
        var analyses = 0
        let drops = DesktopPetDropController(session: session, allNotes: repository.allNotes, pet: pet, showImage: { _ in analyses += 1 })
        pet.canReceiveDrop = { [weak drops] in drops?.pending == nil }
        pet.onHidden = { [weak drops] in drops?.cancel() }
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("dropped material", forType: .string)
        let payload = try DesktopPetDrop.read(from: board)
        drops.present(payload)
        XCTAssertNotNil(drops.pending)
        XCTAssertEqual(try documents.load(id: original.id).string, "original")
        XCTAssertEqual(try documents.load(id: target.id).string, "")
        drops.cancel()
        XCTAssertNil(drops.pending)
        XCTAssertEqual(try documents.load(id: target.id).string, "")
        drops.present(payload)
        XCTAssertThrowsError(try drops.confirmImport(.init(noteID: UUID(), position: .end, startsDocument: false, revision: nil)))
        XCTAssertNotNil(drops.pending, "导入失败保留素材供重新选择")
        try drops.confirmImport(.init(noteID: target.id, position: .end, startsDocument: true, revision: nil))
        XCTAssertNil(drops.pending)
        XCTAssertEqual(try documents.load(id: original.id).string, "original")
        XCTAssertEqual(try documents.load(id: target.id).string, "dropped material")
        XCTAssertEqual((try documents.load(id: target.id).attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 24)
        XCTAssertEqual(analyses, 0)
        try drops.confirmImport(.init(noteID: target.id, position: .end, startsDocument: false, revision: nil))
        XCTAssertEqual(try documents.load(id: target.id).string, "dropped material", "不能重复保存同一批")
        board.clearContents()
        board.setData(try XCTUnwrap(pet.image(clip: "greeting", direction: "right", frame: 0)?.tiffRepresentation), forType: .tiff)
        let imageDrop = try DesktopPetDrop.read(from: board)
        drops.present(DesktopPetDrop(content: imageDrop.content, image: imageDrop.image,
                                    summary: "这是一张名称比较长的项目讨论截图-用来检查预览和按钮是否发生挤压或截断.png"))
        let preview = try XCTUnwrap(drops.popover.contentViewController?.view)
        preview.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(preview as? NSStackView)
        for view in stack.arrangedSubviews {
            XCTAssertGreaterThan(view.frame.width, 0)
            XCTAssertGreaterThan(view.frame.height, 0)
            XCTAssertTrue(preview.bounds.contains(view.frame), "确认框中的元素不能溢出或截断")
        }
        for (first, second) in zip(stack.arrangedSubviews, stack.arrangedSubviews.dropFirst()) {
            XCTAssertFalse(first.frame.intersects(second.frame), "素材、提示、操作按钮不能重叠")
        }
        XCTAssertLessThanOrEqual(preview.frame.width, 292)
        XCTAssertLessThan(preview.frame.height, 220)
        let actions = try XCTUnwrap(stack.arrangedSubviews.last as? NSStackView)
        let primary = try XCTUnwrap(actions.arrangedSubviews.first as? NSButton)
        XCTAssertGreaterThanOrEqual(primary.frame.height, 32, "非激活窗口的主操作不能被压缩成细条")
        XCTAssertEqual(primary.keyEquivalent, "\r")
        XCTAssertEqual(primary.accessibilityRole(), .button)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            preview.appearance = NSAppearance(named: appearance)
            let bitmap = try XCTUnwrap(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
            preview.cacheDisplay(in: preview.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/quicknote-pet-drop-\(appearance.rawValue).png"))
        }
        XCTAssertEqual(analyses, 0)
        drops.analyzeImage()
        XCTAssertEqual(analyses, 1, "只有明确选择识别才打开图片预览")
        XCTAssertNil(drops.pending)
        XCTAssertEqual(try documents.load(id: target.id).string, "dropped material")
        drops.present(payload)
        pet.setEnabled(false)
        XCTAssertNil(drops.pending, "隐藏桌宠也要释放未确认的内容")
    }

    func testProductMalformedFenceRemainsLiteral() {
        let source = "```swift\n**not closed**\n- [x] literal"
        let result = NoteMarkdownImporter.richText(from: source, asDocumentStart: false)
        XCTAssertEqual(result.string, source)
        XCTAssertEqual(result.attachmentCount, 0)
    }

    func testProductCaretBoldUsesTypingFontInsteadOfAdjacentRun() {
        let text = QuickNoteTextView()
        text.textStorage?.setAttributedString(NSAttributedString(string: "bold", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold)]))
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.typingAttributes[.font] = EditorTextStyle.body.font
        let controller = RichTextEditorController()
        controller.connect(text)
        controller.toggleBold()
        XCTAssertEqual(controller.selectionState.bold, .on)
    }

    func testProductMultilinePasteIntoExistingTitleUsesBodyAfterFirstParagraph() {
        let pasted = NotePasteNormalizer.normalized(NSAttributedString(string: "first\nsecond"),
            destinationFont: EditorTextStyle.title.font, replacesWholeDocument: false)
        XCTAssertEqual((pasted.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 24)
        XCTAssertEqual((pasted.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)?.pointSize, 13)
    }

    func testProductChecklistRehydrationPreservesUserParagraphAttributes() throws {
        let source = NSMutableAttributedString(attributedString: NoteMarkdownImporter.richText(from: "- [x]", asDocumentStart: false))
        let text = QuickNoteTextView()
        text.string = "task"
        let controller = RichTextEditorController()
        controller.connect(text)
        controller.insertChecklistItem()
        source.setAttributedString(text.attributedString())
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 17
        source.addAttributes([.paragraphStyle: style, .font: NSFont.systemFont(ofSize: 31)], range: NSRange(location: 0, length: 1))
        text.textStorage?.setAttributedString(source)
        controller.prepareChecklistAttachments(in: text)
        let actual = text.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(actual?.paragraphSpacingBefore, 17)
        XCTAssertEqual((text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 31)
    }

    func testProductNativeBoldCommandWorksOnLightBody() throws {
        let text = QuickNoteTextView()
        text.textStorage?.setAttributedString(NSAttributedString(string: "body", attributes: [.font: EditorTextStyle.body.font]))
        text.setSelectedRange(NSRange(location: 0, length: 4))
        let controller = RichTextEditorController()
        controller.connect(text)
        let manager = NSFontManager.shared
        let previousTarget = manager.target
        let previousAction = manager.action
        defer { manager.target = previousTarget; manager.action = previousAction }
        manager.target = text
        manager.action = #selector(NSTextView.changeFont(_:))
        manager.setSelectedFont(EditorTextStyle.body.font, isMultiple: false)
        let item = NSMenuItem()
        item.tag = Int(NSFontTraitMask.boldFontMask.rawValue)
        manager.addFontTrait(item)
        XCTAssertTrue((text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    func testProductPlainMultilinePasteUsesOnlyOneTitleAndBodyTypingFont() {
        let text = QuickNoteTextView()
        text.typingAttributes[.font] = EditorTextStyle.title.font
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("title\nbody", forType: .string)
        XCTAssertTrue(text.readSelection(from: board))
        XCTAssertEqual((text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 24)
        XCTAssertEqual((text.textStorage?.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)?.pointSize, 13)
        XCTAssertEqual((text.typingAttributes[.font] as? NSFont)?.pointSize, 13)
    }

    func testProductLegacyMigrationStopsAfterCurrentFormatSave() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteDocumentStore(root: root)
        let id = UUID()
        let old = NSAttributedString(string: "legacy", attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .bold)])
        let wrapper = try old.fileWrapper(from: NSRange(location: 0, length: old.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let url = root.appending(path: "\(id.uuidString).rtfd")
        try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
        let originalBytes = try Data(contentsOf: url.appending(path: "TXT.rtf"))
        let loaded = try store.load(id: id)
        XCTAssertEqual((loaded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 24)
        XCTAssertEqual(try Data(contentsOf: url.appending(path: "TXT.rtf")), originalBytes, "read must not write the legacy package")
        let changed = NSMutableAttributedString(attributedString: loaded)
        changed.addAttribute(.font, value: NSFont.systemFont(ofSize: 26, weight: .bold), range: NSRange(location: 0, length: changed.length))
        try store.save(changed, id: id)
        let reopened = try store.load(id: id)
        XCTAssertEqual((reopened.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 26)
        XCTAssertTrue((reopened.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    func testProductAttachmentTemporaryCopiesAreBoundedAndRejectSymlinkRoot() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = root.appending(path: "QuickNote-Attachments")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let foreign = owned.appending(path: "unrelated.txt")
        try Data("keep".utf8).write(to: foreign)
        for index in 0..<22 {
            let copy = try AttachmentTemporaryCopies.write(Data("copy-\(index)".utf8), filename: "../file.txt", temporaryDirectory: root)
            XCTAssertTrue(copy.path.hasPrefix(owned.path + "/"))
            XCTAssertEqual(copy.lastPathComponent, "file.txt")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: owned.path).count, 21)
        XCTAssertEqual(try Data(contentsOf: foreign), Data("keep".utf8))
        let other = root.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let parent = root.appending(path: "symlink-test")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: parent.appending(path: "QuickNote-Attachments"), withDestinationURL: other)
        XCTAssertThrowsError(try AttachmentTemporaryCopies.write(Data(), filename: "file", temporaryDirectory: parent))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    func testProductSelectionCallbackDoesNotReportDocumentEdit() throws {
        var cursor = -1
        var edits = 0
        let controller = RichTextEditorController()
        let editor = RichTextEditor(document: NSAttributedString(string: "cursor"), cursorLocation: 0,
            controller: controller, onChange: { _, _ in edits += 1 }, onActivate: {},
            onSelectionChange: { cursor = $0 })
        let coordinator = editor.makeCoordinator()
        let text = QuickNoteTextView()
        text.string = "cursor"
        text.delegate = coordinator
        controller.connect(text)
        text.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertEqual(cursor, 4)
        XCTAssertEqual(edits, 0)
    }

    func testProductFindTextSelectsAndScrollsLocalizedMatch() {
        let text = QuickNoteTextView()
        text.string = "before CAFÉ after café"
        let controller = RichTextEditorController()
        controller.connect(text)
        XCTAssertTrue(controller.findText("cafe"))
        XCTAssertEqual(text.selectedRange(), NSRange(location: 7, length: 4))
        XCTAssertFalse(controller.findText("missing"))
        XCTAssertEqual(text.selectedRange(), NSRange(location: 7, length: 4))
        XCTAssertFalse(controller.findText(""))
    }

    func testSearchRevealsSecondOccurrenceAfterImageAndChecklist() throws {
        let image = NSTextAttachment()
        image.image = NSImage(size: NSSize(width: 12, height: 12))
        let source = NSMutableAttributedString(attributedString: NSAttributedString(attachment: image))
        source.append(NSAttributedString(string: "\n第一处命中\n🙂 第二处命中"))

        let text = QuickNoteTextView()
        let storage = try XCTUnwrap(text.textStorage)
        storage.setAttributedString(source)
        let controller = RichTextEditorController()
        controller.connect(text)
        let first = (text.string as NSString).range(of: "命中")
        text.setSelectedRange(NSRange(location: first.location, length: 0))
        controller.insertChecklistItem()

        let baseline = NSAttributedString(attributedString: storage)
        let expected = (baseline.string as NSString).range(of: "命中", options: .backwards)
        let attachments = (baseline.string as NSString).substring(to: expected.location).filter { $0 == "\u{FFFC}" }
        XCTAssertEqual(attachments.count, 2)
        let matches = NoteSearchText.snippets(for: "命中", in: baseline.string)
        XCTAssertEqual(matches.count, 2)
        let second = try XCTUnwrap(matches.last)
        XCTAssertEqual(second.matchRange, expected)
        XCTAssertTrue(controller.revealSearchMatch(second, query: "命中"))
        XCTAssertEqual(text.selectedRange(), expected)
        XCTAssertEqual(storage, baseline, "定位只改变选区，不改写正文和附件")
    }

    func testSearchFallsBackWhenOriginalTextChangesAndPreservesSelectionWithoutMatch() throws {
        let original = "前甲命中\n后乙命中"
        let second = try XCTUnwrap(NoteSearchText.snippets(for: "命中", in: original).last)
        let text = QuickNoteTextView()
        let controller = RichTextEditorController()
        text.string = "正文命中\n异处命中"
        controller.connect(text)

        XCTAssertEqual((text.string as NSString).substring(with: second.matchRange), "命中",
                       "旧范围仍看似有效，但所在正文已变化")
        XCTAssertTrue(controller.revealSearchMatch(second, query: "命中"))
        XCTAssertEqual(text.selectedRange(), NSRange(location: 2, length: 2))

        text.string = "新的内容"
        let selection = NSRange(location: 1, length: 2)
        text.setSelectedRange(selection)
        XCTAssertFalse(controller.revealSearchMatch(second, query: "命中"))
        XCTAssertEqual(text.selectedRange(), selection)
    }

    func testAskCitationUsesUTF16RangeAfterImageChecklistAndEmoji() throws {
        let image = NSTextAttachment()
        image.image = NSImage(size: NSSize(width: 12, height: 12))
        let source = NSMutableAttributedString(attributedString: NSAttributedString(attachment: image))
        source.append(NSAttributedString(string: "\n🙂 第一段\n🙂 引用正文"))
        let editor = QuickNoteTextView()
        let storage = try XCTUnwrap(editor.textStorage)
        storage.setAttributedString(source)
        let controller = RichTextEditorController()
        controller.connect(editor)
        let first = (editor.string as NSString).range(of: "第一段")
        editor.setSelectedRange(NSRange(location: first.location, length: 0))
        controller.insertChecklistItem()

        let baseline = NSAttributedString(attributedString: storage)
        let snapshot = NoteIndexSnapshot(noteID: UUID(), title: "合成引用", text: baseline.string, revision: 3)
        let expected = (baseline.string as NSString).range(of: "🙂 引用正文", options: .backwards)
        let attachments = (baseline.string as NSString).substring(to: expected.location).filter { $0 == "\u{FFFC}" }
        XCTAssertEqual(attachments.count, 2)
        let citation = try XCTUnwrap(NoteChunker.chunks(for: snapshot).last)
        XCTAssertEqual(citation.range, expected)
        XCTAssertTrue(controller.revealAskCitation(citation, revision: 3, question: "引用在哪里？"))
        XCTAssertEqual(editor.selectedRange(), expected)
        XCTAssertEqual(storage, baseline)
    }

    func testAskCitationRejectsStaleRevisionAndFingerprintAndFallsBackToExcerptKeywords() throws {
        let original = "第一行\nSpring launch is in June.\nSpring launch is in June."
        let snapshot = NoteIndexSnapshot(noteID: UUID(), title: "合成引用", text: original, revision: 4)
        let citation = try XCTUnwrap(NoteChunker.chunks(for: snapshot).last)
        let editor = QuickNoteTextView()
        let controller = RichTextEditorController()
        editor.string = original
        controller.connect(editor)
        let firstExcerpt = (original as NSString).range(of: citation.text)
        XCTAssertNotEqual(citation.range, firstExcerpt)

        XCTAssertTrue(controller.revealAskCitation(citation, revision: 5, question: "launch?"))
        XCTAssertEqual(editor.selectedRange(), firstExcerpt, "revision 改变后应回退到摘录搜索")
        editor.string = original.replacingOccurrences(of: "第一行", with: "新一行")
        XCTAssertTrue(controller.revealAskCitation(citation, revision: 4, question: "launch?"))
        XCTAssertEqual(editor.selectedRange(), firstExcerpt, "旧范围仍能匹配文字，指纹变化也应回退")

        editor.string = "Plan update: launch delayed."
        XCTAssertTrue(controller.revealAskCitation(citation, revision: 5, question: "launch?"))
        XCTAssertEqual(editor.selectedRange(), (editor.string as NSString).range(of: "launch"))
        editor.string = "无关正文"
        let saved = NSRange(location: 1, length: 2)
        editor.setSelectedRange(saved)
        XCTAssertFalse(controller.revealAskCitation(citation, revision: 5, question: "launch?"))
        XCTAssertEqual(editor.selectedRange(), saved)
    }

    func testProgrammaticEditorRenderingDoesNotPublishCursorOrCollapseUserSelection() throws {
        var reportedCursors: [Int] = []
        let controller = RichTextEditorController()
        let noteID = UUID()
        func editor() -> RichTextEditor {
            RichTextEditor(document: NSAttributedString(string: "Title\nhttps://example.com"), cursorLocation: 8,
                controller: controller, onChange: { _, _ in XCTFail("Rendering is not an edit") },
                onActivate: {}, noteID: noteID, onSelectionChange: { reportedCursors.append($0) })
        }
        let host = NSHostingView(rootView: editor())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        XCTAssertTrue(reportedCursors.isEmpty, "Restoring the saved cursor must not write back into SwiftData")
        text.setSelectedRange(NSRange(location: 8, length: 5))
        XCTAssertEqual(reportedCursors.last, 8, "Real selections must still reach the owner")
        reportedCursors.removeAll()
        host.rootView = editor()
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(reportedCursors.isEmpty)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 8, length: 5))
        withExtendedLifetime(window) {}
    }

    func testProductExternalRevisionRecordsOneUndoWithoutCrossNoteHistory() throws {
        let controller = RichTextEditorController()
        let noteID = UUID()
        func editor(_ content: String, revision: Int, id: UUID) -> RichTextEditor {
            RichTextEditor(document: NSAttributedString(string: content), cursorLocation: content.utf16.count,
                controller: controller, onChange: { _, _ in }, onActivate: {}, noteID: id,
                externalEditRevision: revision)
        }
        let host = NSHostingView(rootView: editor("original", revision: 0, id: noteID))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        host.rootView = editor("original import", revision: 1, id: noteID)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(text.string, "original import")
        XCTAssertTrue(text.undoManager?.canUndo == true)
        controller.undo()
        XCTAssertEqual(text.string, "original")
        host.rootView = editor("different note", revision: 2, id: UUID())
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(text.undoManager?.canUndo == true)
        withExtendedLifetime(window) {}
    }

    func testProductImageContextMenuIncludesSaveDeleteAndSpacing() throws {
        let text = QuickNoteTextView()
        let wrapper = FileWrapper(regularFileWithContents: try XCTUnwrap(testImage().tiffRepresentation))
        wrapper.preferredFilename = "image.tiff"
        text.textStorage?.setAttributedString(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        let menu = try XCTUnwrap(text.attachmentMenu(at: 0))
        for title in ["复制图片", "粘贴", "上下间距", "图片另存为…", "删除图片"] {
            XCTAssertNotNil(menu.item(withTitle: title), title)
        }
        wrapper.preferredFilename = "file.txt"
        let file = FileWrapper(regularFileWithContents: Data("file".utf8))
        file.preferredFilename = "file.txt"
        text.textStorage?.setAttributedString(NSAttributedString(attachment: NSTextAttachment(fileWrapper: file)))
        let fileMenu = try XCTUnwrap(text.attachmentMenu(at: 0))
        for title in ["打开副本（外部修改不同步）…", "附件另存为…", "替换附件…", "删除附件"] {
            XCTAssertNotNil(fileMenu.item(withTitle: title), title)
        }
    }

    func testProductAttachmentRenderingPreservesExplicitParagraphSpacing() throws {
        let text = QuickNoteTextView()
        let wrapper = FileWrapper(regularFileWithContents: try XCTUnwrap(testImage().tiffRepresentation))
        wrapper.preferredFilename = "image.tiff"
        let document = NSMutableAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 17
        document.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: 1))
        text.textStorage?.setAttributedString(document)
        let controller = RichTextEditorController()
        controller.prepareFileAttachments(in: text, normalizeImportedContent: false)
        let actual = text.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(actual?.paragraphSpacing, 0)
        XCTAssertEqual(actual?.paragraphSpacingBefore, 17)
    }

    func testProductMarkdownKeepsSemanticsAndBuildsNativeBlocks() throws {
        let result = NoteMarkdownImporter.richText(from: "# Heading\nplain **bold** *italic* `code` ~~gone~~\n- [ ] todo\n- [x] done\n\n| A | B |\n| --- | :---: |\n| one | **two** |", asDocumentStart: false)
        XCTAssertEqual(result.attachmentCount, 2)
        XCTAssertEqual(result.tableBlockCount, 4)
        for (word, trait) in [("bold", NSFontDescriptor.SymbolicTraits.bold), ("italic", .italic), ("code", .monoSpace)] {
            let location = (result.string as NSString).range(of: word).location
            let font = try XCTUnwrap(result.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(trait), word)
        }
        let plain = (result.string as NSString).range(of: "plain").location
        XCTAssertEqual(result.attribute(.font, at: plain, effectiveRange: nil) as? NSFont, EditorTextStyle.body.font)
        XCTAssertEqual((result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 18)
        let malformed = "| A | B |\n| -- nope | --- |\n| one | two |"
        XCTAssertEqual(NoteMarkdownImporter.richText(from: malformed, asDocumentStart: false).string, malformed)
        let fence = "```swift\nlet x = 1\n```"
        let code = NoteMarkdownImporter.richText(from: fence, asDocumentStart: false)
        XCTAssertEqual(code.string, "let x = 1")
        XCTAssertTrue((code.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    func testProductTableEditsOnlySelectedTableAndPreservesCells() throws {
        let text = QuickNoteTextView()
        text.textStorage?.setAttributedString(NoteMarkdownImporter.richText(from: "| A | B |\n| --- | --- |\n| C | D |\n\nafter", asDocumentStart: false))
        let controller = RichTextEditorController()
        controller.connect(text)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(controller.isSelectionInTable)
        XCTAssertTrue(controller.insertTableRow())
        XCTAssertEqual(text.attributedString().tableBlockCount, 6)
        XCTAssertTrue(controller.insertTableColumn())
        XCTAssertEqual(text.attributedString().tableBlockCount, 9)
        XCTAssertTrue(text.string.contains("D"))
        XCTAssertTrue(controller.deleteTableColumn())
        XCTAssertTrue(controller.deleteTableRow())
        XCTAssertEqual(text.attributedString().tableBlockCount, 4)
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        let original = text.attributedString()
        XCTAssertFalse(controller.isSelectionInTable)
        XCTAssertFalse(controller.insertTableRow())
        XCTAssertFalse(controller.deleteTableColumn())
        XCTAssertFalse(controller.deleteCurrentTable())
        XCTAssertTrue(text.attributedString().isEqual(to: original))
    }

    func testProductSelectionStateIsMixedAndPublishesOnlyChanges() {
        let text = QuickNoteTextView()
        let source = NSMutableAttributedString(string: "a\nb", attributes: [.font: EditorTextStyle.body.font])
        source.addAttribute(.font, value: NSFont.systemFont(ofSize: 18, weight: .bold), range: NSRange(location: 2, length: 1))
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        source.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 2, length: 1))
        text.textStorage?.setAttributedString(source)
        text.setSelectedRange(NSRange(location: 0, length: 3))
        let controller = RichTextEditorController()
        controller.connect(text)
        XCTAssertEqual(controller.selectionState.bold, .mixed)
        XCTAssertNil(controller.selectionState.textStyle)
        XCTAssertNil(controller.selectionState.alignment)
        var updates = 0
        let observation = controller.$selectionState.dropFirst().sink { _ in updates += 1 }
        controller.refreshSelectionState()
        controller.connect(text)
        XCTAssertEqual(updates, 0)
        controller.toggleBold()
        XCTAssertEqual(controller.selectionState.bold, .on)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.typingAttributes[.font] = EditorTextStyle.body.font
        controller.refreshSelectionState()
        XCTAssertEqual(controller.selectionState.bold, .off)
        withExtendedLifetime(observation) {}
    }

    func testProductAttachmentActionsPreserveBytesAndAreUndoable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("original attachment".utf8)
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = "note.txt"
        let text = ProductUndoTextView()
        text.textStorage?.setAttributedString(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        let controller = RichTextEditorController()
        controller.connect(text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 17
        paragraph.paragraphSpacing = 0
        text.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: 1))
        let coordinator = RichTextEditor(document: text.attributedString(), cursorLocation: 0,
            controller: controller, onChange: { _, _ in }, onActivate: {}).makeCoordinator()
        text.delegate = coordinator
        coordinator.recordAttachmentCount(in: text)
        let saved = root.appending(path: "saved.txt")
        try controller.saveAttachment(at: 0, to: saved)
        XCTAssertEqual(try Data(contentsOf: saved), data)
        let replacement = root.appending(path: "new.txt")
        try Data("replacement".utf8).write(to: replacement)
        text.undoManager?.beginUndoGrouping()
        try controller.replaceAttachment(at: 0, with: replacement)
        text.undoManager?.endUndoGrouping()
        XCTAssertEqual((text.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.fileWrapper?.regularFileContents, Data("replacement".utf8))
        controller.undo()
        XCTAssertEqual((text.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)?.fileWrapper?.regularFileContents, data)
        text.undoManager?.beginUndoGrouping()
        XCTAssertTrue(controller.deleteAttachment(at: 0))
        text.undoManager?.endUndoGrouping()
        XCTAssertEqual(text.string, "")
        controller.undo()
        XCTAssertEqual(text.attributedString().attachmentCount, 1)
        XCTAssertEqual((text.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore, 17)
        XCTAssertEqual((text.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing, 0)
        XCTAssertFalse(controller.deleteAttachment(at: 10))
    }

    func testProductCurrentFormatPreservesExplicitTypographyAcrossOpenAndSave() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NoteDocumentStore(root: root)
        let id = UUID()
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 11
        let font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 31, weight: .bold),
                                                toHaveTrait: .italicFontMask)
        let source = NSAttributedString(string: "Custom\nBody", attributes: [.font: font, .paragraphStyle: style])
        try store.save(source, id: id)
        for _ in 0..<2 {
            let loaded = try store.load(id: id)
            let text = QuickNoteTextView()
            text.textStorage?.setAttributedString(loaded)
            RichTextEditorController().applyDefaultParagraphSpacing(in: text)
            let actual = try XCTUnwrap(text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(actual.pointSize, 31)
            XCTAssertTrue(actual.fontDescriptor.symbolicTraits.contains([.bold, .italic]))
            let spacing = try XCTUnwrap(text.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(spacing.paragraphSpacing, 0)
            XCTAssertEqual(spacing.paragraphSpacingBefore, 11)
            XCTAssertEqual(spacing.lineSpacing, 0)
            try store.save(text.attributedString(), id: id)
        }
    }

    func testProductMultilinePasteSplitsAnAttributeRunAtTitleBoundary() throws {
        let text = QuickNoteTextView()
        text.isRichText = true
        text.typingAttributes[.font] = EditorTextStyle.title.font
        let source = NSAttributedString(string: "Title\nBody\nLast", attributes: [.font: NSFont.systemFont(ofSize: 32)])
        let board = NSPasteboard(name: .init(UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setData(try source.data(from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
        XCTAssertTrue(text.readSelection(from: board))
        XCTAssertEqual((text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 24)
        for index in [6, 11] {
            XCTAssertEqual((text.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.pointSize, 13)
        }
    }

    func testProductBoldWorksOnLightSystemBody() throws {
        let text = QuickNoteTextView()
        text.textStorage?.setAttributedString(NSAttributedString(string: "light", attributes: [.font: EditorTextStyle.body.font]))
        text.setSelectedRange(NSRange(location: 0, length: 5))
        let controller = RichTextEditorController()
        controller.connect(text)
        controller.toggleBold()
        XCTAssertTrue((text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        controller.toggleBold()
        XCTAssertEqual(text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, EditorTextStyle.body.font)
    }

    func testProductChecklistTogglesSelectedParagraphsAsGroupAndReturnExitsEmptyItem() {
        let text = QuickNoteTextView()
        text.textStorage?.setAttributedString(NSAttributedString(string: "one\ntwo\nthree", attributes: [.font: EditorTextStyle.body.font]))
        text.setSelectedRange(NSRange(location: 0, length: 7))
        let controller = RichTextEditorController()
        controller.connect(text)
        controller.toggleChecklistItemAtSelection()
        XCTAssertEqual(text.string, "\u{FFFC} one\n\u{FFFC} two\nthree")
        controller.toggleChecklistItemAtSelection()
        XCTAssertEqual(text.string, "one\ntwo\nthree")
        text.setSelectedRange(NSRange(location: 3, length: 0))
        controller.insertChecklistItem()
        XCTAssertTrue(controller.continueListAfterNewline())
        XCTAssertEqual(text.string, "\u{FFFC} one\n\u{FFFC} \ntwo\nthree")
        XCTAssertTrue(controller.continueListAfterNewline())
        XCTAssertEqual(text.string, "\u{FFFC} one\n\ntwo\nthree")
    }

    func testSessionResolvesEachNoteDocumentPath() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let session = NoteSession(repository: repository, documents: NoteDocumentStore(root: root))
        let first = NoteRecord()
        let second = NoteRecord()

        XCTAssertEqual(session.documentURL(for: first), root.appending(path: first.documentPath))
        XCTAssertEqual(session.documentURL(for: second), root.appending(path: second.documentPath))
        XCTAssertNotEqual(session.documentURL(for: first), session.documentURL(for: second))
    }

    func testRTFDRoundTripPreservesText() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = NoteDocumentStore(root: root)
        let id = UUID()
        try store.save(NSAttributedString(string: "快速记录"), id: id)
        XCTAssertEqual(try store.load(id: id).string, "快速记录")
    }

    func testRTFDRoundTripPreservesImageAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = NoteDocumentStore(root: root)
        let id = UUID()
        let attachment = NSTextAttachment()
        attachment.image = testImage()
        let document = NSMutableAttributedString(string: "图：")
        document.append(NSAttributedString(attachment: attachment))
        try store.save(document, id: id)
        let loaded = try store.load(id: id)
        XCTAssertEqual(loaded.attachmentCount, 1)
    }

    func testPastedImageAutosavesAndReopensThroughEditor() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let documents = NoteDocumentStore(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        )
        let session = NoteSession(repository: repository, documents: documents)
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        let controller = RichTextEditorController()
        let editor = RichTextEditor(
            document: session.document,
            cursorLocation: 0,
            controller: controller,
            onChange: session.update,
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([testImage()]))

        XCTAssertTrue(textView.readSelection(from: pasteboard))
        try await Task.sleep(for: .milliseconds(400))

        let reopened = NoteSession(repository: repository, documents: documents)
        try reopened.open(note)
        XCTAssertEqual(reopened.document.attachmentCount, 1)
        let attachment = try XCTUnwrap(
            reopened.document.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        )
        let imageData = try XCTUnwrap(attachment.fileWrapper?.regularFileContents)
        XCTAssertNotNil(NSImage(data: imageData))
    }

    func testWebsiteRichTextPasteAdoptsQuickNoteTypographyAndDropsColors() throws {
        let controller = RichTextEditorController()
        let title = NSAttributedString(
            string: "标题\n",
            attributes: [.font: EditorTextStyle.title.font]
        )
        let editor = RichTextEditor(
            document: title,
            cursorLocation: title.length,
            controller: controller,
            onChange: { _, _ in },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        let source = NSMutableAttributedString(
            string: "网页重点\n第二段",
            attributes: [
                .font: NSFont(name: "Times New Roman Bold", size: 28)!,
                .foregroundColor: NSColor.systemRed,
                .backgroundColor: NSColor.systemYellow,
            ]
        )
        let linkRange = (source.string as NSString).range(of: "第二段")
        source.addAttribute(.link, value: URL(string: "https://example.com")!, range: linkRange)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(
            try source.data(
                from: NSRange(location: 0, length: source.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            ),
            forType: .rtf
        ))

        XCTAssertTrue(textView.readSelection(from: pasteboard))

        let insertedRange = NSRange(location: title.length, length: source.length)
        let font = try XCTUnwrap(textView.textStorage?.attribute(
            .font,
            at: insertedRange.location,
            effectiveRange: nil
        ) as? NSFont)
        XCTAssertEqual(font.pointSize, EditorTextStyle.body.font.pointSize)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertNil(textView.textStorage?.attribute(.foregroundColor, at: insertedRange.location, effectiveRange: nil))
        XCTAssertNil(textView.textStorage?.attribute(.backgroundColor, at: insertedRange.location, effectiveRange: nil))
        XCTAssertEqual(
            textView.textStorage?.attribute(.link, at: NSMaxRange(insertedRange) - 1, effectiveRange: nil) as? URL,
            URL(string: "https://example.com")
        )
    }

    func testScreenshotImportPersistsAsAnImageAttachment() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let documents = NoteDocumentStore(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        )
        let session = NoteSession(repository: repository, documents: documents)
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        let image = testImage()
        let data = try XCTUnwrap(image.tiffRepresentation)

        try session.appendImage(data)

        let reopened = NoteSession(repository: repository, documents: documents)
        try reopened.open(note)
        XCTAssertEqual(reopened.document.attachmentCount, 1)
        XCTAssertEqual(reopened.currentNote?.title, "截图")
    }

    func testEditorToolbarFormatsTextAndInsertsTableAndFile() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "测试")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        textView.setSelectedRange(NSRange(location: 0, length: 2))
        controller.applyTextStyle(.title)
        XCTAssertEqual((document.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, EditorTextStyle.title.font.pointSize)

        textView.setSelectedRange(NSRange(location: document.length, length: 0))
        controller.insertTable()
        XCTAssertEqual(document.tableBlockCount, 4)

        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".txt")
        try Data("附件".utf8).write(to: file)
        textView.setSelectedRange(NSRange(location: document.length, length: 0))
        try controller.insertFiles([file])
        XCTAssertEqual(document.attachmentCount, 1)
    }

    func testNewNoteStartsWithTitleAndReturnContinuesInBodyStyle() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "")
        let host = NSHostingView(rootView: RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        XCTAssertEqual(
            (textView.typingAttributes[.font] as? NSFont)?.pointSize,
            EditorTextStyle.title.font.pointSize
        )
        textView.insertText("标题", replacementRange: textView.selectedRange())
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        textView.insertText("正文", replacementRange: textView.selectedRange())

        let titleFont = try XCTUnwrap(document.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let bodyLocation = (document.string as NSString).range(of: "正文").location
        let bodyFont = try XCTUnwrap(
            document.attribute(.font, at: bodyLocation, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(titleFont.pointSize, EditorTextStyle.title.font.pointSize)
        XCTAssertFalse(NSFontManager.shared.traits(of: titleFont).contains(.boldFontMask))
        XCTAssertEqual(bodyFont.pointSize, 13)
        XCTAssertFalse(NSFontManager.shared.traits(of: bodyFont).contains(.boldFontMask))
    }

    func testInsertedImagesScaleDownAndOtherFilesUseCompactCards() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        host.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let imageURL = root.appending(path: "large.png")
        let largeImage = NSImage(size: NSSize(width: 1_200, height: 900))
        largeImage.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 1_200, height: 900).fill()
        largeImage.unlockFocus()
        let originalImageData = try XCTUnwrap(
            largeImage.tiffRepresentation
                .flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
        )
        try originalImageData.write(to: imageURL)
        let audioURL = root.appending(path: "sample.wav")
        let videoURL = root.appending(path: "sample.mp4")
        let documentURL = root.appending(path: "sample.pdf")
        try Data("audio".utf8).write(to: audioURL)
        try Data("video".utf8).write(to: videoURL)
        try Data("document".utf8).write(to: documentURL)

        try controller.insertFiles([imageURL, audioURL, videoURL, documentURL])

        var attachments: [NSTextAttachment] = []
        document.enumerateAttribute(.attachment, in: NSRange(location: 0, length: document.length)) {
            value, _, _ in
            if let attachment = value as? NSTextAttachment { attachments.append(attachment) }
        }
        XCTAssertEqual(attachments.count, 4)
        let image = try XCTUnwrap(attachments.first)
        XCTAssertLessThanOrEqual(image.bounds.width, 328)
        XCTAssertLessThanOrEqual(image.bounds.height, 278.8)
        XCTAssertFalse(image.allowsTextAttachmentView)
        XCTAssertLessThan(try XCTUnwrap(image.fileWrapper?.regularFileContents).count, originalImageData.count)
        XCTAssertEqual(attachments[1].bounds.height, 34)
        XCTAssertLessThanOrEqual(attachments[1].bounds.width, 328)
        XCTAssertTrue(attachments[1].allowsTextAttachmentView)
        XCTAssertTrue(attachments[1].usesTextAttachmentView)
        XCTAssertNil(attachments[1].attachmentCell)
        XCTAssertTrue(
            try XCTUnwrap(attachments[1].fileWrapper?.preferredFilename)
                .hasPrefix(AttachmentPresentation.audioFilenamePrefix)
        )
        for attachment in attachments.dropFirst(2) {
            XCTAssertEqual(attachment.bounds.height, 58)
        }
        let attachmentParagraph = try XCTUnwrap(
            document.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertEqual(attachmentParagraph.paragraphSpacingBefore, 6)
        XCTAssertEqual(attachmentParagraph.paragraphSpacing, 12)
        XCTAssertTrue(attachments.allSatisfy { $0.fileWrapper?.regularFileContents != nil })
    }

    func testEditorUsesCompactChineseContextMenu() {
        XCTAssertEqual(
            QuickNoteTextView.editingMenu().items.compactMap { $0.isSeparatorItem ? nil : $0.title },
            ["剪切", "复制", "粘贴", "全选", "上下间距"]
        )
        XCTAssertEqual(
            QuickNoteTextView.editingMenu().item(withTitle: "上下间距")?.submenu?.items.map(\.title),
            ["紧凑", "标准", "宽松"]
        )
    }

    func testImageAttachmentCopiesAsStandardImageData() throws {
        let image = testImage()
        let data = try XCTUnwrap(
            image.tiffRepresentation
                .flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
        )
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = "截图.png"
        let textView = QuickNoteTextView()
        textView.textStorage?.setAttributedString(
            NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))

        XCTAssertTrue(textView.copyImageAttachment(at: 0, to: pasteboard))
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    func testAIFormattingChangesOnlyTypographyAndSpacing() throws {
        let controller = RichTextEditorController()
        let imageData = try XCTUnwrap(testImage().tiffRepresentation)
        let wrapper = FileWrapper(regularFileWithContents: imageData)
        wrapper.preferredFilename = "截图.tiff"
        let document = NSMutableAttributedString(string: "产品方案\n核心能力\n正文内容\n")
        document.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        let textView = QuickNoteTextView()
        textView.textStorage?.setAttributedString(document)
        controller.connect(textView)
        let source = try controller.aiFormattingSource()
        let plan = try AIFormattingPlan.parse(
            """
            {"paragraphs":[
              {"index":0,"style":"title"},
              {"index":1,"style":"heading"},
              {"index":2,"style":"body"}
            ]}
            """
        )

        XCTAssertTrue(try controller.applyAIFormatting(plan, expectedDocument: source.document))
        XCTAssertEqual(textView.string, document.string)
        XCTAssertEqual(textView.attributedString().attachmentCount, 1)
        XCTAssertEqual(
            (textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize,
            EditorTextStyle.title.font.pointSize
        )
        let headingLocation = (textView.string as NSString).range(of: "核心能力").location
        XCTAssertEqual(
            (textView.textStorage?.attribute(.font, at: headingLocation, effectiveRange: nil) as? NSFont)?.pointSize,
            EditorTextStyle.heading.font.pointSize
        )
        let bodyLocation = (textView.string as NSString).range(of: "正文内容").location
        let bodyStyle = textView.textStorage?.attribute(
            .paragraphStyle,
            at: bodyLocation,
            effectiveRange: nil
        ) as? NSParagraphStyle
        XCTAssertEqual(
            (textView.textStorage?.attribute(.font, at: bodyLocation, effectiveRange: nil) as? NSFont)?.pointSize,
            EditorTextStyle.body.font.pointSize
        )
        XCTAssertEqual(bodyStyle?.lineHeightMultiple, 0)
        XCTAssertEqual(bodyStyle?.lineSpacing, 1)
        XCTAssertEqual(bodyStyle?.paragraphSpacingBefore, 0)
        XCTAssertEqual(bodyStyle?.paragraphSpacing, 4)
    }

    func testAIFormattingFinishesForOriginalNoteAfterSwitch() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let documents = NoteDocumentStore(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        )
        let session = NoteSession(repository: repository, documents: documents)
        try session.createAndOpen()
        let originalNote = try XCTUnwrap(session.currentNote)
        let original = NSAttributedString(string: "原始便签\n正文")
        session.update(document: original, cursorLocation: original.length)
        try session.flush()
        let revision = session.contentRevision(for: originalNote.id)
        try session.createAndOpen()
        let currentNoteID = session.currentNote?.id
        let replacement = NSMutableAttributedString(attributedString: original)
        replacement.addAttribute(
            .font,
            value: EditorTextStyle.title.font,
            range: NSRange(location: 0, length: 4)
        )

        try session.saveAIFormattedDocument(replacement, replacing: original,
                                           expectedRevision: revision, for: originalNote.id)

        XCTAssertEqual(session.currentNote?.id, currentNoteID)
        let reopened = try documents.load(id: originalNote.id)
        XCTAssertEqual(reopened.string, original.string)
        XCTAssertEqual(
            (reopened.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize,
            EditorTextStyle.title.font.pointSize
        )
    }

    func testImageAttachmentCapsImportedParagraphSpacing() throws {
        let controller = RichTextEditorController()
        let wrapper = FileWrapper(regularFileWithContents: Data())
        wrapper.preferredFilename = "截图.png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let oversized = NSMutableParagraphStyle()
        oversized.paragraphSpacingBefore = 80
        oversized.paragraphSpacing = 120
        let document = NSMutableAttributedString(
            string: "上方文字\n",
            attributes: [.paragraphStyle: oversized]
        )
        let attachmentString = NSMutableAttributedString(attachment: attachment)
        attachmentString.addAttribute(
            .paragraphStyle,
            value: oversized,
            range: NSRange(location: 0, length: attachmentString.length)
        )
        document.append(attachmentString)
        document.append(NSAttributedString(
            string: "\n下方文字",
            attributes: [.paragraphStyle: oversized]
        ))
        let textView = QuickNoteTextView()
        textView.textStorage?.setAttributedString(document)

        controller.prepareFileAttachments(in: textView)

        let attachmentRange = (textView.string as NSString).range(of: "\u{FFFC}")
        let attachmentStyle = try XCTUnwrap(textView.textStorage?.attribute(
            .paragraphStyle,
            at: attachmentRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        XCTAssertEqual(attachmentStyle.paragraphSpacingBefore, 6)
        XCTAssertEqual(attachmentStyle.paragraphSpacing, 12)
        let previousStyle = try XCTUnwrap(textView.textStorage?.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        XCTAssertEqual(previousStyle.paragraphSpacing, 4)
        let nextStyle = try XCTUnwrap(textView.textStorage?.attribute(
            .paragraphStyle,
            at: NSMaxRange(attachmentRange) + 1,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        XCTAssertEqual(nextStyle.paragraphSpacingBefore, 4)
    }

    func testImageAttachmentIsSeparatedFromAdjacentText() throws {
        let controller = RichTextEditorController()
        let data = try XCTUnwrap(
            testImage().tiffRepresentation
                .flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:])
        )
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = "截图.png"
        let document = NSMutableAttributedString(string: "上方文字")
        document.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        document.append(NSAttributedString(string: "下方文字"))
        let textView = QuickNoteTextView()
        textView.textStorage?.setAttributedString(document)
        textView.setSelectedRange(NSRange(location: document.length, length: 0))

        controller.prepareFileAttachments(in: textView)

        XCTAssertEqual(textView.string, "上方文字\n\u{FFFC}\n下方文字")
        XCTAssertEqual(textView.selectedRange().location, textView.string.utf16.count)
    }

    func testAudioAttachmentPreservesCompactSpacingAndFilename() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "")
        let host = NSHostingView(rootView: RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        host.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        try controller.insertFiles([URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")])
        let attachment = try XCTUnwrap(
            document.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        )
        let paragraph = try XCTUnwrap(
            document.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertEqual(paragraph.paragraphSpacingBefore, 6)
        XCTAssertEqual(paragraph.paragraphSpacing, 12)
        XCTAssertEqual((attachment as? AudioTextAttachment)?.originalFilename, "Glass.aiff")
        XCTAssertNotNil(attachment.fileWrapper?.regularFileContents)
    }

    func testAudioAttachmentUsesInteractivePlayerView() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "")
        let host = NSHostingView(rootView: RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        try controller.insertFiles([URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")])
        let attachment = try XCTUnwrap(
            document.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        )
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let provider = attachment.viewProvider(
            for: textView,
            location: contentStorage.documentRange.location,
            textContainer: nil
        )
        let view = try XCTUnwrap(provider?.view)
        let button = try XCTUnwrap(view.descendant(ofType: NSButton.self))
        let slider = try XCTUnwrap(view.descendant(ofType: NSSlider.self))
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(attachment.allowsTextAttachmentView)
        XCTAssertTrue(attachment.usesTextAttachmentView)
        XCTAssertNil(attachment.attachmentCell)
        XCTAssertGreaterThanOrEqual(button.frame.width, 34)
        XCTAssertGreaterThanOrEqual(button.frame.height, 34)
        XCTAssertTrue(slider.isContinuous)
        XCTAssertEqual(button.toolTip, "播放")
        button.performClick(nil)
        XCTAssertEqual(button.toolTip, "暂停")
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertGreaterThan(slider.doubleValue, 0)
        let seekTarget = slider.maxValue * 0.5
        slider.doubleValue = seekTarget
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThan(slider.doubleValue, seekTarget)
        XCTAssertLessThan(slider.doubleValue, seekTarget + 0.4)
        button.performClick(nil)
        XCTAssertEqual(button.toolTip, "播放")
    }

    func testDeletingPlayingAudioAttachmentStopsPlayback() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "")
        let host = NSHostingView(rootView: RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        try controller.insertFiles([URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")])
        let attachment = try XCTUnwrap(
            document.attribute(.attachment, at: 0, effectiveRange: nil) as? AudioTextAttachment
        )
        var isPlaying = false
        attachment.playback.onUpdate = { playing, _, _ in isPlaying = playing }

        attachment.playback.toggle()
        XCTAssertTrue(isPlaying)
        textView.setSelectedRange(NSRange(location: 0, length: 1))
        textView.deleteBackward(nil)

        XCTAssertEqual(document.attachmentCount, 0)
        XCTAssertFalse(isPlaying)
    }

    func testPastedImageIsScaledToEditorAndUsesClickableCell() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        let image = NSImage(size: NSSize(width: 1_008, height: 154))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 1_008, height: 154).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(image.tiffRepresentation)
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = "Pasted Graphic.tiff"
        textView.textStorage?.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.didChangeText()

        let attachment = try XCTUnwrap(
            document.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        )
        XCTAssertLessThanOrEqual(attachment.bounds.width, 328)
        XCTAssertFalse(attachment.allowsTextAttachmentView)
        let cellImage = try XCTUnwrap((attachment.attachmentCell as? NSTextAttachmentCell)?.image)
        XCTAssertLessThanOrEqual(cellImage.size.width, 328)
        XCTAssertTrue(attachment.attachmentCell?.wantsToTrackMouse() == true)
        let preview = NSImage(size: NSSize(width: 32, height: 32))
        preview.lockFocus()
        attachment.attachmentCell?.draw(
            withFrame: NSRect(x: 0, y: 0, width: 32, height: 32),
            in: textView
        )
        preview.unlockFocus()
        let bitmap = try XCTUnwrap(preview.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertNotEqual(bitmap.colorAt(x: 0, y: 16), bitmap.colorAt(x: 16, y: 16))
        XCTAssertEqual(document.string, "\u{FFFC}\n")
        XCTAssertEqual(textView.selectedRange().location, 2)
    }

    func testImagePreviewOpensAtScreenCenter() throws {
        let image = NSImage(size: NSSize(width: 1_008, height: 154))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 1_008, height: 154).fill()
        image.unlockFocus()
        let wrapper = FileWrapper(regularFileWithContents: try XCTUnwrap(image.tiffRepresentation))
        wrapper.preferredFilename = "Preview.tiff"
        let document = NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
        let controller = RichTextEditorController()
        let host = NSHostingView(rootView: RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { _, _ in },
            onActivate: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 240)
        host.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        XCTAssertTrue(controller.openFileAttachment(at: 0))
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Preview.tiff" })
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        XCTAssertEqual(panel.frame.midX, screen.visibleFrame.midX, accuracy: 1)
        XCTAssertEqual(panel.frame.midY, screen.visibleFrame.midY, accuracy: 1)
        panel.close()
    }

    func testChecklistItemCanBeInsertedAndToggled() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "完成这件事")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: document.length,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        controller.insertChecklistItem()

        let itemRange = (document.string as NSString).range(of: "\u{FFFC}")
        XCTAssertNotEqual(itemRange.location, NSNotFound)
        XCTAssertNil(document.attribute(.link, at: itemRange.location, effectiveRange: nil))
        var attachment = try XCTUnwrap(
            document.attribute(.attachment, at: itemRange.location, effectiveRange: nil) as? NSTextAttachment
        )
        XCTAssertEqual(attachment.fileWrapper?.preferredFilename, "quicknote-checklist-unchecked.png")
        XCTAssertEqual(attachment.bounds.size, NSSize(width: 11, height: 11))

        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        textView.setSelectedRange(NSRange(location: 0, length: document.length))
        controller.applyTextStyle(.title)
        attachment = try XCTUnwrap(
            document.attribute(.attachment, at: itemRange.location, effectiveRange: nil) as? NSTextAttachment
        )
        XCTAssertEqual(
            attachment.bounds.origin.y,
            (EditorTextStyle.title.font.capHeight - 11) / 2,
            accuracy: 0.01
        )
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let handled = attachment.attachmentCell?.trackMouse(
            with: click,
            in: attachment.bounds,
            of: textView,
            atCharacterIndex: itemRange.location,
            untilMouseUp: false
        )
        XCTAssertEqual(handled, true)
        attachment = try XCTUnwrap(
            document.attribute(.attachment, at: itemRange.location, effectiveRange: nil) as? NSTextAttachment
        )
        XCTAssertEqual(attachment.fileWrapper?.preferredFilename, "quicknote-checklist-checked.png")
        XCTAssertNil(document.attribute(.link, at: itemRange.location, effectiveRange: nil))

        XCTAssertTrue(controller.toggleChecklistItem(at: itemRange.location))
        attachment = try XCTUnwrap(
            document.attribute(.attachment, at: itemRange.location, effectiveRange: nil) as? NSTextAttachment
        )
        XCTAssertEqual(attachment.fileWrapper?.preferredFilename, "quicknote-checklist-unchecked.png")

        let store = NoteDocumentStore(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        )
        let id = UUID()
        try store.save(document, id: id)
        let reopened = try store.load(id: id)
        XCTAssertEqual(reopened.attachmentCount, 1)
        let reopenedAttachment = reopened.attribute(
            .attachment,
            at: itemRange.location,
            effectiveRange: nil
        ) as? NSTextAttachment
        XCTAssertNotNil((reopenedAttachment?.attachmentCell as? NSTextAttachmentCell)?.image)
        XCTAssertEqual(reopenedAttachment?.fileWrapper?.preferredFilename, "quicknote-checklist-unchecked.png")
        XCTAssertNil(reopened.attribute(.link, at: itemRange.location, effectiveRange: nil))
    }

    func testChecklistButtonActionTogglesCurrentParagraph() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "完成这件事")
        let host = NSHostingView(rootView: RichTextEditor(
            document: document,
            cursorLocation: document.length,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        controller.toggleChecklistItemAtSelection()
        XCTAssertEqual(document.attachmentCount, 1)

        controller.toggleChecklistItemAtSelection()

        XCTAssertEqual(document.string, "完成这件事")
        XCTAssertEqual(document.attachmentCount, 0)
    }

    func testParagraphFormattingUsesVisiblePrefixes() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "第一项\n第二项")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        func selectAll() {
            textView.setSelectedRange(NSRange(location: 0, length: document.length))
        }

        selectAll()
        controller.applyList(.disc)
        XCTAssertEqual(document.string, "• 第一项\n• 第二项")
        selectAll()
        controller.applyList(.hyphen)
        XCTAssertEqual(document.string, "– 第一项\n– 第二项")
        selectAll()
        controller.applyList(.decimal)
        XCTAssertEqual(document.string, "1. 第一项\n2. 第二项")
        selectAll()
        controller.applyBlockQuote()
        XCTAssertEqual(document.string, "› 第一项\n› 第二项")
        selectAll()
        controller.applyBlockQuote()
        XCTAssertEqual(document.string, "第一项\n第二项")

        textView.textStorage?.setAttributedString(NSAttributedString())
        textView.setSelectedRange(.init(location: 0, length: 0))
        controller.applyList(.disc)
        XCTAssertEqual(document.string, "• ")
    }

    func testLegacyLinkedChecklistIsMigratedToDirectClickMarker() throws {
        let legacyAttachment = NSTextAttachment()
        legacyAttachment.image = testImage()
        let legacyMarker = NSMutableAttributedString(attachment: legacyAttachment)
        legacyMarker.addAttribute(
            .link,
            value: URL(string: "quicknote-checklist://unchecked")!,
            range: NSRange(location: 0, length: legacyMarker.length)
        )
        var document: NSAttributedString = legacyMarker
        let controller = RichTextEditorController()
        let editor = RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        XCTAssertNil(textView.textStorage?.attribute(.link, at: 0, effectiveRange: nil))
        let attachment = try XCTUnwrap(
            textView.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        )
        XCTAssertEqual(attachment.fileWrapper?.preferredFilename, "quicknote-checklist-unchecked.png")
    }

    func testParagraphAlignmentCanBeChanged() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "需要居中的段落")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        controller.applyAlignment(.center)

        let style = document.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .center)
    }

    func testParagraphIndentCanIncreaseAndDecrease() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "需要缩进的段落")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        controller.changeIndent(by: 18)
        var style = document.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.headIndent, 18)

        controller.changeIndent(by: -18)
        style = document.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.headIndent, 0)
    }

    func testParagraphLineSpacingCanBeChanged() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "第一行\n第二行")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        textView.setSelectedRange(NSRange(location: 0, length: document.length))

        controller.applyLineHeightMultiple(1.5)

        let first = document.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let second = document.attribute(.paragraphStyle, at: 4, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(first?.lineHeightMultiple, 1.5)
        XCTAssertEqual(second?.lineHeightMultiple, 1.5)
    }

    func testSelectedParagraphSpacingCanBeChanged() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "第一段\n第二段")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        textView.setSelectedRange(NSRange(location: 0, length: document.length))

        controller.applyParagraphSpacing(before: 4, after: 8)

        for location in [0, 4] {
            let style = document.attribute(.paragraphStyle, at: location, effectiveRange: nil)
                as? NSParagraphStyle
            XCTAssertEqual(style?.paragraphSpacingBefore, 4)
            XCTAssertEqual(style?.paragraphSpacing, 8)
        }
    }

    func testEditorEnablesAutomaticLinkDetection() throws {
        let document = NSAttributedString(string: "https://example.com")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: document.length,
            controller: RichTextEditorController(),
            onChange: { _, _ in },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        XCTAssertTrue(textView.isAutomaticLinkDetectionEnabled)
        XCTAssertNotNil(textView.textStorage?.attribute(.link, at: 0, effectiveRange: nil))
    }

    func testNumberedLineContinuesAfterNewline() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "1. 第一项")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: document.length,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        XCTAssertTrue(controller.continueListAfterNewline())
        XCTAssertEqual(document.string, "1. 第一项\n2. ")
    }

    func testNumberedLineRenumbersFollowingItemsAcrossAttachmentAfterNewline() throws {
        let controller = RichTextEditorController()
        let firstLine = "5. 当前事项"
        let source = NSMutableAttributedString(string: "\(firstLine)\n")
        source.append(NSAttributedString(attachment: NSTextAttachment()))
        source.append(NSAttributedString(string: "\n6. 后续事项"))
        var document = NSAttributedString(attributedString: source)
        let editor = RichTextEditor(
            document: document,
            cursorLocation: (firstLine as NSString).length,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        XCTAssertTrue(controller.continueListAfterNewline())
        XCTAssertEqual(document.string, "5. 当前事项\n6. \n\u{FFFC}\n7. 后续事项")
    }

    func testContinuedNumberedLinePreservesParagraphFont() throws {
        let controller = RichTextEditorController()
        let bodyFont = NSFont.systemFont(ofSize: 15)
        var document = NSAttributedString(
            string: "2. 正文内容",
            attributes: [.font: bodyFont]
        )
        let editor = RichTextEditor(
            document: document,
            cursorLocation: document.length,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        textView.typingAttributes[.font] = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)

        XCTAssertTrue(controller.continueListAfterNewline())

        let continuedFont = document.attribute(
            .font,
            at: document.length - 1,
            effectiveRange: nil
        ) as? NSFont
        XCTAssertEqual(continuedFont?.fontName, bodyFont.fontName)
        XCTAssertEqual((textView.typingAttributes[.font] as? NSFont)?.fontName, bodyFont.fontName)
    }

    func testAlphabeticLineContinuesAfterNewline() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "B. 第二项")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: document.length,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        XCTAssertTrue(controller.continueListAfterNewline())
        XCTAssertEqual(document.string, "B. 第二项\nC. ")
    }

    func testEmptyNumberedLineExitsSequence() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "1. 第一项\n2. ")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: document.length,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        XCTAssertTrue(controller.continueListAfterNewline())
        XCTAssertEqual(document.string, "1. 第一项\n")
    }

    func testTextBackgroundColorCanBeAppliedAndCleared() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "背景颜色")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        textView.setSelectedRange(NSRange(location: 0, length: document.length))

        controller.applyBackgroundColor(.systemYellow)
        XCTAssertNotNil(document.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor)

        controller.applyBackgroundColor(nil)
        XCTAssertNil(document.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testEditorAppliesComfortableDefaultTextSpacing() throws {
        let document = NSAttributedString(string: "第一行\n第二行")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: 0,
            controller: RichTextEditorController(),
            onChange: { _, _ in },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        let style = textView.textStorage?.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle

        XCTAssertGreaterThan(style?.paragraphSpacing ?? 0, 0)
        XCTAssertEqual(style?.lineSpacing, 1)
    }

    func testTableInsertionPlacesCaretInVisibleParagraphBelowTable() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "提示词")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: document.length,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        controller.insertTable()

        let caret = textView.selectedRange()
        XCTAssertLessThan(caret.location, document.length)
        if caret.location < document.length {
            let style = document.attribute(.paragraphStyle, at: caret.location, effectiveRange: nil)
                as? NSParagraphStyle
            XCTAssertTrue(style?.textBlocks.isEmpty ?? true)
        }
    }

    func testTableSupportsCustomDimensionsAndKeepsVerticalMargins() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "表格前")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: document.length,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(host.descendant(ofType: NSTextView.self))

        controller.insertTable(rows: 3, columns: 4)

        var blocks: [NSTextTableBlock] = []
        document.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: document.length)) {
            value, _, _ in
            blocks += (value as? NSParagraphStyle)?.textBlocks.compactMap { $0 as? NSTextTableBlock } ?? []
        }
        XCTAssertEqual(blocks.count, 12)
        XCTAssertTrue(blocks.filter { $0.startingRow == 0 }.allSatisfy {
            $0.width(for: .margin, edge: .minY) >= 8
        })
        XCTAssertTrue(blocks.filter { $0.startingRow == 2 }.allSatisfy {
            $0.width(for: .margin, edge: .maxY) >= 8
        })
    }

    func testDeleteCurrentTableRemovesAllCellsAndPreservesSurroundingText() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "表格前")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: document.length,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        controller.insertTable()
        var firstCellLocation: Int?
        document.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: document.length)) {
            value, range, stop in
            guard (value as? NSParagraphStyle)?.textBlocks.contains(where: { $0 is NSTextTableBlock }) == true else {
                return
            }
            firstCellLocation = range.location
            stop.pointee = true
        }
        textView.setSelectedRange(NSRange(location: try XCTUnwrap(firstCellLocation), length: 0))

        XCTAssertTrue(controller.deleteCurrentTable())
        XCTAssertEqual(document.tableBlockCount, 0)
        XCTAssertTrue(document.string.contains("表格前"))
    }

    func testDeleteCurrentTableDoesNotDeleteNearbyTableWhenCaretIsBelowIt() throws {
        let controller = RichTextEditorController()
        var document = NSAttributedString(string: "表格前")
        let editor = RichTextEditor(
            document: document,
            cursorLocation: document.length,
            controller: controller,
            onChange: { updated, _ in document = updated },
            onActivate: {}
        )
        let host = NSHostingView(rootView: editor)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        host.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        controller.insertTable()
        textView.setSelectedRange(NSRange(location: document.length, length: 0))

        XCTAssertFalse(controller.deleteCurrentTable())
        XCTAssertEqual(document.tableBlockCount, 4)
    }

    func testTagsPersistAndParticipateInSearch() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let documents = NoteDocumentStore(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        )
        let session = NoteSession(repository: repository, documents: documents)
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)

        session.setTags(["工作", "工作", " 灵感 "])

        XCTAssertEqual(session.tags, ["工作", "灵感"])
        XCTAssertEqual(try repository.search("灵感").map(\.id), [note.id])
        let reopened = NoteSession(repository: repository, documents: documents)
        try reopened.open(note)
        XCTAssertEqual(reopened.tags, ["工作", "灵感"])
    }

    func testSessionFlushesDocumentMetadataAndCursor() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let documents = NoteDocumentStore(root: root)
        let session = NoteSession(repository: repository, documents: documents)

        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        session.update(document: NSAttributedString(string: "\n  标题  \n正文"), cursorLocation: 4)
        try session.flush()

        XCTAssertEqual(note.title, "标题")
        XCTAssertEqual(note.plainText, "\n  标题  \n正文")
        XCTAssertEqual(note.cursorLocation, 4)
        XCTAssertEqual(try documents.load(id: note.id).string, "\n  标题  \n正文")
    }

    func testSelectedTextAppendsAndPersistsImmediately() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let documents = NoteDocumentStore(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        )
        let session = NoteSession(repository: repository, documents: documents)
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        session.update(document: NSAttributedString(string: "已有内容"), cursorLocation: 4)

        try session.appendPlainText("  选中文字  ")

        XCTAssertEqual(session.document.string, "已有内容\n\n选中文字")
        XCTAssertEqual(note.cursorLocation, session.document.length)
        XCTAssertEqual(try documents.load(id: note.id).string, "已有内容\n\n选中文字")
    }

    func testAIImportPreservesMarkdownSemanticsBeforeAndAfterReopening() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let documents = NoteDocumentStore(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        )
        let session = NoteSession(
            repository: NoteRepository(context: container.mainContext),
            documents: documents
        )
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        let original = NSMutableAttributedString(string: "已有正文\n", attributes: [.font: EditorTextStyle.body.font])
        original.append(NSAttributedString(
            string: "手动重点", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold)]
        ))
        session.update(document: original, cursorLocation: original.length)
        let imported = SelectionResultFormatter.richText(
            from: "## 分析结果\n- 结论：**保持内容**\n1. 使用 `API`\n[参考](https://example.com)",
            asDocumentStart: false
        )
        try session.appendAttributedText(imported)

        for document in [session.document, try documents.load(id: note.id)] {
            XCTAssertEqual(document.string, original.string + "\n\n" + imported.string)
            // P03 now preserves explicit Markdown semantics; RTF may use native family aliases.
            let headingLocation = (document.string as NSString).range(of: "分析结果").location
            XCTAssertEqual((document.attribute(.font, at: headingLocation, effectiveRange: nil) as? NSFont)?.pointSize, 18)
            let emphasisLocation = (document.string as NSString).range(of: "保持内容").location
            XCTAssertTrue((document.attribute(.font, at: emphasisLocation, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
            let codeLocation = (document.string as NSString).range(of: "API").location
            XCTAssertTrue((document.attribute(.font, at: codeLocation, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
            let bodyLocation = (document.string as NSString).range(of: "使用").location
            XCTAssertEqual((document.attribute(.font, at: bodyLocation, effectiveRange: nil) as? NSFont)?.pointSize, 13)
            let manualLocation = (document.string as NSString).range(of: "手动重点").location
            let manualFont = try XCTUnwrap(document.attribute(.font, at: manualLocation, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(manualFont.fontDescriptor.symbolicTraits.contains(.bold))
            let linkLocation = (document.string as NSString).range(of: "参考").location
            XCTAssertEqual(document.attribute(.link, at: linkLocation, effectiveRange: nil) as? URL,
                           URL(string: "https://example.com"))
        }
    }

    func testSessionDebouncesAutosaveToLatestDocument() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let documents = NoteDocumentStore(root: root)
        let session = NoteSession(repository: repository, documents: documents)
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        var saveCount = 0
        session.onSaved = { saveCount += 1 }

        session.update(document: NSAttributedString(string: "旧内容"), cursorLocation: 1)
        session.update(document: NSAttributedString(string: "最新内容"), cursorLocation: 4)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(note.plainText, "最新内容")
        XCTAssertEqual(note.cursorLocation, 4)
        XCTAssertEqual(try documents.load(id: note.id).string, "最新内容")
    }

    func testSessionEditorFixtureTeardownDrainsAutosaveAndRejectsLateEditorUpdates() async throws {
        let fixture = try sessionEditorFixture()
        let session = fixture.session
        try session.createAndOpen()
        var saveCount = 0
        var disconnected = false
        session.onSaved = { saveCount += 1 }
        fixture.addUICleanup { disconnected = true }
        // A retained editor callback must keep its storage owner alive and become inert at teardown.
        let lateEditorUpdate = fixture.update
        lateEditorUpdate(NSAttributedString(string: "待保存的最后一处编辑"), 0)
        XCTAssertTrue(session.isDirty)

        try fixture.tearDown()

        XCTAssertTrue(disconnected)
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(session.saveError)
        XCTAssertEqual(saveCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.documents.root.path))
        lateEditorUpdate(NSAttributedString(string: "关闭后的迟到编辑"), 0)
        // Exercise the original 250ms debounce boundary after the temporary directory is removed.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.document.string, "待保存的最后一处编辑")
        XCTAssertEqual(saveCount, 1)
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(session.saveError)
        try fixture.tearDown()
        XCTAssertEqual(saveCount, 1, "重复清理不能再保存或删除一次")
    }

    func testAutosaveFailurePreservesDirtyDocumentAndCanRetry() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let documents = NoteDocumentStore(root: root)
        let session = NoteSession(repository: repository, documents: documents)
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        let savedRoot = root.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: root, to: savedRoot)
        try Data().write(to: root)

        session.update(document: NSAttributedString(string: "不能丢的内容"), cursorLocation: 6)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(session.isDirty)
        XCTAssertNotNil(session.saveError)
        XCTAssertEqual(session.document.string, "不能丢的内容")
        XCTAssertEqual(note.plainText, "")

        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: savedRoot, to: root)
        session.retrySave()

        XCTAssertFalse(session.isDirty)
        XCTAssertNil(session.saveError)
        XCTAssertEqual(try documents.load(id: note.id).string, "不能丢的内容")
    }

    func testCreateAndOpenDoesNotCreateNoteWhenOutgoingFlushFails() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let session = NoteSession(repository: repository, documents: NoteDocumentStore(root: root))
        try session.createAndOpen()
        try FileManager.default.moveItem(at: root, to: root.appendingPathExtension("saved"))
        try Data().write(to: root)
        session.update(document: NSAttributedString(string: "待保存"), cursorLocation: 3)

        XCTAssertThrowsError(try session.createAndOpen())

        XCTAssertEqual(try repository.allNotes().count, 1)
        XCTAssertEqual(session.document.string, "待保存")
        XCTAssertTrue(session.isDirty)
        XCTAssertNotNil(session.saveError)
    }

    func testFailedPinPublishesErrorAndRetryPersistsIntendedValueOnce() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        var saveAttempt = 0
        var failingAttempt: Int?
        let session = NoteSession(
            repository: repository,
            documents: NoteDocumentStore(root: root),
            saveRepository: {
                saveAttempt += 1
                if saveAttempt == failingAttempt { throw TestError.saveFailed }
                try repository.save()
            }
        )
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        var notificationCount = 0
        session.onSaved = { notificationCount += 1 }
        failingAttempt = 3

        XCTAssertFalse(session.togglePinnedRecovering(note))
        XCTAssertTrue(note.isPinned)
        XCTAssertNotNil(session.saveError)
        XCTAssertEqual(notificationCount, 0)

        session.retrySave()

        XCTAssertTrue(note.isPinned)
        XCTAssertNil(session.saveError)
        XCTAssertEqual(notificationCount, 1)
    }

    func testFailedCreatePublishesErrorAndRetryReusesPendingNote() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        var shouldFail = true
        let session = NoteSession(
            repository: repository,
            documents: NoteDocumentStore(root: root),
            saveRepository: {
                if shouldFail {
                    shouldFail = false
                    throw TestError.saveFailed
                }
                try repository.save()
            }
        )
        var notificationCount = 0
        session.onSaved = { notificationCount += 1 }

        XCTAssertFalse(session.createAndOpenRecovering())
        let pendingNote = try XCTUnwrap(repository.allNotes().first)
        XCTAssertNil(session.currentNote)
        XCTAssertNotNil(session.saveError)
        XCTAssertEqual(try repository.allNotes().count, 1)
        XCTAssertEqual(notificationCount, 0)

        XCTAssertFalse(session.createAndOpenRecovering())
        XCTAssertNil(session.currentNote)
        XCTAssertNotNil(session.saveError)
        XCTAssertEqual(try repository.allNotes().count, 1)
        XCTAssertEqual(notificationCount, 0)

        session.retrySave()

        XCTAssertEqual(session.currentNote?.id, pendingNote.id)
        XCTAssertNil(session.saveError)
        XCTAssertEqual(try repository.allNotes().count, 1)
        XCTAssertEqual(notificationCount, 1)
    }

    func testDeletingCurrentNoteSelectsTheRemainingNote() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: NoteRecord.self, configurations: configuration)
        let repository = NoteRepository(context: container.mainContext)
        let session = NoteSession(
            repository: repository,
            documents: NoteDocumentStore(
                root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            )
        )
        try session.createAndOpen()
        let remaining = try XCTUnwrap(session.currentNote)
        try session.createAndOpen()
        let deleted = try XCTUnwrap(session.currentNote)

        XCTAssertTrue(session.deleteRecovering(deleted))

        XCTAssertEqual(session.currentNote?.id, remaining.id)
        XCTAssertEqual(try repository.allNotes().map(\.id), [remaining.id])
    }
}

@MainActor
extension NotePersistenceTests {
    func testCommandCreatesARealDocumentWhenNoNoteIsOpen() throws {
        let (container, repository, documents, session) = try safetyFixture()
        _ = container
        let panel = NotePanelController(rootView: EmptyView())
        let coordinator = PanelCoordinator(panel: panel, session: session)

        try coordinator.toggleFromCommand()
        defer { try? coordinator.toggleFromCommand() }

        let note = try XCTUnwrap(session.currentNote)
        XCTAssertEqual(try documents.load(id: note.id).string, "")
        XCTAssertEqual(try repository.allNotes().count, 1)
    }

    func testUnchangedUndoStateDoesNotPublishAnotherViewUpdate() {
        let controller = RichTextEditorController()
        let textView = QuickNoteTextView()
        controller.connect(textView)
        var updates = 0
        let observation = controller.objectWillChange.sink { updates += 1 }
        controller.connect(textView)
        controller.refreshUndoAvailability()
        XCTAssertEqual(updates, 0)
        withExtendedLifetime(observation) {}
    }

    func testSwitchingNotesClearsUndoButRefreshingSameNotePreservesIt() async throws {
        let controller = RichTextEditorController()
        let firstID = UUID()
        let secondID = UUID()
        func editor(_ string: String) -> RichTextEditor {
            RichTextEditor(document: NSAttributedString(string: string,
                attributes: [.font: EditorTextStyle.body.font]), cursorLocation: 0,
                controller: controller, onChange: { _, _ in }, onActivate: {},
                noteID: string == "Note A" ? firstID : secondID)
        }
        let host = NSHostingView(rootView: editor("Note A"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let text = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
        text.setSelectedRange(NSRange(location: 0, length: 6))
        controller.toggleUnderline()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(text.undoManager?.canUndo == true)
        host.rootView = editor("Note A")
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(text.undoManager?.canUndo == true, "same-note updates must keep undo")
        host.rootView = editor("Note B must survive")
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(text.string, "Note B must survive")
        if text.undoManager?.canUndo == true { controller.undo() }
        XCTAssertEqual(text.string, "Note B must survive")
        XCTAssertFalse(text.undoManager?.canUndo == true)
        withExtendedLifetime(window) {}
    }

    func testDeleteFailureKeepsOriginalNoteAndDoesNotOverwriteCorruptReplacement() throws {
        let (container, repository, documents, session) = try safetyFixture()
        _ = container
        try session.createAndOpen()
        let original = try XCTUnwrap(session.currentNote)
        try session.appendPlainText("original content")
        let broken = repository.createNote()
        try documents.save(NSAttributedString(string: "other content"), id: broken.id)
        try repository.save()
        let file = session.documentURL(for: broken).appending(path: "TXT.rtf")
        let corrupt = Data("invalid RTF".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try documents.load(id: broken.id))

        XCTAssertFalse(session.deleteRecovering(original))
        XCTAssertEqual(session.currentNote?.id, original.id)
        XCTAssertEqual(session.document.string, "original content")
        try session.flush()
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertEqual(try repository.allNotes().count, 2)
    }

    func testMissingDocumentIsNotOpenedOrSavedAsEmpty() throws {
        let (container, repository, documents, session) = try safetyFixture()
        _ = container
        let note = repository.createNote()
        note.title = "recoverable title"
        note.plainText = "recoverable text"
        try repository.save()

        XCTAssertThrowsError(try documents.load(id: note.id))
        XCTAssertFalse(session.openRecovering(note))
        try session.flush()
        XCTAssertNil(session.currentNote)
        XCTAssertEqual(note.title, "recoverable title")
        XCTAssertEqual(note.plainText, "recoverable text")
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.documentURL(for: note).path))
    }

    func testUnreadableNoteDoesNotBlockOpeningAnotherNote() throws {
        let (container, repository, documents, session) = try safetyFixture()
        _ = container
        let broken = repository.createNote()
        let healthy = repository.createNote()
        try documents.save(NSAttributedString(string: "healthy"), id: healthy.id)
        try documents.save(NSAttributedString(string: "broken"), id: broken.id)
        try Data("invalid RTF".utf8).write(to: session.documentURL(for: broken).appending(path: "TXT.rtf"))
        try repository.save()

        XCTAssertFalse(session.openRecovering(broken))
        XCTAssertTrue(session.openRecovering(healthy))
        XCTAssertEqual(session.currentNote?.id, healthy.id)
        XCTAssertEqual(session.document.string, "healthy")
        XCTAssertNil(session.saveError)
    }

    func testBackgroundAIFormattingRejectsLinkOnlyEdit() throws {
        let (container, _, documents, session) = try safetyFixture()
        _ = container
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        let original = NSAttributedString(string: "link", attributes: [.font: EditorTextStyle.body.font,
            .link: URL(string: "https://example.com/old")!])
        session.update(document: original, cursorLocation: 0)
        try session.flush()
        let revision = session.contentRevision(for: note.id)
        let edited = NSAttributedString(string: "link", attributes: [.font: EditorTextStyle.body.font,
            .link: URL(string: "https://example.com/new")!])
        session.update(document: edited, cursorLocation: 0)
        try session.createAndOpen()

        XCTAssertThrowsError(try session.saveAIFormattedDocument(original, replacing: original,
            expectedRevision: revision, for: note.id))
        XCTAssertEqual(try documents.load(id: note.id).attribute(.link, at: 0, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com/new"))
    }

    func testCurrentAIFormattingRejectsParagraphStyleEdit() throws {
        let controller = RichTextEditorController()
        let textView = QuickNoteTextView()
        textView.textStorage?.setAttributedString(NSAttributedString(string: "Heading\nBody",
            attributes: [.font: EditorTextStyle.body.font]))
        controller.connect(textView)
        let source = try controller.aiFormattingSource()
        let changed = NSMutableParagraphStyle()
        changed.paragraphSpacing = 19
        textView.textStorage?.addAttribute(.paragraphStyle, value: changed,
            range: NSRange(location: 0, length: textView.string.utf16.count))
        let plan = AIFormattingPlan(assignments: [.init(index: 0, style: .title)])

        XCTAssertThrowsError(try controller.applyAIFormatting(plan, expectedDocument: source.document))
        XCTAssertEqual((textView.textStorage?.attribute(.paragraphStyle, at: 0,
            effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing, 19)
    }

    func testStartupSkipsDamagedNewestNoteAndKeepsItForRecovery() throws {
        let (container, repository, documents, session) = try safetyFixture()
        _ = container
        let healthy = repository.createNote()
        let broken = repository.createNote()
        healthy.updatedAt = Date(timeIntervalSince1970: 1)
        broken.updatedAt = Date(timeIntervalSince1970: 2)
        try documents.save(NSAttributedString(string: "healthy"), id: healthy.id)
        try documents.save(NSAttributedString(string: "broken"), id: broken.id)
        let brokenFile = session.documentURL(for: broken).appending(path: "TXT.rtf")
        let corrupt = Data("invalid RTF".utf8)
        try corrupt.write(to: brokenFile)
        try repository.save()

        try session.openMostRecentReadableNote()

        XCTAssertEqual(session.currentNote?.id, healthy.id)
        XCTAssertEqual(session.document.string, "healthy")
        XCTAssertNotNil(session.readError)
        XCTAssertNil(session.saveError)
        XCTAssertEqual(try repository.allNotes().count, 2)
        XCTAssertEqual(try Data(contentsOf: brokenFile), corrupt)
    }

    func testStartupWithOnlyMissingDocumentsCreatesSeparateUsableNote() throws {
        let (container, repository, documents, session) = try safetyFixture()
        _ = container
        let missing = repository.createNote()
        missing.title = "missing note"
        missing.plainText = "recoverable original text"
        try repository.save()

        try session.openMostRecentReadableNote()
        let newNote = try XCTUnwrap(session.currentNote)

        XCTAssertNotEqual(newNote.id, missing.id)
        XCTAssertNotNil(session.readError)
        XCTAssertEqual(missing.plainText, "recoverable original text")
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.documentURL(for: missing).path))
        try session.appendPlainText("new content")
        XCTAssertEqual(try documents.load(id: newNote.id).string, "new content")
        XCTAssertEqual(try repository.allNotes().count, 2)
    }

    func testNewNoteHasARealDocumentAndDeletingLastNoteKeepsEditorUsable() throws {
        let (container, repository, documents, session) = try safetyFixture()
        _ = container
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        XCTAssertEqual(try documents.load(id: note.id).string, "")
        XCTAssertTrue(session.deleteRecovering(note))
        let replacement = try XCTUnwrap(session.currentNote)
        XCTAssertNotEqual(replacement.id, note.id)
        XCTAssertEqual(try repository.allNotes().count, 1)
        try session.appendPlainText("still editable")
        XCTAssertEqual(try documents.load(id: replacement.id).string, "still editable")
    }

    func testBackgroundAIFormattingRejectsImageOnlyEdit() throws {
        let (container, _, documents, session) = try safetyFixture()
        _ = container
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)
        func content(_ imageData: Data) -> NSAttributedString {
            let wrapper = FileWrapper(regularFileWithContents: imageData)
            wrapper.preferredFilename = "image.tiff"
            let text = NSMutableAttributedString(string: "Heading\n")
            text.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            return text
        }
        let original = content(try XCTUnwrap(testImage().tiffRepresentation))
        session.update(document: original, cursorLocation: 0)
        let revision = session.contentRevision(for: note.id)
        let changedImage = NSImage(size: NSSize(width: 8, height: 8))
        changedImage.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        changedImage.unlockFocus()
        let replacementImageData = try XCTUnwrap(changedImage.tiffRepresentation)
        session.update(document: content(replacementImageData), cursorLocation: 0)
        try session.createAndOpen()
        XCTAssertEqual(session.contentRevision(for: note.id), revision + 1)

        XCTAssertThrowsError(try session.saveAIFormattedDocument(original, replacing: original,
            expectedRevision: revision, for: note.id))
        let loaded = try documents.load(id: note.id)
        let attachment = try XCTUnwrap(loaded.attribute(.attachment, at: 8, effectiveRange: nil) as? NSTextAttachment)
        XCTAssertEqual(attachment.fileWrapper?.regularFileContents, replacementImageData)
    }

    private func searchField(in view: NSView, placeholder: String = "搜索标题、正文、标签") -> NSTextField? {
        if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
        return view.subviews.lazy.compactMap { self.searchField(in: $0, placeholder: placeholder) }.first
    }

    private func sendSearchKey(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                               to window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApp.sendEvent(event)
    }

    private func waitForSearchCondition(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(800))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func safetyFixture() throws -> (ModelContainer, NoteRepository, NoteDocumentStore, NoteSession) {
        let container = try ModelContainer(for: NoteRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repository = NoteRepository(context: container.mainContext)
        let documents = NoteDocumentStore(root: FileManager.default.temporaryDirectory
            .appending(path: "QuickNote-Safety-\(UUID().uuidString)"))
        return (container, repository, documents, NoteSession(repository: repository, documents: documents))
    }

    private func sessionEditorFixture() throws -> NotePersistenceSessionEditorFixture {
        let fixture = try NotePersistenceSessionEditorFixture()
        addTeardownBlock { @MainActor () async throws -> Void in
            try fixture.tearDown()
        }
        return fixture
    }
}

/// A UI callback can outlive a test's local variables. Keep the entire store alive until teardown.
@MainActor
private final class NotePersistenceSessionEditorFixture {
    let container: ModelContainer
    let documents: NoteDocumentStore
    let session: NoteSession
    private var isTornDown = false
    private var uiCleanups: [() -> Void] = []

    init() throws {
        container = try ModelContainer(for: NoteRecord.self, NoteFolder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        documents = NoteDocumentStore(root: FileManager.default.temporaryDirectory
            .appending(path: "QuickNote-SessionEditor-\(UUID().uuidString)"))
        session = NoteSession(repository: NoteRepository(context: container.mainContext), documents: documents)
    }

    func update(_ document: NSAttributedString, cursorLocation: Int) {
        guard !isTornDown else { return }
        session.update(document: document, cursorLocation: cursorLocation)
    }

    func addUICleanup(_ cleanup: @escaping () -> Void) { uiCleanups.append(cleanup) }

    func tearDown() throws {
        guard !isTornDown else { return }
        isTornDown = true
        let cleanups = uiCleanups
        uiCleanups.removeAll()
        for cleanup in cleanups.reversed() { cleanup() }
        // flush cancels NoteSession's debounce before its models or temporary RTFD are released.
        try session.flush()
        if FileManager.default.fileExists(atPath: documents.root.path) {
            try FileManager.default.removeItem(at: documents.root)
        }
        withExtendedLifetime(container) {}
    }
}

private enum TestError: Error {
    case saveFailed
}

@MainActor
private final class ProductUndoTextView: NSTextView {
    private let history = UndoManager()
    override var undoManager: UndoManager? { history }
}

private extension NSView {
    func descendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        return subviews.lazy.compactMap { $0.descendant(ofType: type) }.first
    }
}

private extension NSAttributedString {
    var attachmentCount: Int {
        var count = 0
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, _, _ in
            if value is NSTextAttachment { count += 1 }
        }
        return count
    }

    var tableBlockCount: Int {
        var count = 0
        enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: length)) { value, _, _ in
            let style = value as? NSParagraphStyle
            count += style?.textBlocks.compactMap { $0 as? NSTextTableBlock }.count ?? 0
        }
        return count
    }
}

private func testImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 2, height: 2).fill()
    image.unlockFocus()
    return image
}
