import Foundation

enum AIStreamEvent: Sendable {
    case started(providerName: String)
    case delta(String)
    case snapshot(String)
    case completed(AIStreamCompletion)
}

struct AIStreamCompletion: Sendable {
    let text: String
    let providerName: String
    let finishReason: String?

    init(text: String, providerName: String = "", finishReason: String? = nil) {
        self.text = text
        self.providerName = providerName
        self.finishReason = finishReason
    }

    var isComplete: Bool { finishReason == nil || finishReason == "stop" }
}

enum AIStreamingError: LocalizedError {
    case unexpectedEnd

    var errorDescription: String? { "生成中断，结果可能不完整。" }
}

/// Withholds possible tag prefixes so private reasoning is never published and later removed.
struct AIStreamingSanitizer {
    private var pending = ""
    private var isInsideThink = false
    private var removesFollowingWhitespace = false
    private let openingPrefix = "<think"
    private let closingTag = "</think>"

    mutating func append(_ text: String) -> String {
        pending.append(text)
        var visible = ""
        while !pending.isEmpty {
            if isInsideThink {
                if let closing = pending.range(of: closingTag, options: .caseInsensitive) {
                    pending.removeSubrange(..<closing.upperBound)
                    isInsideThink = false
                    removesFollowingWhitespace = true
                    continue
                }
                // Only a potential closing-tag prefix can matter in the next chunk.
                pending = retainedClosingPrefix()
                break
            }

            if removesFollowingWhitespace {
                pending = String(pending.drop(while: \.isWhitespace))
                if pending.isEmpty { break }
                removesFollowingWhitespace = false
            }

            guard let bracket = pending.firstIndex(of: "<") else {
                visible.append(pending)
                pending.removeAll(keepingCapacity: true)
                break
            }
            visible.append(contentsOf: pending[..<bracket])
            pending.removeSubrange(..<bracket)
            let lower = pending.lowercased()
            if openingPrefix.hasPrefix(lower) {
                // Includes an exact '<think': the word boundary has not arrived yet.
                break
            }
            if lower.hasPrefix(openingPrefix) {
                let boundary = pending.index(pending.startIndex, offsetBy: openingPrefix.count)
                let next = pending[boundary]
                if !next.isLetter, !next.isNumber, next != "_" {
                    guard let end = pending.firstIndex(of: ">") else { break }
                    pending.removeSubrange(...end)
                    isInsideThink = true
                    continue
                }
            }
            // An ordinary '<' or a tag such as '<thinking>' is user-visible text.
            visible.append(pending.removeFirst())
        }
        return visible
    }

    mutating func finish() -> String {
        // A truncated opening tag or an unclosed reasoning block must not become visible.
        pending.removeAll(keepingCapacity: false)
        isInsideThink = false
        removesFollowingWhitespace = false
        return ""
    }

    private func retainedClosingPrefix() -> String {
        let lower = pending.lowercased()
        let longest = min(closingTag.count - 1, pending.count)
        guard longest > 0 else { return "" }
        for count in stride(from: longest, through: 1, by: -1) {
            if closingTag.hasPrefix(String(lower.suffix(count))) {
                return String(pending.suffix(count))
            }
        }
        return ""
    }
}

struct AIStreamDecoder {
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
            let finishReason: String?
            enum CodingKeys: String, CodingKey { case delta; case finishReason = "finish_reason" }
        }
        struct Usage: Decodable {}
        let choices: [Choice]?
        let usage: Usage?
    }

    private(set) var isFinished = false
    private var sanitizer = AIStreamingSanitizer()
    private var text = ""
    private var finishReason: String?

    mutating func append(_ event: SSEEvent) throws -> String {
        guard !isFinished else { return "" }
        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return "" }
        if payload == "[DONE]" {
            isFinished = true
            let remaining = sanitizer.finish()
            text.append(remaining)
            return remaining
        }
        let chunk = try JSONDecoder().decode(Chunk.self, from: Data(payload.utf8))
        guard chunk.choices != nil || chunk.usage != nil else { throw AIAnalyzerError.invalidResponse }
        guard let choice = chunk.choices?.first else { return "" }
        if let reason = choice.finishReason { finishReason = reason }
        guard let content = choice.delta?.content else { return "" }
        let visible = sanitizer.append(content)
        text.append(visible)
        return visible
    }

    mutating func finish() throws -> AIStreamCompletion {
        guard isFinished else { throw AIStreamingError.unexpectedEnd }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw AIAnalyzerError.invalidResponse }
        return AIStreamCompletion(text: cleaned, finishReason: finishReason)
    }
}

enum AIStreaming {
    static func makeStream(
        _ operation: @escaping @Sendable (AsyncThrowingStream<AIStreamEvent, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await operation(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
