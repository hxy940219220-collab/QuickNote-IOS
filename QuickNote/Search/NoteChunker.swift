import CryptoKit
import Foundation

struct NoteIndexSnapshot: Equatable, Sendable {
    let noteID: UUID
    let title: String
    let text: String
    let revision: Int
}

struct NoteIndexChunk: Equatable, Sendable {
    let noteID: UUID
    let title: String
    let text: String
    let range: NSRange
    let revision: Int
    let sourceFingerprint: String

    init(noteID: UUID, title: String, text: String, range: NSRange, revision: Int,
         sourceFingerprint: String = "") {
        self.noteID = noteID
        self.title = title
        self.text = text
        self.range = range
        self.revision = revision
        self.sourceFingerprint = sourceFingerprint
    }
}

enum NoteChunker {
    static let maximumCharacters = 500

    static func sourceFingerprint(for source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedExcerpt(_ excerpt: String) -> String {
        excerpt.replacingOccurrences(of: "\u{fffc}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func chunks(for snapshot: NoteIndexSnapshot) -> [NoteIndexChunk] {
        let source = snapshot.text
        let fingerprint = sourceFingerprint(for: source)
        var chunks: [NoteIndexChunk] = []
        source.enumerateSubstrings(in: source.startIndex..<source.endIndex, options: [.byParagraphs, .substringNotRequired]) {
            _, paragraph, _, _ in
            var start = paragraph.lowerBound
            while start < paragraph.upperBound {
                let end = source.index(start, offsetBy: maximumCharacters, limitedBy: paragraph.upperBound)
                    ?? paragraph.upperBound
                let range = start..<end
                // An attachment is a word boundary, but still occupies its original UTF-16 offset.
                let text = normalizedExcerpt(String(source[range]))
                if !text.isEmpty {
                    chunks.append(.init(noteID: snapshot.noteID, title: snapshot.title, text: text,
                                        range: NSRange(range, in: source), revision: snapshot.revision,
                                        sourceFingerprint: fingerprint))
                }
                start = end
            }
        }
        return chunks
    }
}
