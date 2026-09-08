import AppKit

@MainActor
struct NoteDocumentStore {
    private static let formatMarker = "QuickNote-format-version"
    private static let headingMarker = "QuickNote-heading-version"
    private static let bodyWeightMarker = "QuickNote-body-weight-version"
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func load(id: UUID) throws -> NSAttributedString {
        let url = url(for: id)
        let document = try NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
        // Legacy typography is migrated in memory; the next normal save persists the version.
        // Reading never overwrites a user's document (including a damaged package).
        let normalized = FileManager.default.fileExists(atPath: url.appending(path: Self.formatMarker).path)
            ? document : NoteFontNormalizer.normalized(document)
        let headed = FileManager.default.fileExists(atPath: url.appending(path: Self.headingMarker).path)
            ? normalized : NoteHeadingNormalizer.normalized(normalized, promoteFirstLine: false)
        guard !FileManager.default.fileExists(atPath: url.appending(path: Self.bodyWeightMarker).path) else { return headed }
        let result = NSMutableAttributedString(attributedString: headed)
        let oldBody = NSFont.systemFont(ofSize: 13, weight: .light)
        headed.enumerateAttributes(in: NSRange(location: 0, length: headed.length)) { attributes, range, _ in
            guard attributes[.attachment] == nil, let font = attributes[.font] as? NSFont,
                  [oldBody.fontName, "HelveticaNeue-Light", "HelveticaNeue-LightItalic"].contains(font.fontName),
                  abs(font.pointSize - oldBody.pointSize) < 0.1 else { return }
            // RTF serializes AppKit's system Light font as HelveticaNeue-Light.
            let regular = font.fontDescriptor.symbolicTraits.contains(.italic)
                ? NSFontManager.shared.convert(EditorTextStyle.body.font, toHaveTrait: .italicFontMask)
                : EditorTextStyle.body.font
            result.addAttribute(.font, value: regular, range: range)
        }
        return result
    }

    func save(_ document: NSAttributedString, id: UUID) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let range = NSRange(location: 0, length: document.length)
        let wrapper = try document.fileWrapper(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        wrapper.addRegularFile(withContents: Data("1".utf8), preferredFilename: Self.formatMarker)
        wrapper.addRegularFile(withContents: Data("1".utf8), preferredFilename: Self.headingMarker)
        wrapper.addRegularFile(withContents: Data("1".utf8), preferredFilename: Self.bodyWeightMarker)
        try wrapper.write(to: url(for: id), options: .atomic, originalContentsURL: nil)
    }

    func delete(id: UUID) throws {
        let url = url(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func url(for id: UUID) -> URL {
        root.appending(path: "\(id.uuidString).rtfd")
    }
}

@MainActor
enum NoteHeadingNormalizer {
    /// Attributes only. Explicit sizes, links, code, lists and attachments remain untouched.
    static func normalized(_ document: NSAttributedString, promoteFirstLine: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: document)
        let string = document.string as NSString
        var paragraphs: [(range: NSRange, text: String, section: Bool)] = []
        var offset = 0
        while offset < string.length {
            let range = string.paragraphRange(for: NSRange(location: offset, length: 0))
            let text = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            let section = text.range(of: #"^(?:[一二三四五六七八九十百]+[、．.]|[（(][一二三四五六七八九十百]+[）)])\s*\S"#,
                                     options: .regularExpression) != nil
            paragraphs.append((range, text, section))
            offset = NSMaxRange(range)
        }
        let first = paragraphs.firstIndex { !$0.text.isEmpty }
        var fenced = false
        for (index, paragraph) in paragraphs.enumerated() {
            let text = paragraph.text
            if text.hasPrefix("```") || text.hasPrefix("~~~") { fenced.toggle(); continue }
            guard !fenced, !text.isEmpty, text.count <= 48,
                  !text.contains("|"), !text.contains("\u{fffc}"), !text.contains("://"),
                  !"。！？!?；;：:".contains(text.last!),
                  text.range(of: #"^(?:[0-9]+[.、)]\s*|[•◦☐☑*+-]\s|\[[ xX]\])"#, options: .regularExpression) == nil else { continue }
            let next = paragraphs.indices.dropFirst(index + 1).first { !paragraphs[$0].text.isEmpty }
            let separated = index == first || (index > 0 && paragraphs[index - 1].text.isEmpty)
            // ponytail: conservative plain-text headings; ambiguous prose stays body text.
            // Semantic Markdown headings are handled by the importer, not guessed here.
            let sectionHeading = paragraph.section && separated && next.map { !paragraphs[$0].section } == true
            let summaryHeading = !paragraph.section && separated && next.map { paragraphs[$0].section } == true
            let documentTitle = promoteFirstLine && index == first && !paragraph.section
            guard sectionHeading || summaryHeading || documentTitle else { continue }
            var eligible = true
            document.enumerateAttributes(in: paragraph.range) { attributes, _, stop in
                let font = attributes[.font] as? NSFont
                let style = attributes[.paragraphStyle] as? NSParagraphStyle
                if attributes[.attachment] != nil || attributes[.link] != nil
                    || font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true
                    || (font != nil && abs(font!.pointSize - EditorTextStyle.body.font.pointSize) > 0.1)
                    || !(style?.textBlocks.isEmpty ?? true) || !(style?.textLists.isEmpty ?? true) {
                    eligible = false
                    stop.pointee = true
                }
            }
            guard eligible else { continue }
            let base = documentTitle ? EditorTextStyle.title.font
                : (text.hasPrefix("（") || text.hasPrefix("(") ? EditorTextStyle.subheading.font : EditorTextStyle.heading.font)
            document.enumerateAttributes(in: paragraph.range) { attributes, range, _ in
                let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                var font = traits.contains(.bold) ? NSFont.systemFont(ofSize: base.pointSize, weight: .bold) : base
                if traits.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                result.addAttribute(.font, value: font, range: range)
            }
            let style = (document.attribute(.paragraphStyle, at: paragraph.range.location, effectiveRange: nil)
                         as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.paragraphSpacingBefore = index == first ? 0 : 8
            style.paragraphSpacing = 6
            result.addAttribute(.paragraphStyle, value: style, range: paragraph.range)
        }
        return result
    }
}

enum NoteFontNormalizer {
    static func normalized(_ document: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: document)
        let range = NSRange(location: 0, length: document.length)
        var fontRuns: [(NSFont, NSRange)] = []
        document.enumerateAttributes(in: range) { attributes, run, _ in
            guard attributes[.attachment] == nil,
                  let font = attributes[.font] as? NSFont else { return }
            fontRuns.append((font, run))
        }

        for (font, run) in fontRuns {
            let originalTraits = font.fontDescriptor.symbolicTraits
            let base: NSFont = if originalTraits.contains(.monoSpace) {
                EditorTextStyle.monospaced.font
            } else if font.pointSize >= 23 {
                EditorTextStyle.title.font
            } else if font.pointSize >= 18 {
                EditorTextStyle.heading.font
            } else if font.pointSize >= 15.5 {
                EditorTextStyle.subheading.font
            } else {
                EditorTextStyle.body.font
            }
            let legacyHeavyHeading = [26, 20, 17].contains { abs(font.pointSize - CGFloat($0)) < 0.1 }
            var normalized = base
            if originalTraits.contains(.bold), !legacyHeavyHeading {
                normalized = originalTraits.contains(.monoSpace)
                    ? .monospacedSystemFont(ofSize: base.pointSize, weight: .bold)
                    : .systemFont(ofSize: base.pointSize, weight: .bold)
            }
            if originalTraits.contains(.italic) {
                normalized = NSFontManager.shared.convert(normalized, toHaveTrait: .italicFontMask)
            }
            result.addAttribute(.font, value: normalized, range: run)
        }
        return result
    }
}
