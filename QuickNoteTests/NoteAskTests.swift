import XCTest
@testable import QuickNote

@MainActor
final class NoteAskTests: XCTestCase {
    @MainActor
    private final class Stub {
        var eligible: Set<UUID> = []
        var availableDestinations: Set<NoteAskDestination> = [.cloud, .local]
        var confirm = true
        var onConfirm: (() -> Void)?
        var confirmations = 0
        var configuredUsesCodex = true
        var requestedDestinations: [NoteAskDestination] = []
        var requests: [NoteAskRequest] = []
        var preflights: [@MainActor @Sendable () throws -> Void] = []
        var streams: [AsyncThrowingStream<AIStreamEvent, Error>.Continuation] = []

        func model(_ destination: NoteAskDestination) -> NoteAskModel {
            let usesCodex = destination == .configured && configuredUsesCodex
            return NoteAskModel(destination: usesCodex ? CodexLocalPreferences.destinationName
                                                       : (destination == .local ? "本机" : "合成服务"),
                         isAvailable: availableDestinations.contains(destination),
                         confirm: {
                             self.confirmations += 1
                             self.onConfirm?()
                             return self.confirm
                         }, start: { request, preflight in
                             self.requestedDestinations.append(destination)
                             self.requests.append(request)
                             self.preflights.append(preflight)
                             let (stream, continuation) = AsyncThrowingStream<AIStreamEvent, Error>.makeStream()
                             self.streams.append(continuation)
                             return stream
                         }, isCodex: usesCodex)
        }
    }

    func testBundledAskEvalCasesCoverNoAnswerAndPromptInjection() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cases", withExtension: "jsonl"))
        let cases = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let ids = try cases.map { try XCTUnwrap($0["id"] as? String) }
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        XCTAssertEqual(Set(ids).count, cases.count)
        let checks = try cases.map { fixture in
            XCTAssertFalse(try XCTUnwrap(fixture["input"] as? String).isEmpty)
            XCTAssertFalse(try XCTUnwrap(fixture["notes"] as? String).isEmpty)
            return try XCTUnwrap(fixture["checks"] as? [String: Any])
        }
        XCTAssertGreaterThanOrEqual(checks.filter { $0["exact"] as? String == NoteAskController.noEvidenceMessage }.count, 5)
        let attackCases = zip(ids, checks).filter { $0.0.hasPrefix("injection-") }
        XCTAssertGreaterThanOrEqual(attackCases.count, 2)
        for (_, check) in attackCases {
            XCTAssertFalse(try XCTUnwrap(check["excludes"] as? [String]).isEmpty)
            XCTAssertFalse(try XCTUnwrap(check["contains"] as? [String]).isEmpty)
            XCTAssertFalse(try XCTUnwrap(check["references"] as? [Int]).isEmpty)
        }
    }

    func testPastedExampleUsesQuotedQuestionForRetrievalAndModelRequest() async throws {
        let expectedQuestion = "星河工单有哪些待开发需求？请按便签归纳并标注出处。"
        let pasted = "想看相关内容，可以切到「搜索」；想让 AI 归纳，可以问 **「\(expectedQuestion)」**"
        let matching = hit(UUID(), "星河工单支持逾期提醒和批量关闭。")
        let distractions = [
            hit(UUID(), "AI 归纳会议纪要，请标注出处。"),
            hit(UUID(), "可以切到搜索查看相关内容。"),
            hit(UUID(), "示例里可以问 AI 如何归纳。"),
        ]
        let chunks = ([matching] + distractions).map { SearchableNoteChunk(chunk: $0.chunk, vector: nil) }
        let stub = Stub()
        stub.eligible = Set(chunks.map { $0.chunk.noteID })
        var queries: [String] = []
        let controller = NoteAskController(search: { query, limit in
            queries.append(query)
            return HybridSearchRanking.search(query, chunks: chunks, queryVector: nil, limit: limit)
        }, sourceLocation: { _ in "合成便签集" },
           resolveModel: stub.model, retrievalDelay: .zero)
        controller.activate(question: pasted)
        try await waitUntil { controller.canAnswer }
        XCTAssertEqual(queries, ["星河工单有哪些待开发需求"])
        XCTAssertEqual(controller.evidence.map { $0.chunk.noteID }, [matching.chunk.noteID])

        controller.answerQuestion()
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertTrue(request.user.contains(expectedQuestion))
        XCTAssertTrue(request.user.contains("批量关闭"))
        XCTAssertFalse(request.user.contains("想看相关内容"))
        XCTAssertFalse(request.user.contains("归纳会议纪要"))
        let stream = try XCTUnwrap(stub.streams.first)
        stream.yield(.completed(.init(text: "需求包括逾期提醒和批量关闭[1]")))
        stream.finish()
        try await waitUntil { !controller.isLoading }
        XCTAssertEqual(controller.answer, "需求包括逾期提醒和批量关闭[1]")
    }

    func testQuotedWordsAndFollowUpQuestionsKeepTheirContext() {
        let originalQuestions = [
            "请解释便签里的「什么时候交付？」这句话。",
            "我可以问「交付时间是什么？」吗？",
            "「工单系统」的负责人是谁？还有哪些遗留事项？",
            "可以问「发布时间在哪里？",
        ]
        for question in originalQuestions {
            XCTAssertEqual(NoteAskQuestion.normalized(question), question)
        }
        let nested = "示例问题：「「工单系统」的负责人是谁？」"
        XCTAssertEqual(NoteAskQuestion.normalized(nested), "「工单系统」的负责人是谁？")
        let qualified = "有哪些需求？请根据便签核对只属于二期的事项。"
        XCTAssertEqual(NoteAskQuestion.retrievalText(for: qualified), qualified)
    }

    func testEmptyRetrievalReturnsNoEvidenceWithoutCallingModel() async throws {
        let stub = Stub()
        let controller = makeController(stub, hits: [])
        controller.activate(question: "什么时候开会？")
        controller.answerQuestion()
        try await waitUntil { !controller.isRetrieving }
        XCTAssertEqual(controller.notice, "便签里没有找到相关内容")
        XCTAssertEqual(stub.confirmations, 0)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testQuestionRefreshesWhenKeywordsAndHybridIndexBecomeReadyWithoutSending() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = NoteIndexSnapshot(noteID: UUID(), title: "档案", text: "手稿保存在蓝色档案夹", revision: 1)
        let embeddings = DispatchSemaphore(value: 0)
        let index = SemanticIndex(directory: directory, embedding: {
            .init(model: .init(identifier: "synthetic", revision: 1, dimension: 2), vector: { text in
                if text == snapshot.text { _ = embeddings.wait(timeout: .now() + 5) }
                return [1, 0]
            })
        })
        defer { embeddings.signal() }
        let stub = Stub()
        let controller = NoteAskController(index: index, sourceLocation: { _ in "便签集" },
                                           resolveModel: stub.model, retrievalDelay: .zero)
        index.beginLibraryLoad()
        controller.activate(question: "手稿在哪？")
        try await waitUntil { controller.notice == NoteAskController.noEvidenceMessage }
        XCTAssertTrue(controller.isIndexBuilding)
        index.replaceLibrary(with: [snapshot])
        try await waitUntil { controller.evidence.count == 1 }
        XCTAssertTrue(controller.isIndexBuilding)
        XCTAssertEqual(controller.indexMode, .keyword)

        embeddings.signal()
        await index.flushPending()
        try await waitUntil { controller.indexMode == .hybrid && !controller.isIndexBuilding }
        XCTAssertEqual(controller.evidence.map { $0.chunk.noteID }, [snapshot.noteID])
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testStreamFiltersInvalidAndSplitCitationsAndPreservesValidReferences() async throws {
        let id = UUID()
        let stub = Stub()
        stub.eligible = [id]
        let controller = makeController(stub, hits: [hit(id, "会议在周二。"), hit(id, "会议地点为会议室。")])
        controller.activate(question: "会议安排？")
        try await waitUntil { controller.canAnswer }
        controller.answerQuestion()
        let stream = try XCTUnwrap(stub.streams.first)

        stream.yield(.delta("周二开会[1"))
        try await waitUntil { controller.answer.contains("周二") }
        XCTAssertFalse(controller.answer.contains("["))
        stream.yield(.delta("][99]，地点为会议室[2]"))
        try await waitUntil { controller.citedNumbers == [1, 2] }
        XCTAssertFalse(controller.answer.contains("[99]"))
        stream.yield(.completed(.init(text: "周二开会[1][99]，地点为会议室[2]")))
        stream.finish()
        try await waitUntil { !controller.isLoading }

        XCTAssertEqual(controller.answer, "周二开会[1]，地点为会议室[2]")
        XCTAssertEqual(controller.citedNumbers, [1, 2])
        XCTAssertNil(controller.notice)
        XCTAssertEqual(Set(controller.evidence.map { $0.chunk.noteID }).count, 1)
    }

    func testWaitingForFirstVisibleAnswerEndsWhenStreamingTextArrives() async throws {
        let id = UUID()
        let stub = Stub()
        stub.eligible = [id]
        let controller = makeController(stub, hits: [hit(id, "会议在周二。")])
        controller.activate(question: "什么时候开会？")
        try await waitUntil { controller.canAnswer }
        controller.answerQuestion()
        let stream = try XCTUnwrap(stub.streams.first)
        XCTAssertTrue(controller.isWaitingForAnswer)
        XCTAssertEqual(controller.answer, "")

        stream.yield(.started(providerName: "合成服务"))
        stream.yield(.delta("周二开会[1]"))
        try await waitUntil { !controller.isWaitingForAnswer }
        XCTAssertTrue(controller.isLoading)
        XCTAssertEqual(controller.answer, "周二开会[1]")
        controller.stop()
    }

    func testTimedOutBeforeAnswerEndsWaitingAndOffersRetry() async throws {
        let id = UUID()
        let stub = Stub()
        stub.eligible = [id]
        let controller = makeController(stub, hits: [hit(id, "会议在周二。")])
        controller.activate(question: "什么时候开会？")
        try await waitUntil { controller.canAnswer }
        controller.answerQuestion()
        let stream = try XCTUnwrap(stub.streams.first)
        XCTAssertTrue(controller.isWaitingForAnswer)
        stream.finish(throwing: URLError(.timedOut))
        try await waitUntil { !controller.isLoading }
        XCTAssertFalse(controller.isWaitingForAnswer)
        XCTAssertTrue(controller.canAnswer)
        XCTAssertEqual(controller.notice, "等待模型回复超时，请重试。")
    }

    func testUncitedAnswerAndModelNoAnswerKeepEvidenceAndShowNotice() async throws {
        let id = UUID()
        let stub = Stub()
        stub.eligible = [id]
        let controller = makeController(stub, hits: [hit(id, "备份已经完成。")])
        controller.activate(question: "什么时候开会？")
        try await waitUntil { controller.canAnswer }

        for (raw, visible) in [("便签里没有找到相关内容", "便签里没有找到相关内容"), ("未核实的回答[15]", "未核实的回答")] {
            controller.answerQuestion()
            let stream = try XCTUnwrap(stub.streams.last)
            stream.yield(.completed(.init(text: raw)))
            stream.finish()
            try await waitUntil { !controller.isLoading }
            XCTAssertEqual(controller.answer, visible)
            XCTAssertEqual(controller.notice, "未能标注出处")
            XCTAssertEqual(controller.evidence.count, 1)
            XCTAssertTrue(controller.citedNumbers.isEmpty)
        }
    }

    func testLocalChoiceDoesNotSendToCloudWhenFoundationModelIsUnavailable() async throws {
        let id = UUID()
        let stub = Stub()
        stub.eligible = [id]
        stub.availableDestinations = [.cloud]
        let controller = makeController(stub, hits: [hit(id, "项目周二提交。")])
        controller.activate(question: "项目何时提交？")
        controller.setDestination(.local)
        try await waitUntil { !controller.isRetrieving }
        controller.answerQuestion()
        XCTAssertEqual(controller.destination, .local)
        XCTAssertEqual(controller.destinationName, "本机")
        XCTAssertEqual(controller.evidence.count, 1)
        XCTAssertFalse(controller.canAnswer)
        XCTAssertEqual(controller.notice, "本机模型不可用，以下为检索结果。")
        XCTAssertEqual(stub.confirmations, 0)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testSelectingAvailableLocalModelUsesLocalRoute() async throws {
        let id = UUID()
        let stub = Stub()
        stub.eligible = [id]
        let controller = makeController(stub, hits: [hit(id, "项目周二提交。")])
        controller.activate(question: "项目何时提交？")
        controller.setDestination(.local)
        try await waitUntil { controller.canAnswer }
        controller.answerQuestion()
        XCTAssertEqual(controller.destination, .local)
        XCTAssertEqual(controller.destinationName, "本机")
        XCTAssertEqual(stub.requests.count, 1)
        controller.stop()
    }

    func testConfiguredCodexSnapshotsRouteAcrossConfirmationAndRechecksSourcesAtSend() async throws {
        let id = UUID(), sensitive = UUID()
        let stub = Stub()
        stub.eligible = [id]
        stub.availableDestinations.insert(.configured)
        let controller = makeController(stub, hits: [hit(sensitive, "不可发送的片段"), hit(id, "可用资料")],
                                        initialDestination: .configured)
        controller.activate(question: "有哪些资料？")
        try await waitUntil { controller.canAnswer }
        stub.onConfirm = { stub.configuredUsesCodex = false }
        controller.answerQuestion()

        XCTAssertEqual(controller.destination, .configured)
        XCTAssertEqual(controller.destinationName, CodexLocalPreferences.destinationName)
        XCTAssertEqual(controller.waitingMessage, "正在等待 Codex…")
        XCTAssertEqual(stub.requestedDestinations, [.configured])
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertTrue(request.user.contains("可用资料"))
        XCTAssertFalse(request.user.contains("不可发送的片段"))

        let preflight = try XCTUnwrap(stub.preflights.first)
        XCTAssertNoThrow(try preflight())
        stub.eligible.remove(id)
        XCTAssertThrowsError(try preflight())
        controller.stop()
    }

    func testConfiguredCodexFailureDoesNotFallbackAndShowsReason() async throws {
        let id = UUID()
        let stub = Stub()
        stub.eligible = [id]
        stub.availableDestinations.insert(.configured)
        let controller = makeController(stub, hits: [hit(id, "合成资料")], initialDestination: .configured)
        controller.activate(question: "有哪些资料？")
        try await waitUntil { controller.canAnswer }
        controller.answerQuestion()
        try XCTUnwrap(stub.streams.first).finish(throwing: CodexLocalError.unavailable)

        try await waitUntil { !controller.isLoading }
        XCTAssertEqual(controller.notice, CodexLocalError.unavailable.localizedDescription)
        XCTAssertEqual(stub.requestedDestinations, [.configured])
    }

    func testSensitiveResultsAreFilteredAndEligibilityIsCheckedAgainAfterConfirmation() async throws {
        let id = UUID(), sensitive = UUID()
        let stub = Stub()
        stub.eligible = [id]
        let controller = makeController(stub, hits: [hit(sensitive, "禁止发送的文本"), hit(id, "合法的片段")])
        controller.activate(question: "哪里有资料？")
        try await waitUntil { controller.canAnswer }
        XCTAssertEqual(controller.evidence.map { $0.chunk.noteID }, [id])

        stub.onConfirm = { stub.eligible.remove(id) }
        controller.answerQuestion()
        XCTAssertEqual(stub.confirmations, 1)
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertTrue(controller.evidence.isEmpty)
        XCTAssertEqual(controller.notice, NoteAskController.noEvidenceMessage)
    }

    func testDecliningConfirmationDoesNotStartTransport() async throws {
        let id = UUID()
        let stub = Stub()
        stub.eligible = [id]
        stub.confirm = false
        let controller = makeController(stub, hits: [hit(id, "会后发出纪要。")])
        controller.activate(question: "如何同步纪要？")
        try await waitUntil { controller.canAnswer }
        controller.answerQuestion()
        XCTAssertEqual(stub.confirmations, 1)
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertFalse(controller.isLoading)
    }

    func testRevokedSourceCancelsStreamAndRejectsLateOutputAndRetry() async throws {
        let id = UUID(), other = UUID()
        let stub = Stub()
        stub.eligible = [id, other]
        let controller = makeController(stub, hits: [hit(id, "旧片段"), hit(other, "可用片段")])
        controller.activate(question: "怎样整理？")
        try await waitUntil { controller.canAnswer }
        controller.answerQuestion()
        let stream = try XCTUnwrap(stub.streams.first)
        let preflight = try XCTUnwrap(stub.preflights.first)
        XCTAssertNoThrow(try preflight())
        stream.yield(.delta("旧的输出[1]"))
        try await waitUntil { !controller.answer.isEmpty }

        stub.eligible.remove(id)
        controller.invalidateNote(id)
        XCTAssertThrowsError(try preflight())
        stream.yield(.completed(.init(text: "迟到的旧结果[1]")))
        stream.finish()
        await Task.yield()

        XCTAssertEqual(controller.evidence.map { $0.chunk.noteID }, [other])
        XCTAssertEqual(controller.answer, "")
        XCTAssertTrue(controller.citedNumbers.isEmpty)
        XCTAssertFalse(controller.isLoading)
    }

    func testNewQuestionOwnsItsStreamAndDiscardedQuestionCannotOverwrite() async throws {
        let id = UUID()
        let stub = Stub()
        stub.eligible = [id]
        let controller = makeController(stub, hits: [hit(id, "素材")])
        controller.activate(question: "旧问题？")
        try await waitUntil { controller.canAnswer }
        controller.answerQuestion()
        let old = try XCTUnwrap(stub.streams.first)

        controller.setQuestion("新问题？")
        try await waitUntil { controller.canAnswer }
        controller.answerQuestion()
        let current = try XCTUnwrap(stub.streams.last)
        XCTAssertEqual(stub.streams.count, 2)
        current.yield(.completed(.init(text: "新答案[1]")))
        current.finish()
        try await waitUntil { !controller.isLoading }
        old.yield(.completed(.init(text: "旧答案[1]")))
        old.finish()
        await Task.yield()

        XCTAssertEqual(controller.answer, "新答案[1]")
        XCTAssertTrue(stub.requests.last?.user.contains("新问题") == true)
    }

    func testRetrievalUsesSixFragmentsAndRemovalExcludesAllFragmentsOfThatNote() async throws {
        let removed = UUID(), kept = UUID()
        let stub = Stub()
        stub.eligible = [removed, kept]
        let hits = (1...8).map { hit($0 <= 2 ? removed : kept, "片段\($0)") }
        var limits: [Int] = []
        let controller = NoteAskController(search: { _, limit in
            limits.append(limit)
            return .init(mode: .keyword, hits: hits)
        }, sourceLocation: { stub.eligible.contains($0) ? "测试文件夹" : nil },
           resolveModel: stub.model, retrievalDelay: .zero)
        controller.activate(question: "片段内容？")
        try await waitUntil { controller.canAnswer }
        XCTAssertEqual(limits, [6])
        XCTAssertEqual(controller.evidence.count, 6)
        controller.removeNote(removed)
        XCTAssertEqual(controller.evidence.map(\.number), [1, 2, 3, 4])
        controller.answerQuestion()
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertFalse(request.user.contains("片段1"))
        XCTAssertFalse(request.user.contains("片段2"))
        XCTAssertFalse(request.user.contains("片段7"))
        XCTAssertTrue(request.user.contains("片段3"))
        XCTAssertFalse(request.user.contains("测试文件夹"))
        controller.stop()
    }

    private func makeController(_ stub: Stub, hits: [NoteIndexHit],
                                initialDestination: NoteAskDestination? = nil) -> NoteAskController {
        NoteAskController(search: { _, _ in .init(mode: .keyword, hits: hits) },
                          sourceLocation: { stub.eligible.contains($0) ? "便签集" : nil },
                          resolveModel: stub.model, presentation: AIStreamPresentation(interval: .zero),
                          initialDestination: initialDestination,
                          retrievalDelay: .zero)
    }

    private func hit(_ id: UUID, _ text: String) -> NoteIndexHit {
        NoteIndexHit(chunk: .init(noteID: id, title: "本地标题", text: text,
                                  range: NSRange(location: 0, length: text.utf16.count), revision: 0),
                     score: 1, keywordScore: 1, cosineSimilarity: nil)
    }

    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "问答状态未在期限内更新", file: file, line: line)
    }
}
