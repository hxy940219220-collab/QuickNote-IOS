import Foundation

enum NoteIndexMode: Equatable, Sendable {
    case hybrid, keyword

    var notice: String? { self == .keyword ? "当前为关键词检索" : nil }
}

struct NoteIndexHit: Sendable {
    let chunk: NoteIndexChunk
    /// Normalized reciprocal-rank score in [0, 1], or relative BM25 in keyword mode.
    let score: Double
    /// BM25 divided by the highest lexical score for this query, in [0, 1].
    let keywordScore: Double
    /// Similarity in [-1, 1] in the active model's vector space, if available.
    let cosineSimilarity: Double?
}

struct NoteIndexSearchResult: Sendable {
    let mode: NoteIndexMode
    let hits: [NoteIndexHit]
}

struct SearchableNoteChunk: Sendable {
    let chunk: NoteIndexChunk
    let foldedText: String
    let termCounts: [String: Int]
    let termCount: Int
    let vector: [Float]?

    init(chunk: NoteIndexChunk, vector: [Float]?) {
        self.chunk = chunk
        foldedText = HybridSearchRanking.folded(chunk.text)
        let terms = HybridSearchRanking.tokens(in: foldedText)
        termCount = terms.count
        termCounts = terms.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        self.vector = vector
    }
}

enum HybridSearchRanking {
    private struct LexicalHit {
        let index: Int
        let score: Double
        let terms: [String]
        let exact: Bool
    }

    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }

    static func tokens(in foldedText: String) -> [String] {
        var output: [String] = []
        var han: [Unicode.Scalar] = []
        var word = String.UnicodeScalarView()

        func flushHan() {
            if han.count == 1 {
                output.append(String(han[0]))
            } else {
                for (a, b) in zip(han, han.dropFirst()) { output.append(String(a) + String(b)) }
            }
            han.removeAll(keepingCapacity: true)
        }

        func flushWord() {
            guard !word.isEmpty else { return }
            output.append(String(word))
            word.removeAll(keepingCapacity: true)
        }

        for scalar in foldedText.unicodeScalars {
            if scalar.properties.isIdeographic {
                flushWord()
                han.append(scalar)
            } else if CharacterSet.alphanumerics.contains(scalar) {
                flushHan()
                word.append(scalar)
            } else {
                flushHan()
                flushWord()
            }
        }
        flushHan()
        flushWord()
        return output
    }

    static func normalized(_ vector: [Float]?, dimension: Int) -> [Float]? {
        guard let vector, dimension > 0, vector.count == dimension,
              vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm > 0, norm.isFinite else { return nil }
        return vector.map { Float(Double($0) / norm) }
    }

    static func search(_ query: String, chunks: [SearchableNoteChunk], queryVector: [Float]?,
                       limit: Int) -> NoteIndexSearchResult {
        let foldedQuery = folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let queryTerms = Set(tokens(in: foldedQuery)).sorted()
        guard !queryTerms.isEmpty, limit > 0, !chunks.isEmpty else {
            return .init(mode: queryVector == nil ? .keyword : .hybrid, hits: [])
        }

        func precedes(_ a: Int, _ b: Int) -> Bool {
            let lhs = chunks[a].chunk, rhs = chunks[b].chunk
            return lhs.noteID == rhs.noteID ? lhs.range.location < rhs.range.location
                : lhs.noteID.uuidString < rhs.noteID.uuidString
        }

        let idf = inverseDocumentFrequency(queryTerms, chunks: chunks)
        let lexical = lexicalRanking(query: foldedQuery, terms: queryTerms, chunks: chunks, idf: idf)
            .sorted { $0.score == $1.score ? precedes($0.index, $1.index) : $0.score > $1.score }
        let highestLexical = lexical.first?.score ?? 1
        let keywordScores = Dictionary(uniqueKeysWithValues: lexical.map { ($0.index, $0.score / highestLexical) })
        let exact = lexical.filter(\.exact).map(\.index)
        let semantic = semanticScores(chunks: chunks, queryVector: queryVector)
        guard !semantic.isEmpty else {
            let indices = Array((exact + lexical.filter { !$0.exact }.map(\.index)).prefix(limit))
            return .init(mode: .keyword, hits: indices.map {
                let score = keywordScores[$0, default: 0]
                return .init(chunk: chunks[$0].chunk, score: score, keywordScore: score, cosineSimilarity: nil)
            })
        }

        let semanticRanking = semantic.keys.filter { semantic[$0, default: 0] > 0 }.sorted {
            let a = semantic[$0, default: 0], b = semantic[$1, default: 0]
            return a == b ? precedes($0, $1) : a > b
        }
        // A rank of 1 contributes 0.5. Missing channels contribute zero.
        let rankOffset = 60.0
        var combined: [Int: Double] = [:]
        for ranking in [lexical.map(\.index), semanticRanking] {
            for (offset, index) in ranking.enumerated() {
                combined[index, default: 0] += (rankOffset + 1) / (2 * (rankOffset + Double(offset + 1)))
            }
        }
        let protected = protectedLexicalHits(exact: exact, lexical: lexical, idf: idf, limit: limit)
        let protectedSet = Set(protected)
        let ranked = combined.keys.sorted {
            let a = combined[$0, default: 0], b = combined[$1, default: 0]
            return a == b ? precedes($0, $1) : a > b
        }
        let selected = protectedSet.union(ranked.lazy.filter { !protectedSet.contains($0) }
            .prefix(max(0, limit - protected.count)))
        return .init(mode: .hybrid, hits: ranked.filter { selected.contains($0) }.map {
            .init(chunk: chunks[$0].chunk, score: combined[$0, default: 0],
                  keywordScore: keywordScores[$0, default: 0], cosineSimilarity: semantic[$0])
        })
    }

    private static func inverseDocumentFrequency(_ terms: [String], chunks: [SearchableNoteChunk]) -> [String: Double] {
        var counts: [String: Int] = [:]
        for chunk in chunks {
            for term in terms where chunk.termCounts[term] != nil { counts[term, default: 0] += 1 }
        }
        return counts.mapValues { frequency in
            log(1 + (Double(chunks.count - frequency) + 0.5) / (Double(frequency) + 0.5))
        }
    }

    private static func lexicalRanking(query: String, terms: [String], chunks: [SearchableNoteChunk],
                                       idf: [String: Double]) -> [LexicalHit] {
        let averageLength = Double(chunks.reduce(0) { $0 + $1.termCount }) / Double(chunks.count)
        let k1 = 1.2, b = 0.75
        return chunks.indices.compactMap { index in
            let chunk = chunks[index]
            let norm = k1 * (1 - b + b * Double(chunk.termCount) / max(averageLength, 1))
            var score = 0.0
            var matches: [String] = []
            for term in terms {
                guard let frequency = chunk.termCounts[term], let weight = idf[term] else { continue }
                let tf = Double(frequency)
                score += weight * tf * (k1 + 1) / (tf + norm)
                matches.append(term)
            }
            guard score > 0, score.isFinite else { return nil }
            let isWholeWord = terms.count == 1 && terms.first == query && !query.unicodeScalars.contains { $0.properties.isIdeographic }
            let exact = isWholeWord ? matches.first == query : chunk.foldedText.contains(query)
            return .init(index: index, score: score, terms: matches, exact: exact)
        }
    }

    private static func semanticScores(chunks: [SearchableNoteChunk], queryVector: [Float]?) -> [Int: Double] {
        guard let queryVector else { return [:] }
        var scores: [Int: Double] = [:]
        for (index, chunk) in chunks.enumerated() {
            guard let vector = chunk.vector, vector.count == queryVector.count else { continue }
            let dot = zip(vector, queryVector).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
            if dot.isFinite { scores[index] = max(-1, min(1, dot)) }
        }
        return scores
    }

    private static func protectedLexicalHits(exact: [Int], lexical: [LexicalHit],
                                              idf: [String: Double], limit: Int) -> [Int] {
        var selected = Array(exact.prefix(limit))
        var selectedSet = Set(selected)
        var covered = Set(lexical.lazy.filter { selectedSet.contains($0.index) }.flatMap(\.terms))
        let quota = max(1, limit / 2)
        while selected.count < quota {
            var best: LexicalHit?
            var bestGain = 0.0
            for candidate in lexical where !selectedSet.contains(candidate.index) {
                // A lone Han character in a longer question often comes from a particle.
                let gain = candidate.terms.reduce(0.0) { result, term in
                    let isSingleHan = term.unicodeScalars.count == 1 && term.unicodeScalars.first?.properties.isIdeographic == true
                    guard !covered.contains(term), !isSingleHan else { return result }
                    return result + idf[term, default: 0]
                }
                if gain > bestGain {
                    best = candidate
                    bestGain = gain
                }
            }
            guard let best else { break }
            selected.append(best.index)
            selectedSet.insert(best.index)
            covered.formUnion(best.terms)
        }
        return selected
    }
}
