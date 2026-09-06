import AppKit
import Combine
import SwiftData
import SwiftUI
import XCTest
@testable import QuickNote

@MainActor
final class NotePersistenceTests: XCTestCase {
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
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(160))
        view.layoutSubtreeIfNeeded()
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
        XCTAssertEqual(attachmentParagraph.paragraphSpacingBefore, 4)
        XCTAssertEqual(attachmentParagraph.paragraphSpacing, 4)
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
        XCTAssertEqual(bodyStyle?.lineHeightMultiple, 1.18)
        XCTAssertEqual(bodyStyle?.paragraphSpacing, 7)
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

    private func safetyFixture() throws -> (ModelContainer, NoteRepository, NoteDocumentStore, NoteSession) {
        let container = try ModelContainer(for: NoteRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repository = NoteRepository(context: container.mainContext)
        let documents = NoteDocumentStore(root: FileManager.default.temporaryDirectory
            .appending(path: "QuickNote-Safety-\(UUID().uuidString)"))
        return (container, repository, documents, NoteSession(repository: repository, documents: documents))
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
