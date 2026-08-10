import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private protocol ChecklistClickHandling: AnyObject {
    func toggleChecklist(at location: Int) -> Bool
    func openFileAttachment(at location: Int) -> Bool
}

private class InteractiveAttachmentCell: NSTextAttachmentCell {
    override func wantsToTrackMouse() -> Bool { true }
}

private final class ChecklistAttachmentCell: InteractiveAttachmentCell {
    override func trackMouse(
        with event: NSEvent,
        in cellFrame: NSRect,
        of controlView: NSView?,
        atCharacterIndex charIndex: Int,
        untilMouseUp flag: Bool
    ) -> Bool {
        guard let textView = controlView as? NSTextView,
              let handler = textView.delegate as? ChecklistClickHandling else { return false }
        return handler.toggleChecklist(at: charIndex)
    }
}

private final class FileAttachmentCell: InteractiveAttachmentCell {
    override func trackMouse(
        with event: NSEvent,
        in cellFrame: NSRect,
        of controlView: NSView?,
        atCharacterIndex charIndex: Int,
        untilMouseUp flag: Bool
    ) -> Bool {
        guard event.clickCount >= 2,
              let textView = controlView as? NSTextView,
              let handler = textView.delegate as? ChecklistClickHandling else { return false }
        return handler.openFileAttachment(at: charIndex)
    }
}

private final class ImageAttachmentCell: InteractiveAttachmentCell {
    override func trackMouse(
        with event: NSEvent,
        in cellFrame: NSRect,
        of controlView: NSView?,
        atCharacterIndex charIndex: Int,
        untilMouseUp flag: Bool
    ) -> Bool {
        guard let textView = controlView as? NSTextView,
              let handler = textView.delegate as? ChecklistClickHandling else { return false }
        return handler.openFileAttachment(at: charIndex)
    }
}

enum AttachmentPresentation {
    static let audioFilenamePrefix = "quicknote-audio--"
    static let audioFilenameSuffix = ".qnaudio"

    static func scaledSize(for original: NSSize, fitting maximum: NSSize) -> NSSize {
        guard original.width > 0, original.height > 0 else { return .zero }
        let scale = min(1, maximum.width / original.width, maximum.height / original.height)
        return NSSize(width: floor(original.width * scale), height: floor(original.height * scale))
    }

    static func scaledImage(_ image: NSImage, to size: NSSize) -> NSImage {
        guard image.size != size else { return image }
        let rendered = NSImage(size: size)
        rendered.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size))
        rendered.unlockFocus()
        return rendered
    }

    static func storedAudioFilename(for original: String) -> String {
        audioFilenamePrefix + original + audioFilenameSuffix
    }

    static func originalAudioFilename(from stored: String) -> String? {
        guard stored.hasPrefix(audioFilenamePrefix), stored.hasSuffix(audioFilenameSuffix) else {
            return nil
        }
        return String(stored.dropFirst(audioFilenamePrefix.count).dropLast(audioFilenameSuffix.count))
    }
}

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
    @Published private(set) var canUndo = false
    private var imagePreviewPanel: NSPanel?
    private var preparedAttachmentWidth: CGFloat?
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
    private static let listPrefix = try? NSRegularExpression(
        pattern: #"^([\t ]*)(\d+|[A-Za-z])\.\s+"#
    )

    func connect(_ textView: NSTextView) {
        self.textView = textView
        refreshUndoAvailability()
    }

    func undo() {
        textView?.undoManager?.undo()
        refreshUndoAvailability()
    }

    func clearUndoHistory() {
        textView?.undoManager?.removeAllActions()
        refreshUndoAvailability()
    }

    func refreshUndoAvailability() {
        canUndo = textView?.undoManager?.canUndo == true
    }

    func toggleBold() { toggleFontTrait(.boldFontMask) }
    func toggleItalic() { toggleFontTrait(.italicFontMask) }
    func toggleUnderline() { toggleDecoration(.underlineStyle) }
    func toggleStrikethrough() { toggleDecoration(.strikethroughStyle) }

    func applyTextStyle(_ style: EditorTextStyle) {
        guard let textView else { return }
        let range = paragraphRange(in: textView)
        if range.length == 0 {
            registerUndoSnapshot(in: textView)
            textView.typingAttributes[.font] = style.font
        } else {
            registerUndoSnapshot(in: textView)
            textView.textStorage?.addAttribute(.font, value: style.font, range: range)
            commit(textView, preserving: textView.selectedRange())
        }
    }

    func applyTextColor(_ color: NSColor) {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            registerUndoSnapshot(in: textView)
            textView.typingAttributes[.foregroundColor] = color
        } else {
            registerUndoSnapshot(in: textView)
            textView.textStorage?.addAttribute(.foregroundColor, value: color, range: range)
            commit(textView, preserving: range)
        }
    }

    func applyBackgroundColor(_ color: NSColor?) {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            if let color {
                registerUndoSnapshot(in: textView)
                textView.typingAttributes[.backgroundColor] = color
            } else {
                guard textView.typingAttributes[.backgroundColor] != nil else { return }
                registerUndoSnapshot(in: textView)
                textView.typingAttributes.removeValue(forKey: .backgroundColor)
            }
        } else {
            registerUndoSnapshot(in: textView)
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
            registerUndoSnapshot(in: textView)
            textView.typingAttributes[.paragraphStyle] = style
            return
        }
        registerUndoSnapshot(in: textView)
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
        registerUndoSnapshot(in: textView)
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
            registerUndoSnapshot(in: textView)
            textView.typingAttributes[.paragraphStyle] = style
            return
        }
        registerUndoSnapshot(in: textView)
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

    func prepareChecklistAttachments(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let range = NSRange(location: 0, length: storage.length)
        var items: [(Int, Bool)] = []
        storage.enumerateAttribute(.attachment, in: range) { value, range, _ in
            guard value is NSTextAttachment,
                  let checked = checklistState(at: range.location, in: storage) else { return }
            items.append((range.location, checked))
        }
        for (location, checked) in items.reversed() {
            storage.replaceCharacters(
                in: NSRange(location: location, length: 1),
                with: checklistMarker(checked: checked)
            )
        }
    }

    @discardableResult
    func continueListAfterNewline() -> Bool {
        guard let textView, let storage = textView.textStorage else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let paragraph = (storage.string as NSString).paragraphRange(for: selection)
        let beforeCursor = NSRange(
            location: paragraph.location,
            length: selection.location - paragraph.location
        )
        let line = (storage.string as NSString).substring(with: beforeCursor)
        let lineRange = NSRange(location: 0, length: (line as NSString).length)
        guard let match = Self.listPrefix?.firstMatch(in: line, range: lineRange) else { return false }
        if match.range.length == lineRange.length {
            registerUndoSnapshot(in: textView)
            storage.deleteCharacters(in: beforeCursor)
            commit(textView, preserving: NSRange(location: paragraph.location, length: 0))
            return true
        }
        let value = line as NSString
        let indentation = value.substring(with: match.range(at: 1))
        let marker = value.substring(with: match.range(at: 2))
        let next: String
        if let number = Int(marker) {
            next = String(number + 1)
        } else {
            guard let scalar = marker.unicodeScalars.first,
                  scalar.value != 90,
                  scalar.value != 122,
                  let following = UnicodeScalar(scalar.value + 1) else { return false }
            next = String(following)
        }
        var continuationAttributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
        continuationAttributes.removeValue(forKey: .link)
        continuationAttributes.removeValue(forKey: .attachment)
        let content = NSAttributedString(
            string: "\n\(indentation)\(next). ",
            attributes: continuationAttributes
        )
        registerUndoSnapshot(in: textView)
        storage.replaceCharacters(in: selection, with: content)
        commit(textView, preserving: NSRange(location: selection.location + content.length, length: 0))
        textView.typingAttributes = continuationAttributes
        return true
    }

    func applyDefaultParagraphSpacing(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let spacing: CGFloat = 4
        let fullRange = NSRange(location: 0, length: storage.length)
        enumerateParagraphs(in: fullRange, text: storage.string) { range in
            let style = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            guard style.textBlocks.isEmpty, style.paragraphSpacing == 0 else { return }
            style.paragraphSpacing = spacing
            storage.addAttribute(.paragraphStyle, value: style, range: range)
        }
        let cursor = textView.selectedRange().location
        let style = (cursor < storage.length
            ? storage.attribute(.paragraphStyle, at: cursor, effectiveRange: nil) as? NSParagraphStyle
            : textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        if style.textBlocks.isEmpty, style.paragraphSpacing == 0 {
            style.paragraphSpacing = spacing
        }
        textView.typingAttributes[.paragraphStyle] = style
    }

    func insertChecklistItem() {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let paragraph = (storage.string as NSString).paragraphRange(for: selection)
        if paragraph.location < storage.length,
           checklistState(at: paragraph.location, in: storage) != nil {
            return
        }
        registerUndoSnapshot(in: textView)
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
        registerUndoSnapshot(in: textView)
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
        registerUndoSnapshot(in: textView)
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
        registerUndoSnapshot(in: textView)
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
        registerUndoSnapshot(in: textView)
        storage.deleteCharacters(in: tableRange)
        commit(textView, preserving: NSRange(location: min(tableRange.location, storage.length), length: 0))
        return true
    }

    func insertFiles(_ urls: [URL]) throws {
        guard let textView, !urls.isEmpty else { return }
        let content = NSMutableAttributedString()
        let maximumWidth = attachmentWidth(in: textView)
        for url in urls {
            let type = UTType(filenameExtension: url.pathExtension)
            let attachment: NSTextAttachment
            if type?.conforms(to: .image) == true {
                attachment = try imageAttachment(
                    from: url,
                    fitting: NSSize(width: maximumWidth, height: min(520, maximumWidth * 0.85))
                )
            } else {
                let wrapper = try FileWrapper(url: url, options: .immediate)
                wrapper.preferredFilename = url.lastPathComponent
                attachment = configuredFileAttachment(
                    NSTextAttachment(fileWrapper: wrapper),
                    maximumWidth: maximumWidth
                )
            }
            let storedFilename = attachment.fileWrapper?.preferredFilename
                ?? attachment.fileWrapper?.filename
                ?? ""
            let paragraph = attachmentParagraphStyle(
                compact: AttachmentPresentation.originalAudioFilename(from: storedFilename) != nil
            )
            let item = NSMutableAttributedString(attachment: attachment)
            item.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: 1))
            content.append(item)
            content.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
        }
        replaceSelection(with: content, in: textView)
    }

    func prepareFileAttachments(in textView: NSTextView, force: Bool = true) {
        guard let storage = textView.textStorage else { return }
        let maximumWidth = attachmentWidth(in: textView)
        guard force || abs((preparedAttachmentWidth ?? 0) - maximumWidth) > 1 else { return }
        preparedAttachmentWidth = maximumWidth
        var attachmentParagraphs: [(range: NSRange, compact: Bool)] = []
        var replacements: [(range: NSRange, attachment: NSTextAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  let wrapper = attachment.fileWrapper else { return }
            let filename = wrapper.preferredFilename ?? wrapper.filename ?? "附件"
            guard !filename.hasPrefix("quicknote-checklist-") else { return }
            let compact = AttachmentPresentation.originalAudioFilename(from: filename) != nil
                || UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension)?
                    .conforms(to: .audio) == true
            attachmentParagraphs.append(
                ((storage.string as NSString).paragraphRange(for: range), compact)
            )
            let type = UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension)
            if type?.conforms(to: .image) == true,
               let data = wrapper.regularFileContents,
               let image = NSImage(data: data) {
                let size = AttachmentPresentation.scaledSize(
                    for: image.size,
                    fitting: NSSize(width: maximumWidth, height: min(520, maximumWidth * 0.85))
                )
                attachment.bounds = NSRect(origin: .zero, size: size)
                attachment.allowsTextAttachmentView = false
                attachment.attachmentCell = ImageAttachmentCell(
                    imageCell: AttachmentPresentation.scaledImage(image, to: size)
                )
            } else {
                let configured = configuredFileAttachment(attachment, maximumWidth: maximumWidth)
                if configured !== attachment {
                    replacements.append((range, configured))
                }
            }
        }
        for replacement in replacements {
            storage.addAttribute(.attachment, value: replacement.attachment, range: replacement.range)
        }
        for item in attachmentParagraphs {
            let existing = storage.attribute(.paragraphStyle, at: item.range.location, effectiveRange: nil)
                as? NSParagraphStyle
            storage.addAttribute(
                .paragraphStyle,
                value: attachmentParagraphStyle(from: existing, compact: item.compact),
                range: item.range
            )
        }
    }

    private func attachmentParagraphStyle(
        from existing: NSParagraphStyle? = nil,
        compact: Bool = false
    ) -> NSParagraphStyle {
        let style = existing?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.paragraphSpacingBefore = compact ? 3 : max(style.paragraphSpacingBefore, 8)
        style.paragraphSpacing = compact ? 5 : max(style.paragraphSpacing, 12)
        return style
    }

    func openFileAttachment(at location: Int) -> Bool {
        guard let textView, let storage = textView.textStorage,
              location >= 0, location < storage.length,
              let attachment = storage.attribute(.attachment, at: location, effectiveRange: nil)
                as? NSTextAttachment,
              let wrapper = attachment.fileWrapper,
              let data = wrapper.regularFileContents else { return false }
        let filename = URL(fileURLWithPath: wrapper.preferredFilename ?? wrapper.filename ?? "附件")
            .lastPathComponent
        let type = UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension)
        if type?.conforms(to: .image) == true, let image = NSImage(data: data) {
            showImagePreview(image, title: filename)
            return true
        }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "QuickNote-Attachments")
                .appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: filename)
            try data.write(to: url, options: .atomic)
            return NSWorkspace.shared.open(url)
        } catch {
            return false
        }
    }

    private func showImagePreview(_ image: NSImage, title: String) {
        let visibleFrame = (textView?.window?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let imageSize = AttachmentPresentation.scaledSize(
            for: image.size,
            fitting: NSSize(
                width: min(1_000, visibleFrame.width - 120),
                height: min(720, visibleFrame.height - 160)
            )
        )
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.setContentSize(NSSize(
            width: max(420, imageSize.width + 40),
            height: max(280, imageSize.height + 40)
        ))
        panel.minSize = NSSize(width: 320, height: 220)
        let imageView = NSImageView(frame: panel.contentView?.bounds.insetBy(dx: 20, dy: 20) ?? .zero)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyDown
        imageView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(imageView)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - panel.frame.width / 2,
            y: visibleFrame.midY - panel.frame.height / 2
        ))
        imagePreviewPanel?.close()
        imagePreviewPanel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func imageAttachment(from url: URL, fitting maximum: NSSize) throws -> NSTextAttachment {
        guard let source = NSImage(contentsOf: url) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let size = AttachmentPresentation.scaledSize(for: source.size, fitting: maximum)
        guard size.width > 0, size.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let rendered = NSImage(size: size)
        rendered.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: size))
        rendered.unlockFocus()
        guard let tiff = rendered.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let format: NSBitmapImageRep.FileType = bitmap.hasAlpha ? .png : .jpeg
        let properties: [NSBitmapImageRep.PropertyKey: Any] = format == .jpeg
            ? [.compressionFactor: 0.82]
            : [:]
        guard let data = bitmap.representation(using: format, properties: properties) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let wrapper = FileWrapper(regularFileWithContents: data)
        let baseName = url.deletingPathExtension().lastPathComponent
        wrapper.preferredFilename = "\(baseName).\(format == .jpeg ? "jpg" : "png")"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        attachment.bounds = NSRect(origin: .zero, size: size)
        attachment.allowsTextAttachmentView = false
        attachment.attachmentCell = ImageAttachmentCell(imageCell: NSImage(data: data))
        return attachment
    }

    private func configuredFileAttachment(
        _ attachment: NSTextAttachment,
        maximumWidth: CGFloat
    ) -> NSTextAttachment {
        guard let wrapper = attachment.fileWrapper else { return attachment }
        let filename = wrapper.preferredFilename ?? wrapper.filename ?? "附件"
        let type = UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension)
        if let audio = attachment as? AudioTextAttachment {
            audio.maximumWidth = min(maximumWidth, 420)
            audio.bounds = NSRect(x: 0, y: 0, width: audio.maximumWidth, height: 34)
            return audio
        }
        if AttachmentPresentation.originalAudioFilename(from: filename) != nil
            || type?.conforms(to: .audio) == true {
            if AttachmentPresentation.originalAudioFilename(from: filename) == nil {
                wrapper.preferredFilename = AttachmentPresentation.storedAudioFilename(for: filename)
            }
            let audio = AudioTextAttachment(audioFileWrapper: wrapper)
            audio.maximumWidth = min(maximumWidth, 420)
            audio.bounds = NSRect(x: 0, y: 0, width: audio.maximumWidth, height: 34)
            return audio
        }
        let kind: String
        if type?.conforms(to: .movie) == true {
            kind = "视频"
        } else {
            kind = "文档"
        }
        let size = NSSize(width: min(maximumWidth, 420), height: 58)
        let card = NSImage(size: size)
        card.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9).fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        border.lineWidth = 1
        border.stroke()
        let icon = NSWorkspace.shared.icon(for: type ?? .data)
        icon.size = NSSize(width: 32, height: 32)
        icon.draw(in: NSRect(x: 13, y: 13, width: 32, height: 32))
        (filename as NSString).draw(
            in: NSRect(x: 56, y: 29, width: size.width - 68, height: 18),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        ("\(kind) · 双击打开" as NSString).draw(
            in: NSRect(x: 56, y: 11, width: size.width - 68, height: 16),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        card.unlockFocus()
        attachment.bounds = NSRect(origin: .zero, size: size)
        attachment.attachmentCell = FileAttachmentCell(imageCell: card)
        return attachment
    }

    private func attachmentWidth(in textView: NSTextView) -> CGFloat {
        let width = max(
            textView.enclosingScrollView?.contentSize.width ?? 0,
            textView.bounds.width,
            textView.visibleRect.width
        )
        return min(560, max(120, width > 32 ? width - 32 : 560))
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        let manager = NSFontManager.shared
        let reference = font(at: range.location, in: textView)
        let removing = manager.traits(of: reference).contains(trait)
        if range.length == 0 {
            registerUndoSnapshot(in: textView)
            textView.typingAttributes[.font] = removing
                ? manager.convert(reference, toNotHaveTrait: trait)
                : manager.convert(reference, toHaveTrait: trait)
            return
        }
        var runs: [(NSFont, NSRange)] = []
        storage.enumerateAttribute(.font, in: range) { value, run, _ in
            runs.append((value as? NSFont ?? textView.font ?? .systemFont(ofSize: 15), run))
        }
        registerUndoSnapshot(in: textView)
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
            registerUndoSnapshot(in: textView)
            textView.typingAttributes[key] = active ? 0 : NSUnderlineStyle.single.rawValue
        } else {
            registerUndoSnapshot(in: textView)
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
        let wrapper = FileWrapper(regularFileWithContents: png ?? Data())
        wrapper.preferredFilename = "quicknote-checklist-\(checked ? "checked" : "unchecked").png"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        attachment.bounds = NSRect(x: 0, y: -2, width: 15, height: 15)
        attachment.attachmentCell = ChecklistAttachmentCell(imageCell: png.flatMap(NSImage.init(data:)))
        return NSAttributedString(attachment: attachment)
    }

    private func checklistState(at location: Int, in storage: NSTextStorage) -> Bool? {
        guard location >= 0, location < storage.length,
              let attachment = storage.attribute(.attachment, at: location, effectiveRange: nil)
                as? NSTextAttachment else { return nil }
        let filename = attachment.fileWrapper?.preferredFilename ?? attachment.fileWrapper?.filename
        if filename == "quicknote-checklist-checked.png" { return true }
        if filename == "quicknote-checklist-unchecked.png" { return false }
        guard let url = storage.attribute(.link, at: location, effectiveRange: nil) as? URL,
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
        registerUndoSnapshot(in: textView)
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

    private func registerUndoSnapshot(in textView: NSTextView) {
        let document = NSAttributedString(attributedString: textView.attributedString())
        let selection = textView.selectedRange()
        let typingAttributes = textView.typingAttributes
        textView.undoManager?.registerUndo(withTarget: self) { [weak textView] controller in
            guard let textView else { return }
            controller.registerUndoSnapshot(in: textView)
            textView.textStorage?.setAttributedString(document)
            controller.commit(textView, preserving: selection)
            textView.typingAttributes = typingAttributes
        }
        textView.undoManager?.setActionName("编辑")
        refreshUndoAvailability()
    }
}

struct RichTextEditor: NSViewRepresentable {
    let document: NSAttributedString
    let cursorLocation: Int
    let controller: RichTextEditorController
    let onChange: (NSAttributedString, Int) -> Void
    let onActivate: () -> Void
    var backgroundColor: NSColor = .textBackgroundColor
    var textColor: NSColor = .textColor
    var overridesDocumentTextColor = false

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
        controller.prepareChecklistAttachments(in: textView)
        controller.prepareFileAttachments(in: textView)
        controller.detectLinks(in: textView)
        textView.setSelectedRange(NSRange(location: clampedCursorLocation, length: 0))
        controller.applyDefaultParagraphSpacing(in: textView)
        applyTheme(to: scroll, textView: textView)
        context.coordinator.recordAttachmentCount(in: textView)
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            controller.prepareFileAttachments(in: textView, force: false)
        }
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.owner = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        applyTheme(to: scroll, textView: textView)
        controller.connect(textView)
        if !textView.attributedString().isEqual(to: document) {
            textView.textStorage?.setAttributedString(document)
            controller.prepareChecklistAttachments(in: textView)
            controller.prepareFileAttachments(in: textView)
            controller.detectLinks(in: textView)
            controller.applyDefaultParagraphSpacing(in: textView)
            context.coordinator.recordAttachmentCount(in: textView)
        } else {
            controller.prepareFileAttachments(in: textView, force: false)
        }
        if textView.selectedRange().location != clampedCursorLocation {
            textView.setSelectedRange(NSRange(location: clampedCursorLocation, length: 0))
        }
    }

    private func applyTheme(to scroll: NSScrollView, textView: NSTextView) {
        scroll.drawsBackground = true
        scroll.backgroundColor = backgroundColor
        textView.drawsBackground = true
        textView.backgroundColor = backgroundColor
        textView.insertionPointColor = textColor
        guard let layoutManager = textView.layoutManager else { return }
        let range = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        if overridesDocumentTextColor, range.length > 0 {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: textColor, forCharacterRange: range)
        }
    }

    private var clampedCursorLocation: Int {
        min(max(cursorLocation, 0), document.length)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, ChecklistClickHandling {
        var owner: RichTextEditor
        private var attachmentCount = 0

        init(owner: RichTextEditor) { self.owner = owner }

        func textDidBeginEditing(_ notification: Notification) {
            owner.onActivate()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let newCount = countAttachments(in: textView)
            if newCount != attachmentCount {
                let insertedAttachment = newCount > attachmentCount
                attachmentCount = newCount
                owner.controller.prepareFileAttachments(in: textView)
                if insertedAttachment { moveCaretOutsideAttachment(in: textView) }
            }
            owner.controller.refreshUndoAvailability()
            owner.onChange(textView.attributedString(), textView.selectedRange().location)
        }

        private func moveCaretOutsideAttachment(in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            guard selection.length == 0, selection.location > 0,
                  storage.attribute(.attachment, at: selection.location - 1, effectiveRange: nil)
                    is NSTextAttachment else { return }
            if selection.location < storage.length,
               (storage.string as NSString).character(at: selection.location) == 10 {
                textView.setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            } else {
                storage.insert(NSAttributedString(string: "\n"), at: selection.location)
                textView.setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            }
        }

        func recordAttachmentCount(in textView: NSTextView) {
            attachmentCount = countAttachments(in: textView)
        }

        private func countAttachments(in textView: NSTextView) -> Int {
            guard let storage = textView.textStorage else { return 0 }
            var count = 0
            storage.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: storage.length)
            ) { value, _, _ in
                if value is NSTextAttachment { count += 1 }
            }
            return count
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            return owner.controller.continueListAfterNewline()
        }

        func toggleChecklist(at location: Int) -> Bool {
            owner.controller.toggleChecklistItem(at: location)
        }

        func openFileAttachment(at location: Int) -> Bool {
            owner.controller.openFileAttachment(at: location)
        }

    }
}
