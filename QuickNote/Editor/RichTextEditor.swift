import AppKit
import SwiftUI

enum EditorTextStyle: String, CaseIterable, Identifiable {
    case title
    case heading
    case subheading
    case body
    case monospaced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .title: "标题"
        case .heading: "小标题"
        case .subheading: "副标题"
        case .body: "正文"
        case .monospaced: "等宽样式"
        }
    }

    var font: NSFont {
        switch self {
        case .title: .systemFont(ofSize: 26, weight: .bold)
        case .heading: .systemFont(ofSize: 20, weight: .bold)
        case .subheading: .systemFont(ofSize: 17, weight: .semibold)
        case .body: .systemFont(ofSize: 15)
        case .monospaced: .monospacedSystemFont(ofSize: 15, weight: .regular)
        }
    }
}

@MainActor
final class RichTextEditorController: ObservableObject {
    private weak var textView: NSTextView?
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    func connect(_ textView: NSTextView) {
        self.textView = textView
    }

    func toggleBold() { toggleFontTrait(.boldFontMask) }
    func toggleItalic() { toggleFontTrait(.italicFontMask) }
    func toggleUnderline() { toggleDecoration(.underlineStyle) }
    func toggleStrikethrough() { toggleDecoration(.strikethroughStyle) }

    func applyTextStyle(_ style: EditorTextStyle) {
        guard let textView else { return }
        let range = paragraphRange(in: textView)
        if range.length == 0 {
            textView.typingAttributes[.font] = style.font
        } else {
            textView.textStorage?.addAttribute(.font, value: style.font, range: range)
            commit(textView, preserving: textView.selectedRange())
        }
    }

    func applyTextColor(_ color: NSColor) {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            textView.typingAttributes[.foregroundColor] = color
        } else {
            textView.textStorage?.addAttribute(.foregroundColor, value: color, range: range)
            commit(textView, preserving: range)
        }
    }

    func applyBackgroundColor(_ color: NSColor?) {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            if let color {
                textView.typingAttributes[.backgroundColor] = color
            } else {
                textView.typingAttributes.removeValue(forKey: .backgroundColor)
            }
        } else {
            if let color {
                textView.textStorage?.addAttribute(.backgroundColor, value: color, range: range)
            } else {
                textView.textStorage?.removeAttribute(.backgroundColor, range: range)
            }
            commit(textView, preserving: range)
        }
    }

    func applyAlignment(_ alignment: NSTextAlignment) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let target = paragraphRange(in: textView)
        if target.length == 0 {
            let style = (textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.alignment = alignment
            textView.typingAttributes[.paragraphStyle] = style
            return
        }
        enumerateParagraphs(in: target, text: storage.string) { range in
            let style = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.alignment = alignment
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        commit(textView, preserving: selection)
    }

    func changeIndent(by amount: CGFloat) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let target = paragraphRange(in: textView)
        guard target.length > 0 else { return }
        enumerateParagraphs(in: target, text: storage.string) { range in
            let style = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            let indent = max(0, style.headIndent + amount)
            let delta = indent - style.headIndent
            style.headIndent = indent
            style.firstLineHeadIndent = max(0, style.firstLineHeadIndent + delta)
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        commit(textView, preserving: selection)
    }

    func applyLineHeightMultiple(_ multiple: CGFloat) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let target = paragraphRange(in: textView)
        let value = max(1, multiple)
        if target.length == 0 {
            let style = (textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineHeightMultiple = value
            textView.typingAttributes[.paragraphStyle] = style
            return
        }
        enumerateParagraphs(in: target, text: storage.string) { range in
            let style = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineHeightMultiple = value
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        commit(textView, preserving: selection)
    }

    func detectLinks(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let range = NSRange(location: 0, length: storage.length)
        Self.linkDetector?.enumerateMatches(in: storage.string, range: range) { result, _, _ in
            guard let result, let url = result.url,
                  storage.attribute(.link, at: result.range.location, effectiveRange: nil) == nil else { return }
            storage.addAttribute(.link, value: url, range: result.range)
        }
    }

    func insertChecklistItem() {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let paragraph = (storage.string as NSString).paragraphRange(for: selection)
        if paragraph.location < storage.length,
           checklistState(at: paragraph.location, in: storage) != nil {
            return
        }
        let marker = checklistMarker(checked: false)
        let content = NSMutableAttributedString(attributedString: marker)
        content.append(NSAttributedString(string: " "))
        storage.insert(content, at: paragraph.location)
        commit(
            textView,
            preserving: NSRange(location: selection.location + content.length, length: selection.length)
        )
    }

    @discardableResult
    func toggleChecklistItem(at location: Int) -> Bool {
        guard let textView,
              let storage = textView.textStorage,
              let checked = checklistState(at: location, in: storage) else { return false }
        storage.replaceCharacters(
            in: NSRange(location: location, length: 1),
            with: checklistMarker(checked: !checked)
        )
        commit(textView, preserving: textView.selectedRange())
        return true
    }

    func applyList(_ marker: NSTextList.MarkerFormat?) {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let target = paragraphRange(in: textView)
        guard target.length > 0 else { return }
        enumerateParagraphs(in: target, text: storage.string) { range in
            let existing = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            existing.textLists = marker.map { [NSTextList(markerFormat: $0, options: 0)] } ?? []
            existing.headIndent = marker == nil ? 0 : 22
            existing.firstLineHeadIndent = 0
            storage.addAttribute(.paragraphStyle, value: existing, range: range)
        }
        commit(textView, preserving: selection)
    }

    func applyBlockQuote() {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let target = paragraphRange(in: textView)
        guard target.length > 0 else { return }
        enumerateParagraphs(in: target, text: storage.string) { range in
            let existing = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            existing.headIndent = existing.headIndent == 18 ? 0 : 18
            existing.firstLineHeadIndent = existing.headIndent
            storage.addAttribute(.paragraphStyle, value: existing, range: range)
        }
        commit(textView, preserving: selection)
    }

    func insertTable(rows: Int = 2, columns: Int = 2) {
        guard let textView else { return }
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        let content = NSMutableAttributedString()
        let selection = textView.selectedRange()
        if selection.location > 0,
           (textView.string as NSString).substring(with: NSRange(location: selection.location - 1, length: 1)) != "\n" {
            content.append(NSAttributedString(string: "\n"))
        }
        for row in 0..<rows {
            for column in 0..<columns {
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: row,
                    rowSpan: 1,
                    startingColumn: column,
                    columnSpan: 1
                )
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                if row == 0 {
                    block.setWidth(8, type: .absoluteValueType, for: .margin, edge: .minY)
                }
                if row == rows - 1 {
                    block.setWidth(8, type: .absoluteValueType, for: .margin, edge: .maxY)
                }
                block.setBorderColor(.separatorColor)
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                content.append(NSAttributedString(
                    string: " \n",
                    attributes: [.font: NSFont.systemFont(ofSize: 15), .paragraphStyle: paragraph]
                ))
            }
        }
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.paragraphSpacingBefore = 2
        content.append(NSAttributedString(
            string: " \n",
            attributes: [.font: NSFont.systemFont(ofSize: 15), .paragraphStyle: bodyParagraph]
        ))
        replaceSelection(
            with: content,
            in: textView,
            selecting: NSRange(location: content.length - 2, length: 1)
        )
    }

    @discardableResult
    func deleteCurrentTable() -> Bool {
        guard let textView, let storage = textView.textStorage, storage.length > 0 else { return false }
        let cursor = min(textView.selectedRange().location, storage.length - 1)
        let style = storage.attribute(.paragraphStyle, at: cursor, effectiveRange: nil) as? NSParagraphStyle
        var table = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first?.table
        var nearestDistance = Int.max
        if table == nil {
            storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) {
                value, range, _ in
                guard let candidate = (value as? NSParagraphStyle)?.textBlocks
                    .compactMap({ $0 as? NSTextTableBlock }).first else { return }
                let distance = cursor < range.location
                    ? range.location - cursor
                    : max(0, cursor - NSMaxRange(range))
                if distance < nearestDistance {
                    nearestDistance = distance
                    table = candidate.table
                }
            }
        }
        guard let table else { return false }
        var tableRange = NSRange(location: NSNotFound, length: 0)
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            let blocks = (value as? NSParagraphStyle)?.textBlocks.compactMap { $0 as? NSTextTableBlock } ?? []
            guard blocks.contains(where: { $0.table === table }) else { return }
            tableRange = tableRange.location == NSNotFound ? range : NSUnionRange(tableRange, range)
        }
        guard tableRange.location != NSNotFound else { return false }
        storage.deleteCharacters(in: tableRange)
        commit(textView, preserving: NSRange(location: min(tableRange.location, storage.length), length: 0))
        return true
    }

    func insertFiles(_ urls: [URL]) throws {
        guard let textView, !urls.isEmpty else { return }
        let content = NSMutableAttributedString()
        for url in urls {
            let wrapper = try FileWrapper(url: url, options: .immediate)
            wrapper.preferredFilename = url.lastPathComponent
            content.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            content.append(NSAttributedString(string: "\n"))
        }
        replaceSelection(with: content, in: textView)
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let manager = NSFontManager.shared
        let reference = font(at: range.location, in: textView)
        let removing = manager.traits(of: reference).contains(trait)
        if range.length == 0 {
            textView.typingAttributes[.font] = removing
                ? manager.convert(reference, toNotHaveTrait: trait)
                : manager.convert(reference, toHaveTrait: trait)
            return
        }
        var runs: [(NSFont, NSRange)] = []
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            runs.append((value as? NSFont ?? textView.font ?? .systemFont(ofSize: 15), run))
        }
        for (font, run) in runs {
            storage.addAttribute(
                .font,
                value: removing
                    ? manager.convert(font, toNotHaveTrait: trait)
                    : manager.convert(font, toHaveTrait: trait),
                range: run
            )
        }
        commit(textView, preserving: range)
    }

    private func toggleDecoration(_ key: NSAttributedString.Key) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let active = ((attribute(key, at: range.location, in: textView) as? NSNumber)?.intValue ?? 0) != 0
        if range.length == 0 {
            textView.typingAttributes[key] = active ? 0 : NSUnderlineStyle.single.rawValue
        } else {
            if active {
                storage.removeAttribute(key, range: range)
            } else {
                storage.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            commit(textView, preserving: range)
        }
    }

    private func font(at location: Int, in textView: NSTextView) -> NSFont {
        attribute(.font, at: location, in: textView) as? NSFont
            ?? textView.typingAttributes[.font] as? NSFont
            ?? textView.font
            ?? .systemFont(ofSize: 15)
    }

    private func checklistMarker(checked: Bool) -> NSAttributedString {
        let image = NSImage(size: NSSize(width: 15, height: 15))
        image.lockFocus()
        let circle = NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 12, height: 12))
        if checked {
            NSColor.controlAccentColor.setFill()
            circle.fill()
            let checkmark = NSBezierPath()
            checkmark.move(to: NSPoint(x: 4.2, y: 7.4))
            checkmark.line(to: NSPoint(x: 6.5, y: 5.2))
            checkmark.line(to: NSPoint(x: 10.9, y: 10))
            checkmark.lineWidth = 1.6
            checkmark.lineCapStyle = .round
            checkmark.lineJoinStyle = .round
            NSColor.white.setStroke()
            checkmark.stroke()
        } else {
            circle.lineWidth = 1.5
            NSColor.tertiaryLabelColor.setStroke()
            circle.stroke()
        }
        image.unlockFocus()
        let png = image.tiffRepresentation
            .flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:])
        let attachment = NSTextAttachment(data: png, ofType: "public.png")
        if let png {
            attachment.image = NSImage(data: png)
        }
        attachment.bounds = NSRect(x: 0, y: -2, width: 15, height: 15)
        attachment.attachmentCell = NSTextAttachmentCell(imageCell: attachment.image)
        let marker = NSMutableAttributedString(attachment: attachment)
        marker.addAttribute(
            .link,
            value: URL(string: "quicknote-checklist://\(checked ? "checked" : "unchecked")")!,
            range: NSRange(location: 0, length: marker.length)
        )
        return marker
    }

    private func checklistState(at location: Int, in storage: NSTextStorage) -> Bool? {
        guard location >= 0, location < storage.length,
              let url = storage.attribute(.link, at: location, effectiveRange: nil) as? URL,
              url.scheme == "quicknote-checklist" else { return nil }
        return url.host == "checked"
    }

    private func attribute(_ key: NSAttributedString.Key, at location: Int, in textView: NSTextView) -> Any? {
        guard let storage = textView.textStorage, storage.length > 0 else {
            return textView.typingAttributes[key]
        }
        return storage.attribute(key, at: min(location, storage.length - 1), effectiveRange: nil)
    }

    private func paragraphRange(in textView: NSTextView) -> NSRange {
        let selection = textView.selectedRange()
        return (textView.string as NSString).paragraphRange(for: selection)
    }

    private func enumerateParagraphs(in range: NSRange, text: String, body: (NSRange) -> Void) {
        let value = text as NSString
        var location = range.location
        while location < NSMaxRange(range) {
            let paragraph = value.paragraphRange(for: NSRange(location: location, length: 0))
            body(paragraph)
            location = NSMaxRange(paragraph)
        }
    }

    private func replaceSelection(
        with content: NSAttributedString,
        in textView: NSTextView,
        selecting relativeSelection: NSRange? = nil
    ) {
        let range = textView.selectedRange()
        textView.textStorage?.replaceCharacters(in: range, with: content)
        let selection = relativeSelection.map {
            NSRange(location: range.location + $0.location, length: $0.length)
        } ?? NSRange(location: range.location + content.length, length: 0)
        commit(textView, preserving: selection)
    }

    private func commit(_ textView: NSTextView, preserving selection: NSRange) {
        textView.setSelectedRange(selection)
        textView.didChangeText()
        textView.window?.makeFirstResponder(textView)
    }
}

struct RichTextEditor: NSViewRepresentable {
    let document: NSAttributedString
    let cursorLocation: Int
    let controller: RichTextEditorController
    let onChange: (NSAttributedString, Int) -> Void
    let onActivate: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.delegate = context.coordinator
        controller.connect(textView)
        textView.textStorage?.setAttributedString(document)
        controller.detectLinks(in: textView)
        textView.setSelectedRange(NSRange(location: clampedCursorLocation, length: 0))
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.owner = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        controller.connect(textView)
        if !textView.attributedString().isEqual(to: document) {
            textView.textStorage?.setAttributedString(document)
            controller.detectLinks(in: textView)
        }
        if textView.selectedRange().location != clampedCursorLocation {
            textView.setSelectedRange(NSRange(location: clampedCursorLocation, length: 0))
        }
    }

    private var clampedCursorLocation: Int {
        min(max(cursorLocation, 0), document.length)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: RichTextEditor

        init(owner: RichTextEditor) { self.owner = owner }

        func textDidBeginEditing(_ notification: Notification) {
            owner.onActivate()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            owner.onChange(textView.attributedString(), textView.selectedRange().location)
        }

        func textView(
            _ textView: NSTextView,
            clickedOn cell: any NSTextAttachmentCellProtocol,
            in cellFrame: NSRect,
            at charIndex: Int
        ) {
            owner.controller.toggleChecklistItem(at: charIndex)
        }

    }
}
