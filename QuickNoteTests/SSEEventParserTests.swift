import Foundation
import XCTest
@testable import QuickNote

final class SSEEventParserTests: XCTestCase {
    func testParserEmitsDataOnlyAfterAnEventBoundary() throws {
        var parser = SSEEventParser()
        XCTAssertEqual(try parser.append(Data("data: first\n".utf8)), [])
        XCTAssertEqual(try parser.append(Data("\n".utf8)), [SSEEvent(data: "first")])
    }

    func testParserPreservesChineseEnglishAndEmojiAtEveryByteSplit() throws {
        let input = Data("data: 中文 English 👩🏽‍💻🙂\n\n".utf8)
        for split in 0...input.count {
            var parser = SSEEventParser()
            let events = try parser.append(Data(input.prefix(split)))
                + parser.append(Data(input.dropFirst(split)))
            XCTAssertEqual(events, [SSEEvent(data: "中文 English 👩🏽‍💻🙂")], "split=\(split)")
        }
    }

    func testParserAcceptsOneByteChunksAndLinesAcrossManyChunks() throws {
        var parser = SSEEventParser()
        var events: [SSEEvent] = []
        for byte in Data("data: 中🙂\n\n".utf8) {
            events += try parser.append(Data([byte]))
        }
        XCTAssertEqual(events, [SSEEvent(data: "中🙂")])
    }

    func testParserSupportsLFCRLFAndCRIncludingSplitCRLF() throws {
        for separator in ["\n", "\r\n", "\r"] {
            var parser = SSEEventParser()
            let bytes = Data("data: one\(separator)\(separator)data: two\(separator)\(separator)".utf8)
            var events: [SSEEvent] = []
            for byte in bytes { events += try parser.append(Data([byte])) }
            XCTAssertEqual(events, [SSEEvent(data: "one"), SSEEvent(data: "two")])
        }
    }

    func testParserIgnoresCommentsUnknownFieldsAndEmptyEvents() throws {
        var parser = SSEEventParser()
        let events = try parser.append(Data("\n: heartbeat\nevent: message\nid: 42\nretry: 1000\n\ndata: answer\n\n\n".utf8))
        XCTAssertEqual(events, [SSEEvent(data: "answer")])
    }

    func testParserJoinsMultipleDataLinesAndRemovesOnlyOneOptionalSpace() throws {
        var parser = SSEEventParser()
        XCTAssertEqual(try parser.append(Data("data: line one\ndata:  line two\ndata\n\n".utf8)),
                       [SSEEvent(data: "line one\n line two\n")])
    }

    func testParserAcceptsUTF8BOMSplitAcrossChunks() throws {
        var parser = SSEEventParser()
        var events: [SSEEvent] = []
        for byte in Data("\u{FEFF}data: hello\n\n".utf8) {
            events += try parser.append(Data([byte]))
        }
        XCTAssertEqual(events, [SSEEvent(data: "hello")])
    }

    func testParserFinishesPendingDataAtEOFWithoutInventingAnotherEvent() throws {
        var parser = SSEEventParser()
        XCTAssertEqual(try parser.append(Data("data: final".utf8)), [])
        XCTAssertEqual(try parser.finish(), [SSEEvent(data: "final")])
        XCTAssertEqual(try parser.finish(), [])
    }

    func testParserRejectsMalformedUTF8InsteadOfReplacingIt() {
        var parser = SSEEventParser()
        XCTAssertThrowsError(try parser.append(Data([100, 97, 116, 97, 58, 32, 0xF0, 0x28, 0x8C, 0x28, 10, 10])))
    }

    func testSanitizerHidesThinkBlocksAtEveryCharacterSplit() {
        let input = "前文 <think>私密推理🙂</think> 后文"
        for split in input.indices {
            var sanitizer = AIStreamingSanitizer()
            let first = sanitizer.append(String(input[..<split]))
            XCTAssertFalse(first.contains("私密"), "split=\(split)")
            let result = first + sanitizer.append(String(input[split...])) + sanitizer.finish()
            XCTAssertEqual(result, "前文 后文")
        }
    }

    func testSanitizerNeverPublishesSplitOpeningOrClosingTags() {
        var sanitizer = AIStreamingSanitizer()
        XCTAssertEqual(sanitizer.append("可见<thi"), "可见")
        XCTAssertEqual(sanitizer.append("nk>secret</thi"), "")
        XCTAssertEqual(sanitizer.append("nk>\n继续"), "继续")
        XCTAssertEqual(sanitizer.finish(), "")
    }

    func testSanitizerSupportsCaseInsensitiveThinkTagsAndAttributes() {
        var sanitizer = AIStreamingSanitizer()
        XCTAssertEqual(sanitizer.append("A<ThInK mode=\"deep\">hidden</tHiNk>  B"), "AB")
        XCTAssertEqual(sanitizer.finish(), "")
    }

    func testSanitizerDiscardsUnclosedThinkContentAndIncompleteOpeningTag() {
        var sanitizer = AIStreamingSanitizer()
        XCTAssertEqual(sanitizer.append("answer<think>private reasoning"), "answer")
        XCTAssertEqual(sanitizer.finish(), "")
        var partial = AIStreamingSanitizer()
        XCTAssertEqual(partial.append("answer<thi"), "answer")
        XCTAssertEqual(partial.finish(), "")
    }

    func testSanitizerPreservesOrdinaryLessThanAndNonThinkTags() {
        var sanitizer = AIStreamingSanitizer()
        XCTAssertEqual(sanitizer.append("1 < 2; <thinking>literal</thinking>; 中文🙂"),
                       "1 < 2; <thinking>literal</thinking>; 中文🙂")
        XCTAssertEqual(sanitizer.finish(), "")
    }

    func testSanitizerHandlesConsecutiveThinkBlocksWithoutLeakingContent() {
        var sanitizer = AIStreamingSanitizer()
        XCTAssertEqual(sanitizer.append("<think>one</think> \n<think>two</think> visible"), "visible")
        XCTAssertEqual(sanitizer.finish(), "")
    }

    func testDecoderIgnoresRoleOnlyAndUsageOnlyChunks() throws {
        var decoder = AIStreamDecoder()
        XCTAssertEqual(try decoder.append(event(#"{"choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}"#)), "")
        XCTAssertEqual(try decoder.append(event(#"{"choices":[],"usage":{"completion_tokens":3}}"#)), "")
        XCTAssertEqual(try decoder.append(event(#"{"usage":{"completion_tokens":3}}"#)), "")
        XCTAssertEqual(try decoder.append(event(#"{"choices":[{"delta":{"content":"你好🙂"},"finish_reason":null}]}"#)), "你好🙂")
        XCTAssertEqual(try decoder.append(event(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#)), "")
        XCTAssertEqual(try decoder.append(event("[DONE]")), "")
        let completion = try decoder.finish()
        XCTAssertTrue(decoder.isFinished)
        XCTAssertTrue(completion.isComplete)
        XCTAssertEqual(completion.text, "你好🙂")
    }

    func testDecoderPreservesLengthLimitedContentAsIncomplete() throws {
        var decoder = AIStreamDecoder()
        _ = try decoder.append(event(#"{"choices":[{"delta":{"content":"part"},"finish_reason":"length"}]}"#))
        _ = try decoder.append(event("[DONE]"))
        let completion = try decoder.finish()
        XCTAssertEqual(completion.text, "part")
        XCTAssertEqual(completion.finishReason, "length")
        XCTAssertFalse(completion.isComplete)
    }

    func testDecoderAcceptsNilFinishReasonWhenDoneIsPresent() throws {
        var decoder = AIStreamDecoder()
        _ = try decoder.append(event(#"{"choices":[{"delta":{"content":"answer"}}]}"#))
        _ = try decoder.append(event("[DONE]"))
        XCTAssertTrue(try decoder.finish().isComplete)
    }

    func testDecoderRejectsEOFWithoutDoneEvenAfterStopReason() throws {
        var decoder = AIStreamDecoder()
        _ = try decoder.append(event(#"{"choices":[{"delta":{"content":"part"},"finish_reason":"stop"}]}"#))
        XCTAssertThrowsError(try decoder.finish()) { error in
            XCTAssertTrue(error is AIStreamingError)
        }
    }

    func testDecoderFiltersThinkBeforeAnyVisibleDeltaAndRejectsReasoningOnly() throws {
        var decoder = AIStreamDecoder()
        XCTAssertEqual(try decoder.append(event(#"{"choices":[{"delta":{"content":"<thi"}}]}"#)), "")
        XCTAssertEqual(try decoder.append(event(#"{"choices":[{"delta":{"content":"nk>private</think>"}}]}"#)), "")
        _ = try decoder.append(event("[DONE]"))
        XCTAssertThrowsError(try decoder.finish())
    }

    func testDecoderRejectsMalformedJSONAndMissingChoices() {
        var decoder = AIStreamDecoder()
        XCTAssertThrowsError(try decoder.append(event("not json")))
        XCTAssertThrowsError(try decoder.append(event(#"{"unexpected":true}"#)))
    }

    private func event(_ data: String) -> SSEEvent { SSEEvent(data: data) }
}
