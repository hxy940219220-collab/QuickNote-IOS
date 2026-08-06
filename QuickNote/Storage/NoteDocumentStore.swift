import AppKit

struct NoteDocumentStore {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func load(id: UUID) throws -> NSAttributedString {
        let url = url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return NSAttributedString(string: "") }
        return try NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        )
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
