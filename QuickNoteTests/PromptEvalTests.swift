import Foundation
import XCTest
@testable import QuickNote

@MainActor
final class PromptEvalTests: XCTestCase {
    func testAskAnswerV1WithExplicitProfile() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let profile = environment["QUICKNOTE_EVAL_PROFILE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !profile.isEmpty else {
            throw XCTSkip("设置 QUICKNOTE_EVAL_PROFILE 后运行合成问答评测。")
        }

        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cases", withExtension: "jsonl"))
        let cases = try String(contentsOf: fixtureURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(EvaluationCase.self, from: Data($0.utf8)) }
        guard cases.count >= 20, Set(cases.map(\.id)).count == cases.count else {
            return XCTFail("评测夹具至少需要 20 条具有唯一 ID 的用例。")
        }
        let store = AIConfigurationStore.shared
        let slots = AIProfileSlot.allCases.filter { $0.title == profile || store.displayName(for: $0) == profile }
        guard slots.count == 1, let slot = slots.first else {
            return XCTFail("评测配置名必须唯一，请使用模型槽位名称或唯一的自定义名称。")
        }
        guard store.inputModalities(for: slot).contains(.text),
              let configuration = try? store.draft(for: slot).validated() else {
            return XCTFail("评测配置的文字模型不可用。")
        }

        var results: [EvaluationResult] = []
        for fixture in cases {
            let start = ContinuousClock.now
            let outcome: [String]
            do {
                outcome = try await failedChecks(in: fixture, configuration: configuration)
            } catch {
                // HTTP errors may echo provider data. The report contains only synthetic case IDs and check labels.
                outcome = ["request_failed"]
            }
            let duration = start.duration(to: .now).components
            let milliseconds = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
            results.append(.init(id: fixture.id, passed: outcome.isEmpty, failedChecks: outcome,
                                 milliseconds: Int(milliseconds.rounded())))
        }
        let passed = results.filter(\.passed).count
        let report = EvaluationReport(prompt: Prompts.AskAnswer.id, version: Prompts.AskAnswer.version,
                                      passed: passed, total: results.count, cases: results)
        let reportDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "evals/reports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let reportURL = reportDirectory.appending(path: "ask-answer-v1-\(UUID().uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        XCTAssertEqual(passed, results.count, "合成问答评测报告：\(reportURL.path)")
    }

    private func failedChecks(in fixture: EvaluationCase, configuration: AIConfiguration) async throws -> [String] {
        let evidence: [NoteAskEvidence] = (fixture.context ?? []).enumerated().map { index, text in
            NoteAskEvidence(number: index + 1, chunk: NoteIndexChunk(
                noteID: UUID(), title: "合成便签", text: text,
                range: NSRange(location: 0, length: text.utf16.count), revision: 0
            ), location: "合成便签集")
        }
        let rawAnswer: String
        if evidence.isEmpty {
            rawAnswer = Prompts.AskAnswer.noEvidence
        } else {
            let request = NoteAskRequest(question: fixture.input, evidence: evidence)
            var result: AIStreamCompletion?
            for try await event in OpenAICompatibleClient.stream(configuration: configuration, system: request.system,
                                                                 user: request.user) {
                if case .completed(let completion) = event { result = completion }
            }
            guard let result, result.isComplete else { return ["incomplete_response"] }
            rawAnswer = result.text
        }
        let answer = AskCitationParser.parse(rawAnswer, validNumbers: Set(evidence.map(\.number)), streaming: false)
        let normalized = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var failures: [String] = []
        if let exact = fixture.checks.exact, rawAnswer != exact { failures.append("exact_answer") }
        if let required = fixture.checks.contains, !required.allSatisfy({ normalized.contains($0) }) {
            failures.append("supported_facts")
        }
        if let forbidden = fixture.checks.excludes, forbidden.contains(where: { rawAnswer.contains($0) }) {
            failures.append("excluded_material")
        }
        if Set(answer.references) != Set(fixture.checks.references) { failures.append("references") }
        return failures
    }
}

private struct EvaluationCase: Decodable {
    struct Checks: Decodable {
        let exact: String?
        let contains: [String]?
        let excludes: [String]?
        let references: [Int]
    }

    let id: String
    let input: String
    let context: [String]?
    let checks: Checks
    let notes: String
}

private struct EvaluationResult: Encodable {
    let id: String
    let passed: Bool
    let failedChecks: [String]
    let milliseconds: Int
}

private struct EvaluationReport: Encodable {
    let prompt: String
    let version: Int
    let passed: Int
    let total: Int
    let cases: [EvaluationResult]
}
