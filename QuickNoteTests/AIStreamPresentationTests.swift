import XCTest
@testable import QuickNote

@MainActor
final class AIStreamPresentationTests: XCTestCase {
    func testDeltasAreMergedUntilTheFiftyMillisecondWindow() async {
        let clock = ManualStreamPresentationClock()
        let presentation = AIStreamPresentation(sleep: { try await clock.sleep($0) })
        let generation = presentation.begin()
        presentation.receive(.delta("中"), generation: generation)
        presentation.receive(.delta("文🙂"), generation: generation)
        await drainTasks()
        XCTAssertEqual(presentation.snapshot.text, "")
        XCTAssertEqual(clock.requestedDurations, [.milliseconds(50)])
        clock.advance()
        await drainTasks()
        XCTAssertEqual(presentation.snapshot.text, "中文🙂")
    }

    func testFirstChunkBecomesVisibleWithinOneHundredMilliseconds() async throws {
        let presentation = AIStreamPresentation()
        let (stream, continuation) = AsyncThrowingStream<AIStreamEvent, Error>.makeStream()
        presentation.start(stream)
        let clock = ContinuousClock()
        let started = clock.now
        continuation.yield(.delta("第一段🙂"))
        while presentation.snapshot.text.isEmpty && clock.now - started < .milliseconds(100) {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(presentation.snapshot.text, "第一段🙂")
        XCTAssertLessThanOrEqual(clock.now - started, .milliseconds(100))
        presentation.stop()
        continuation.finish()
    }

    func testCompletionImmediatelyPublishesTheFinalTextAndAllowsImport() {
        let presentation = AIStreamPresentation()
        let generation = presentation.begin()
        presentation.receive(.delta("尚未刷新"), generation: generation)
        XCTAssertFalse(presentation.snapshot.canImport)
        presentation.receive(.completed(AIStreamCompletion(text: "完整结果", providerName: "测试模型")), generation: generation)
        XCTAssertEqual(presentation.snapshot.text, "完整结果")
        XCTAssertEqual(presentation.snapshot.providerName, "测试模型")
        XCTAssertEqual(presentation.snapshot.phase, .completed)
        XCTAssertTrue(presentation.snapshot.canImport)
        XCTAssertFalse(presentation.snapshot.isPartial)
    }

    func testStopDiscardsQueuedFlushAndRejectsLateChunks() async {
        let clock = ManualStreamPresentationClock()
        let presentation = AIStreamPresentation(sleep: { try await clock.sleep($0) })
        let generation = presentation.begin()
        presentation.receive(.delta("已显示"), generation: generation)
        await drainTasks()
        clock.advance()
        await drainTasks()
        presentation.receive(.delta("未显示"), generation: generation)
        await drainTasks()
        presentation.stop()
        presentation.receive(.delta("迟到内容"), generation: generation)
        presentation.receive(.completed(AIStreamCompletion(text: "迟到完成")), generation: generation)
        clock.advance()
        await drainTasks()
        XCTAssertEqual(presentation.snapshot.text, "已显示")
        XCTAssertEqual(presentation.snapshot.phase, .stopped)
        XCTAssertTrue(presentation.snapshot.isPartial)
        XCTAssertEqual(presentation.snapshot.notice, "已停止，结果可能不完整")
    }

    func testNewGenerationRejectsOldDeltasCompletionAndErrors() {
        let presentation = AIStreamPresentation()
        let oldGeneration = presentation.begin()
        let generation = presentation.begin()
        presentation.receive(.delta("旧内容"), generation: oldGeneration)
        presentation.receive(.completed(AIStreamCompletion(text: "旧完成")), generation: oldGeneration)
        presentation.fail(URLError(.networkConnectionLost), generation: oldGeneration)
        XCTAssertEqual(presentation.snapshot.text, "")
        XCTAssertEqual(presentation.snapshot.phase, .streaming)
        presentation.receive(.completed(AIStreamCompletion(text: "新结果")), generation: generation)
        XCTAssertEqual(presentation.snapshot.text, "新结果")
    }

    func testAProviderRetryClearsThePreviousProvidersPartialResult() async {
        let clock = ManualStreamPresentationClock()
        let presentation = AIStreamPresentation(sleep: { try await clock.sleep($0) })
        let generation = presentation.begin()
        presentation.receive(.started(providerName: "模型一"), generation: generation)
        presentation.receive(.delta("旧片段"), generation: generation)
        await drainTasks()
        clock.advance()
        await drainTasks()
        presentation.receive(.started(providerName: "模型二"), generation: generation)
        XCTAssertEqual(presentation.snapshot.text, "")
        XCTAssertEqual(presentation.snapshot.providerName, "模型二")
        presentation.receive(.completed(AIStreamCompletion(text: "新片段", providerName: "模型二")), generation: generation)
        XCTAssertEqual(presentation.snapshot.text, "新片段")
    }

    func testIncompleteFinishReasonKeepsTextWithoutMarkingSuccess() {
        let presentation = AIStreamPresentation()
        let generation = presentation.begin()
        presentation.receive(.completed(AIStreamCompletion(text: "保留部分", finishReason: "length")), generation: generation)
        XCTAssertEqual(presentation.snapshot.text, "保留部分")
        XCTAssertEqual(presentation.snapshot.phase, .incomplete)
        XCTAssertEqual(presentation.snapshot.notice, "结果可能不完整")
        XCTAssertTrue(presentation.snapshot.isPartial)
        XCTAssertTrue(presentation.snapshot.canImport)
    }

    func testNetworkFailurePreservesTheGeneratedTextAndShowsIncompleteNotice() {
        let presentation = AIStreamPresentation()
        let generation = presentation.begin()
        presentation.receive(.delta("已生成内容"), generation: generation)
        presentation.fail(URLError(.networkConnectionLost), generation: generation)
        XCTAssertEqual(presentation.snapshot.text, "已生成内容")
        XCTAssertEqual(presentation.snapshot.phase, .failed)
        XCTAssertTrue(presentation.snapshot.notice.contains("结果可能不完整"))
        XCTAssertTrue(presentation.snapshot.canImport)
    }

    func testImportRemainsDisabledDuringGenerationEvenAfterAVisibleChunk() async {
        let clock = ManualStreamPresentationClock()
        let presentation = AIStreamPresentation(sleep: { try await clock.sleep($0) })
        let generation = presentation.begin()
        presentation.receive(.delta("可见内容"), generation: generation)
        await drainTasks()
        clock.advance()
        await drainTasks()
        XCTAssertEqual(presentation.snapshot.text, "可见内容")
        XCTAssertTrue(presentation.snapshot.isLoading)
        XCTAssertFalse(presentation.snapshot.canImport)
    }

    func testCumulativeLocalModelSnapshotsReplaceRatherThanDuplicateText() {
        let presentation = AIStreamPresentation()
        let generation = presentation.begin()
        presentation.receive(.snapshot("你"), generation: generation)
        presentation.receive(.snapshot("你好🙂"), generation: generation)
        presentation.receive(.completed(AIStreamCompletion(text: "你好🙂")), generation: generation)
        XCTAssertEqual(presentation.snapshot.text, "你好🙂")
    }

    func testStreamEndingWithoutACompletionKeepsItsTextAndReportsFailure() async {
        let presentation = AIStreamPresentation()
        let failed = expectation(description: "The consumer reports an unexpected end")
        presentation.onUpdate = { snapshot in
            if snapshot.phase == .failed { failed.fulfill() }
        }
        let (stream, continuation) = AsyncThrowingStream<AIStreamEvent, Error>.makeStream()
        presentation.start(stream)
        continuation.yield(.delta("被截断的内容"))
        continuation.finish()
        let completion = await XCTWaiter.fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(completion, .completed)
        XCTAssertEqual(presentation.snapshot.text, "被截断的内容")
        XCTAssertEqual(presentation.snapshot.phase, .failed)
        XCTAssertTrue(presentation.snapshot.isPartial)
    }

    func testStopCancelsTheConsumerAndIgnoresSubsequentProducerYields() async {
        let presentation = AIStreamPresentation()
        let (stream, continuation) = AsyncThrowingStream<AIStreamEvent, Error>.makeStream()
        presentation.start(stream)
        continuation.yield(.completed(AIStreamCompletion(text: "首次结果")))
        await drainTasks()
        presentation.start(stream)
        presentation.stop()
        continuation.yield(.delta("停止后内容"))
        continuation.finish()
        await drainTasks()
        XCTAssertEqual(presentation.snapshot.text, "")
        XCTAssertEqual(presentation.snapshot.phase, .stopped)
    }

    private func drainTasks() async {
        for _ in 0..<16 { await Task.yield() }
    }
}

@MainActor
private final class ManualStreamPresentationClock {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private(set) var requestedDurations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        requestedDurations.append(duration)
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func advance() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}
