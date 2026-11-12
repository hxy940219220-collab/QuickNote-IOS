import AppKit
import UniformTypeIdentifiers

@MainActor
enum NoteMarkdownExporter {
    static let maximumCharacters = 50_000

    static func export(_ document: NSAttributedString) -> (markdown: String, truncated: Bool) {
        let text = document.string as NSString
        var blocks: [String] = []
        var codeLines: [String] = []
        var offset = 0

        while offset < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: offset, length: 0))
            offset = NSMaxRange(paragraph)
            let raw = text.substring(with: paragraph)
            let line = raw.trimmingCharacters(in: .newlines)
            let range = NSRange(location: paragraph.location, length: line.utf16.count)
            if isCodeLine(document, range: range.length == 0 ? paragraph : range) {
                codeLines.append(line)
                continue
            }
            flushCode(&codeLines, into: &blocks)
            blocks.append(renderLine(line, range: range, text: text, in: document))
        }
        flushCode(&codeLines, into: &blocks)

        // A scalar limit also bounds the encoded response for composed and escaped text.
        let markdown = blocks.joined(separator: "\n")
        let prefix = String(markdown.unicodeScalars.prefix(maximumCharacters))
        return (prefix, prefix != markdown)
    }

    private static func flushCode(_ lines: inout [String], into blocks: inout [String]) {
        guard !lines.isEmpty else { return }
        let code = lines.joined(separator: "\n")
        let fence = delimiter(for: code, minimum: 3)
        blocks.append("\(fence)\n\(code)\n\(fence)")
        lines.removeAll(keepingCapacity: true)
    }

    private static func isCodeLine(_ document: NSAttributedString, range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        var allMonospaced = true
        document.enumerateAttributes(in: range) { attributes, _, stop in
            guard let font = attributes[.font] as? NSFont,
                  font.fontDescriptor.symbolicTraits.contains(.monoSpace),
                  attributes[.attachment] == nil, attributes[.link] == nil else {
                allMonospaced = false
                stop.pointee = true
                return
            }
        }
        return allMonospaced
    }

    private static func renderLine(
        _ line: String, range: NSRange, text: NSString, in document: NSAttributedString
    ) -> String {
        guard range.length > 0 else { return "" }
        var body = range
        var prefix = ""
        if let marker = checklistPrefix(document.attributes(at: range.location, effectiveRange: nil)) {
            prefix = marker
            let length = line.hasPrefix("\u{fffc} ") ? 2 : 1
            body = NSRange(location: range.location + length, length: range.length - length)
        } else if let marker = line.range(of: #"^[\t ]*(?:[•◦–]|[0-9]+\.) "#, options: .regularExpression) {
            let source = String(line[marker])
            let indentation = source.prefix { $0 == " " || $0 == "\t" }
            let item = source.dropFirst(indentation.count)
            prefix = item.hasPrefix("◦") ? "\(indentation)    - " :
                (item.hasPrefix("•") || item.hasPrefix("–") ? "\(indentation)- " : source)
            body = NSRange(location: range.location + source.utf16.count, length: range.length - source.utf16.count)
        } else if let font = document.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont {
            let headings: [EditorTextStyle] = [.title, .heading, .subheading]
            if let level = headings.firstIndex(where: { abs($0.font.pointSize - font.pointSize) < 0.1 }) {
                prefix = String(repeating: "#", count: level + 1) + " "
            }
        }

        var result = prefix
        document.enumerateAttributes(in: body) { attributes, run, _ in
            result += renderRun(text.substring(with: run), attributes: attributes)
        }
        return result
    }

    private static func checklistPrefix(_ attributes: [NSAttributedString.Key: Any]) -> String? {
        guard let attachment = attributes[.attachment] as? NSTextAttachment else { return nil }
        switch attachment.fileWrapper?.preferredFilename ?? attachment.fileWrapper?.filename {
        case "quicknote-checklist-checked.png": return "- [x] "
        case "quicknote-checklist-unchecked.png": return "- [ ] "
        default:
            guard let link = attributes[.link] as? URL, link.scheme == "quicknote-checklist" else { return nil }
            return link.host == "checked" ? "- [x] " : "- [ ] "
        }
    }

    private static func renderRun(_ text: String, attributes: [NSAttributedString.Key: Any]) -> String {
        if let attachment = attributes[.attachment] as? NSTextAttachment {
            let name = attachment.fileWrapper?.preferredFilename ?? attachment.fileWrapper?.filename
            if let name, let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension),
               type.conforms(to: .image) { return "[图片]" }
            if let name {
                let filename = URL(fileURLWithPath: name).lastPathComponent
                return "[附件：\(escape(filename.replacingOccurrences(of: "\n", with: " ")))]"
            }
            return attachment.image != nil ? "[图片]" : "[附件]"
        }

        let content = text.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty, let range = text.range(of: content) else { return text }
        let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
        var rendered = escape(content)
        if traits.contains(.monoSpace) {
            let fence = delimiter(for: content, minimum: 1)
            let padding = content.hasPrefix("`") || content.hasSuffix("`") ? " " : ""
            rendered = "\(fence)\(padding)\(content)\(padding)\(fence)"
        } else {
            if traits.contains(.bold) { rendered = "**\(rendered)**" }
            if traits.contains(.italic) { rendered = "*\(rendered)*" }
        }
        let link = (attributes[.link] as? URL) ?? (attributes[.link] as? String).flatMap(URL.init(string:))
        if let link, let scheme = link.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            rendered = "[\(rendered)](<\(link.absoluteString)>)"
        }
        return String(text[..<range.lowerBound]) + rendered + String(text[range.upperBound...])
    }

    private static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if "\\`*_[]<>#".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    private static func delimiter(for code: String, minimum: Int) -> String {
        let longest = code.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        return String(repeating: "`", count: max(minimum, longest + 1))
    }
}
