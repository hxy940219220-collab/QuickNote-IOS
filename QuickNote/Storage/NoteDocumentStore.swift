import AppKit

struct NoteDocumentStore {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func load(id: UUID) throws -> NSAttributedString {
        let url = url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return NSAttributedString(string: "") }
        let document = try NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
        return NoteFontNormalizer.normalized(document)
    }

    func save(_ document: NSAttributedString, id: UUID) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let range = NSRange(location: 0, length: document.length)
        let wrapper = try document.fileWrapper(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
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

enum NoteFontNormalizer {
    static func normalized(_ document: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: document)
        let range = NSRange(location: 0, length: document.length)
        var fontRuns: [(NSFont, NSRange)] = []
        document.enumerateAttributes(in: range) { attributes, run, _ in
            guard attributes[.attachment] == nil,
                  let font = attributes[.font] as? NSFont,
                  font.pointSize < EditorTextStyle.subheading.font.pointSize else { return }
            fontRuns.append((font, run))
        }

        for (font, run) in fontRuns {
            let originalTraits = font.fontDescriptor.symbolicTraits
            let base = originalTraits.contains(.monoSpace)
                ? EditorTextStyle.monospaced.font
                : EditorTextStyle.body.font
            var traits = base.fontDescriptor.symbolicTraits
            if originalTraits.contains(.bold) { traits.insert(.bold) }
            if originalTraits.contains(.italic) { traits.insert(.italic) }
            let normalized = traits == base.fontDescriptor.symbolicTraits
                ? base
                : NSFont(
                    descriptor: base.fontDescriptor.withSymbolicTraits(traits),
                    size: EditorTextStyle.body.font.pointSize
                ) ?? base
            result.addAttribute(.font, value: normalized, range: run)
        }
        return result
    }
}
