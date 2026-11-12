import Foundation

enum NoteAskQuestion {
    static func normalized(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let introduction = #"(?:^|[\s，,。；;：:])(?:可以问|试着问|例如问|比如问|示例问题)\s*[:：]?\s*(?:\*\*)?[「『“"]"#
        guard let match = trimmed.range(of: introduction, options: .regularExpression) else { return trimmed }
        let opening = trimmed[trimmed.index(before: match.upperBound)]
        let closing: Character = ["「": "」", "『": "』", "“": "”", "\"": "\""][opening] ?? opening
        var depth = 1
        for index in trimmed.indices[match.upperBound...] {
            let character = trimmed[index]
            if character == closing {
                depth -= 1
                guard depth == 0 else { continue }
                let question = trimmed[match.upperBound..<index].trimmingCharacters(in: .whitespacesAndNewlines)
                let remainder = trimmed[trimmed.index(after: index)...]
                guard question.contains(where: { $0 == "?" || $0 == "？" }),
                      remainder.allSatisfy({ $0.isWhitespace || "。.!！?？*".contains($0) }) else { return trimmed }
                return question
            }
            if character == opening { depth += 1 }
        }
        return trimmed
    }

    static func retrievalText(for question: String) -> String {
        guard let end = question.lastIndex(where: { $0 == "?" || $0 == "？" }) else { return question }
        let suffix = question[question.index(after: end)...]
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        switch suffix {
        case "请按便签归纳并标注出处", "请根据便签归纳并标注出处", "请标注出处", "请附上出处":
            return String(question[..<end])
        default:
            return question
        }
    }
}

struct NoteAskEvidence: Identifiable, Equatable, Sendable {
    let number: Int
    let chunk: NoteIndexChunk
    let location: String

    var id: Int { number }
}

struct NoteAskRequest: Sendable {
    static let materialStart = "<reference_materials>"
    static let materialEnd = "</reference_materials>"

    let system = Prompts.AskAnswer.system
    let user: String

    init(question: String, evidence: [NoteAskEvidence]) {
        let questionJSON = Self.jsonLiteral(question)
        let materials = evidence.map {
            #"{"number":\#($0.number),"text":\#(Self.jsonLiteral($0.chunk.text))}"#
        }.joined(separator: ",\n")
        user = """
        问题（JSON 字符串）：
        \(questionJSON)
        \(Self.materialStart)
        [
        \(materials)
        ]
        \(Self.materialEnd)
        """
    }

    private static func jsonLiteral(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // Escaping angle brackets keeps boundary-looking substrings inside their JSON strings.
        guard let data = try? encoder.encode(text) else { return "\"\"" }
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: ">", with: "\\u003E")
    }
}

enum AskCitationParser {
    struct Result: Equatable, Sendable {
        let text: String
        let references: [Int]
    }

    static func parse(_ text: String, validNumbers: Set<Int>, streaming: Bool) -> Result {
        var output = ""
        var references: [Int] = []
        var seen: Set<Int> = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index] == "[" {
                let digitsEnd = text[next...].firstIndex(where: { !$0.isASCII || !$0.isNumber }) ?? text.endIndex
                // A numeric marker can be split over stream updates. Do not briefly display it as text.
                if digitsEnd == text.endIndex, streaming || next < digitsEnd { break }
                if next < digitsEnd, digitsEnd < text.endIndex, text[digitsEnd] == "]" {
                    if let number = Int(text[next..<digitsEnd]), validNumbers.contains(number) {
                        output += "[\(number)]"
                        if seen.insert(number).inserted { references.append(number) }
                    }
                    index = text.index(after: digitsEnd)
                    continue
                }
            }
            output.append(text[index])
            index = next
        }
        return Result(text: output, references: references)
    }
}

enum NoteAskCitationLocation {
    static func resolve(_ chunk: NoteIndexChunk, revision: Int, source: String, question: String) -> NSRange? {
        let length = source.utf16.count
        if chunk.revision == revision,
           chunk.range.location >= 0, chunk.range.location <= length,
           chunk.range.length > 0, chunk.range.length <= length - chunk.range.location,
           let range = Range(chunk.range, in: source),
           NoteChunker.sourceFingerprint(for: source) == chunk.sourceFingerprint,
           NoteChunker.normalizedExcerpt(String(source[range])) == chunk.text {
            return chunk.range
        }

        if let excerpt = NoteSearchText.firstRange(of: chunk.text, in: source) { return excerpt }
        let questionTerms = Set(HybridSearchRanking.tokens(in: HybridSearchRanking.folded(question)))
        var seen: Set<String> = []
        let terms = HybridSearchRanking.tokens(in: HybridSearchRanking.folded(chunk.text))
            .filter { $0.count > 1 && seen.insert($0).inserted }
            .enumerated().sorted {
                let left = $0.element, right = $1.element
                let leftInQuestion = questionTerms.contains(left), rightInQuestion = questionTerms.contains(right)
                if leftInQuestion != rightInQuestion { return leftInQuestion }
                if left.count != right.count { return left.count > right.count }
                return $0.offset < $1.offset
            }
        return terms.lazy.compactMap { NoteSearchText.firstRange(of: $0.element, in: source) }.first
    }
}
