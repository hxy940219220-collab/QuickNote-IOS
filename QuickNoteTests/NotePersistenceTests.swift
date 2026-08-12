import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import QuickNote

@MainActor
final class NotePersistenceTests: XCTestCase {
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
        XCTAssertEqual((document.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 26)

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

        XCTAssertEqual((textView.typingAttributes[.font] as? NSFont)?.pointSize, 26)
        textView.insertText("标题", replacementRange: textView.selectedRange())
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        textView.insertText("正文", replacementRange: textView.selectedRange())

        let titleFont = try XCTUnwrap(document.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let bodyLocation = (document.string as NSString).range(of: "正文").location
        let bodyFont = try XCTUnwrap(
            document.attribute(.font, at: bodyLocation, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(titleFont.pointSize, 26)
        XCTAssertTrue(NSFontManager.shared.traits(of: titleFont).contains(.boldFontMask))
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
        XCTAssertEqual(attachmentParagraph.paragraphSpacingBefore, 8)
        XCTAssertEqual(attachmentParagraph.paragraphSpacing, 12)
        XCTAssertTrue(attachments.allSatisfy { $0.fileWrapper?.regularFileContents != nil })
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
        XCTAssertEqual(paragraph.paragraphSpacingBefore, 3)
        XCTAssertEqual(paragraph.paragraphSpacing, 5)
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

    func testDeleteCurrentTableFindsTableWhenCaretIsBelowIt() throws {
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

        XCTAssertTrue(controller.deleteCurrentTable())
        XCTAssertEqual(document.tableBlockCount, 0)
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
        try Data().write(to: root)
        let documents = NoteDocumentStore(root: root)
        let session = NoteSession(repository: repository, documents: documents)
        try session.createAndOpen()
        let note = try XCTUnwrap(session.currentNote)

        session.update(document: NSAttributedString(string: "不能丢的内容"), cursorLocation: 6)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(session.isDirty)
        XCTAssertNotNil(session.saveError)
        XCTAssertEqual(session.document.string, "不能丢的内容")
        XCTAssertEqual(note.plainText, "")

        try FileManager.default.removeItem(at: root)
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
        try Data().write(to: root)
        let session = NoteSession(repository: repository, documents: NoteDocumentStore(root: root))
        try session.createAndOpen()
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

private enum TestError: Error {
    case saveFailed
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
