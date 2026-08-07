import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import QuickNote

@MainActor
final class NotePersistenceTests: XCTestCase {
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
        XCTAssertLessThan(try XCTUnwrap(image.fileWrapper?.regularFileContents).count, originalImageData.count)
        XCTAssertEqual(attachments[1].bounds.height, 40)
        XCTAssertGreaterThanOrEqual(attachments[1].bounds.width, 320)
        XCTAssertFalse(attachments[1].allowsTextAttachmentView)
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

        let textView = try XCTUnwrap(host.descendant(ofType: NSTextView.self))
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
            in: NSRect(x: 0, y: 0, width: 15, height: 15),
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

    func testEditorAppliesComfortableDefaultParagraphSpacing() throws {
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
