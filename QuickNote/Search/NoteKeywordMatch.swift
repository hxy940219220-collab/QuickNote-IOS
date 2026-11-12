import Foundation

struct NoteSearchSnippet: Identifiable, Equatable {
    struct Run: Equatable {
        let text: String
        let isMatch: Bool
    }

    let sourceText: String
    let matchRange: NSRange
    let runs: [Run]

    var id: Int { matchRange.location }
}

struct NoteSearchMatch {
    enum Source: Hashable { case title, tag }
    private static let collapsedSnippetLimit = 2

    let title: String
    let location: String
    let snippets: [NoteSearchSnippet]
    let otherSources: [Source]

    var hiddenSnippetCount: Int { max(0, snippets.count - Self.collapsedSnippetLimit) }

    func visibleSnippets(expanded: Bool) -> [NoteSearchSnippet] {
        expanded ? snippets : Array(snippets.prefix(Self.collapsedSnippetLimit))
    }

    init(title: String, location: String, body: String, tags: [String], isSensitive: Bool, query: String) {
        self.title = title
        self.location = location
        guard !isSensitive else {
            snippets = []
            otherSources = []
            return
        }
        snippets = NoteSearchText.snippets(for: query, in: body, excludingFirstLineMatching: title)
        var sources: [Source] = []
        if snippets.isEmpty {
            if NoteSearchText.firstRange(of: query, in: title) != nil { sources.append(.title) }
            if tags.contains(where: { NoteSearchText.firstRange(of: query, in: $0) != nil }) {
                sources.append(.tag)
            }
        }
        otherSources = sources
    }
}

enum NoteSearchNavigation {
    struct ItemID: Hashable {
        let noteID: UUID
        let snippetID: Int?
    }

    struct PointerSelection {
        private(set) var item: ItemID?
        private var isTrackingRows = false

        func highlightedItem(keyboardItem: ItemID?) -> ItemID? {
            isTrackingRows ? item : keyboardItem
        }

        mutating func update(isHovered: Bool, item: ItemID) {
            if isHovered {
                isTrackingRows = true
                self.item = item
            } else if self.item == item {
                clearItem()
            }
        }

        mutating func clearItem() {
            item = nil
        }
    }

    static func items(noteID: UUID, match: NoteSearchMatch, expanded: Bool) -> [ItemID] {
        let snippets = match.visibleSnippets(expanded: expanded)
        return snippets.isEmpty ? [ItemID(noteID: noteID, snippetID: nil)]
            : snippets.map { ItemID(noteID: noteID, snippetID: $0.id) }
    }

    static func move(in items: [ItemID], selected: ItemID?, offset: Int) -> ItemID? {
        guard let selected, let index = items.firstIndex(of: selected) else { return items.first }
        let boundedOffset = min(max(offset, -index), items.count - 1 - index)
        return items[index + boundedOffset]
    }
}

enum NoteSearchPanelLayout {
    static let topInset: CGFloat = 36

    static func maximumSize(in viewport: CGSize) -> CGSize {
        CGSize(width: max(0, min(560, viewport.width - 32)),
               height: max(0, min(440, viewport.height - topInset - 16)))
    }
}

enum NoteSearchText {
    private struct SnippetGroup {
        let paragraph: NSRange
        let paragraphContentEnd: Int
        let anchor: NSRange
        var context: NSRange
        var highlights: [NSRange]

        mutating func merge(context nextContext: NSRange, match: NSRange) {
            context = NSUnionRange(context, nextContext)
            if let last = highlights.last, match.location <= NSMaxRange(last) {
                highlights[highlights.count - 1] = NSUnionRange(last, match)
            } else {
                highlights.append(match)
            }
        }
    }

    static func firstRange(of query: String, in text: String) -> NSRange? {
        firstRange(of: query.trimmingCharacters(in: .whitespacesAndNewlines), in: text as NSString, from: 0)
    }

    static func validatedRange(for snippet: NoteSearchSnippet, query: String, in text: String) -> NSRange? {
        let candidate = snippet.matchRange
        let length = text.utf16.count
        guard candidate.location >= 0, candidate.location <= length, candidate.length > 0,
              candidate.length <= length - candidate.location,
              text.utf16.elementsEqual(snippet.sourceText.utf16),
              let range = Range(candidate, in: text),
              firstRange(of: query, in: String(text[range])) == NSRange(location: 0, length: candidate.length)
        else { return nil }
        return candidate
    }

    static func snippets(for query: String, in sourceText: String,
                         excludingFirstLineMatching title: String? = nil) -> [NoteSearchSnippet] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = sourceText as NSString
        guard !keyword.isEmpty, text.length > 0 else { return [] }
        let bodyLocation = bodyStart(in: text, title: title)
        var start = bodyLocation
        var snippets: [NoteSearchSnippet] = []
        var group: SnippetGroup?
        while let match = firstRange(of: keyword, in: text, from: start) {
            let end = NSMaxRange(match)
            var paragraphStart = 0, paragraphEnd = 0, paragraphContentEnd = 0
            text.getParagraphStart(&paragraphStart, end: &paragraphEnd, contentsEnd: &paragraphContentEnd, for: match)
            paragraphStart = max(paragraphStart, bodyLocation)
            let paragraph = NSRange(location: paragraphStart, length: paragraphEnd - paragraphStart)
            paragraphContentEnd = max(end, paragraphContentEnd)
            let contextStart = max(paragraphStart, match.location - 20)
            let contextEnd = min(paragraphContentEnd, end + 40)
            let context = text.rangeOfComposedCharacterSequences(for: NSRange(
                location: contextStart, length: contextEnd - contextStart))
            if group?.paragraph == paragraph, let current = group?.context,
               context.location <= NSMaxRange(current) {
                group?.merge(context: context, match: match)
            } else {
                if let group { snippets.append(snippet(for: group, sourceText: sourceText, text: text)) }
                group = SnippetGroup(paragraph: paragraph, paragraphContentEnd: paragraphContentEnd,
                                     anchor: match, context: context, highlights: [match])
            }
            start = NSMaxRange(text.rangeOfComposedCharacterSequence(at: match.location))
        }
        if let group { snippets.append(snippet(for: group, sourceText: sourceText, text: text)) }
        return snippets
    }

    private static func bodyStart(in text: NSString, title: String?) -> Int {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        var end = 0, contentsEnd = 0
        text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: 0, length: 0))
        let firstLine = text.substring(to: contentsEnd).trimmingCharacters(in: .whitespacesAndNewlines)
        return firstLine == title.trimmingCharacters(in: .whitespacesAndNewlines) ? end : 0
    }

    private static func snippet(for group: SnippetGroup, sourceText: String, text: NSString) -> NoteSearchSnippet {
        var runs: [NoteSearchSnippet.Run] = []
        var cursor = group.context.location
        for highlight in group.highlights {
            let prefix = runs.isEmpty && cursor > group.paragraph.location ? "…" : ""
            let between = text.substring(with: NSRange(location: cursor, length: highlight.location - cursor))
            if !prefix.isEmpty || !between.isEmpty {
                runs.append(.init(text: prefix + display(between), isMatch: false))
            }
            runs.append(.init(text: display(text.substring(with: highlight)), isMatch: true))
            cursor = NSMaxRange(highlight)
        }
        let end = NSMaxRange(group.context)
        let suffix = end < group.paragraphContentEnd ? "…" : ""
        if cursor < end || !suffix.isEmpty {
            let tail = text.substring(with: NSRange(location: cursor, length: end - cursor))
            runs.append(.init(text: display(tail) + suffix, isMatch: false))
        }
        return NoteSearchSnippet(sourceText: sourceText, matchRange: group.anchor, runs: runs)
    }

    private static func firstRange(of keyword: String, in text: NSString, from start: Int) -> NSRange? {
        guard !keyword.isEmpty, start < text.length else { return nil }
        let range = text.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                               range: NSRange(location: start, length: text.length - start), locale: .current)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return text.rangeOfComposedCharacterSequences(for: range)
    }

    private static func display(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: " ")
            .components(separatedBy: .newlines).joined(separator: " ")
    }
}
