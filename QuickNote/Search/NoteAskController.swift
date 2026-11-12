import Combine
import Foundation

@MainActor
final class NoteAskController: ObservableObject {
    static let noEvidenceMessage = Prompts.AskAnswer.noEvidence

    typealias Search = @MainActor (String, Int) async -> NoteIndexSearchResult
    typealias SourceLocation = @MainActor (UUID) -> String?
    typealias ResolveModel = @MainActor (NoteAskDestination) -> NoteAskModel

    @Published private(set) var evidence: [NoteAskEvidence] = []
    @Published private(set) var answer = ""
    @Published private(set) var citedNumbers: [Int] = []
    @Published private(set) var isIndexBuilding = false
    @Published private(set) var indexMode: NoteIndexMode?
    @Published private(set) var isRetrieving = false
    @Published private(set) var isLoading = false
    @Published private(set) var notice: String?
    @Published private(set) var destination = NoteAskDestination.local
    @Published private(set) var destinationName = ""

    var isModelAvailable: Bool { model?.isAvailable == true }
    var isWaitingForAnswer: Bool { isLoading && answer.isEmpty }
    var waitingMessage: String { model?.isCodex == true ? "正在等待 Codex…" : "正在等待模型回复…" }
    var canAnswer: Bool { !isLoading && !isRetrieving && !evidence.isEmpty && isModelAvailable }

    private let search: Search
    private let sourceLocation: SourceLocation
    private let resolveModel: ResolveModel
    private let initialDestination: NoteAskDestination?
    private let presentation: AIStreamPresentation
    private let retrievalDelay: Duration
    private var indexSubscriptions: Set<AnyCancellable> = []
    private var retrievalTask: Task<Void, Never>?
    private var model: NoteAskModel?
    private var destinationChosen = false
    private var active = false
    private var question = ""
    private var excludedNoteIDs: Set<UUID> = []
    private var answerRequested = false
    private var needsReadyRetrieval = false
    private var generation = 0

    init(search: @escaping Search, sourceLocation: @escaping SourceLocation,
         resolveModel: @escaping ResolveModel, presentation: AIStreamPresentation = AIStreamPresentation(),
         initialDestination: NoteAskDestination? = nil,
         retrievalDelay: Duration = .milliseconds(150)) {
        self.search = search
        self.sourceLocation = sourceLocation
        self.resolveModel = resolveModel
        self.initialDestination = initialDestination
        self.presentation = presentation
        self.retrievalDelay = retrievalDelay
    }

    convenience init(index: SemanticIndex, sourceLocation: @escaping SourceLocation,
                     retrievalDelay: Duration = .milliseconds(150)) {
        self.init(index: index, sourceLocation: sourceLocation,
                  resolveModel: { NoteAskModel.resolve($0) }, initialDestination: .configured,
                  retrievalDelay: retrievalDelay)
    }

    convenience init(index: SemanticIndex, sourceLocation: @escaping SourceLocation,
                     resolveModel: @escaping ResolveModel, initialDestination: NoteAskDestination? = nil,
                     retrievalDelay: Duration = .milliseconds(150)) {
        self.init(search: { query, limit in await index.searchAvailable(query, limit: limit) },
                  sourceLocation: sourceLocation, resolveModel: resolveModel,
                  initialDestination: initialDestination, retrievalDelay: retrievalDelay)
        index.$isBuilding.sink { [weak self] building in
            self?.indexBuildingChanged(building)
        }.store(in: &indexSubscriptions)
        index.$keywordRevision.dropFirst().sink { [weak self] _ in
            guard let self, active, !isLoading, answer.isEmpty else { return }
            retrieve()
        }.store(in: &indexSubscriptions)
    }

    func activate(question: String) {
        if active {
            setQuestion(question)
            return
        }
        active = true
        if destinationChosen {
            useModel(resolveModel(destination), destination: destination)
        } else if let initialDestination {
            useModel(resolveModel(initialDestination), destination: initialDestination)
        } else {
            let cloud = resolveModel(.cloud)
            if cloud.isAvailable {
                useModel(cloud, destination: .cloud)
            } else {
                useModel(resolveModel(.local), destination: .local)
            }
        }
        setQuestion(question)
    }

    func deactivate() {
        active = false
        cancelWork()
        question = ""
        needsReadyRetrieval = false
        excludedNoteIDs.removeAll()
        evidence = []
        indexMode = nil
        clearAnswer()
    }

    func setQuestion(_ value: String) {
        let value = NoteAskQuestion.normalized(value)
        guard active, value != question else { return }
        cancelWork()
        question = value
        excludedNoteIDs.removeAll()
        evidence = []
        indexMode = nil
        clearAnswer()
        retrieve()
    }

    func setDestination(_ value: NoteAskDestination) {
        guard active, value != destination else { return }
        destinationChosen = true
        let wasRetrieving = isRetrieving
        cancelWork()
        clearAnswer()
        useModel(resolveModel(value), destination: value)
        if wasRetrieving { retrieve() }
        else { describeEvidence() }
    }

    func answerQuestion() {
        guard active, !question.isEmpty, !isLoading else { return }
        if isRetrieving || needsReadyRetrieval {
            answerRequested = true
            if !isRetrieving { retrieve() }
            return
        }
        discardIneligibleEvidence()
        if destination == .configured {
            useModel(resolveModel(.configured), destination: .configured)
        }
        guard let model, canAnswer else {
            describeEvidence()
            return
        }

        generation += 1
        let expected = generation
        let sources = evidence
        let sourceIDs = Set(sources.map { $0.chunk.noteID })
        clearAnswer()
        isLoading = true
        let confirmed = model.confirm()
        guard generation == expected, active else { return }
        guard confirmed, sourcesAreEligible(sourceIDs) else {
            isLoading = false
            discardIneligibleEvidence()
            describeEvidence()
            return
        }

        let request = NoteAskRequest(question: question, evidence: sources)
        presentation.onUpdate = { [weak self] snapshot in
            self?.receive(snapshot, generation: expected, sources: sources, sourceIDs: sourceIDs)
        }
        presentation.start(model.start(request, { [weak self] in
            guard let self, self.active, self.generation == expected,
                  self.sourcesAreEligible(sourceIDs) else { throw CancellationError() }
        }))
    }

    func stop() {
        guard isLoading else { return }
        cancelWork()
        notice = answer.isEmpty ? "已停止" : "已停止，结果可能不完整"
    }

    func removeNote(_ id: UUID) {
        guard active, evidence.contains(where: { $0.chunk.noteID == id }) else { return }
        excludedNoteIDs.insert(id)
        removeEvidence(for: id)
    }

    func invalidateNote(_ id: UUID) {
        guard active, evidence.contains(where: { $0.chunk.noteID == id }) else { return }
        removeEvidence(for: id)
    }

    func invalidateLibrary() {
        guard active else { return }
        cancelWork()
        clearAnswer()
        evidence = []
        indexMode = nil
        retrieve()
    }

    private func useModel(_ value: NoteAskModel, destination: NoteAskDestination) {
        model = value
        self.destination = destination
        destinationName = value.destination
    }

    private func indexBuildingChanged(_ building: Bool) {
        let becameReady = isIndexBuilding && !building
        isIndexBuilding = building
        guard becameReady, active else { return }
        if isLoading || !answer.isEmpty {
            needsReadyRetrieval = true
        } else {
            retrieve()
        }
    }

    private func retrieve() {
        guard active, !question.isEmpty else { return }
        needsReadyRetrieval = false
        retrievalTask?.cancel()
        let expected = generation
        let query = NoteAskQuestion.retrievalText(for: question)
        isRetrieving = true
        notice = nil
        retrievalTask = Task { [weak self, search, retrievalDelay] in
            do { try await Task.sleep(for: retrievalDelay) } catch { return }
            let result = await search(query, 6)
            guard let self, !Task.isCancelled, generation == expected else { return }
            indexMode = result.mode
            evidence = result.hits.prefix(6).reduce(into: []) { matches, hit in
                let id = hit.chunk.noteID
                guard !excludedNoteIDs.contains(id), let location = sourceLocation(id) else { return }
                matches.append(NoteAskEvidence(number: matches.count + 1, chunk: hit.chunk, location: location))
            }
            retrievalTask = nil
            isRetrieving = false
            describeEvidence()
            if answerRequested {
                answerRequested = false
                answerQuestion()
            }
        }
    }

    private func receive(_ snapshot: AIStreamPresentationState, generation expected: Int,
                         sources: [NoteAskEvidence], sourceIDs: Set<UUID>) {
        guard active, generation == expected else { return }
        if !snapshot.isLoading, !sourcesAreEligible(sourceIDs) {
            cancelWork()
            clearAnswer()
            discardIneligibleEvidence()
            describeEvidence()
            return
        }
        let parsed = AskCitationParser.parse(snapshot.text, validNumbers: Set(sources.map(\.number)),
                                             streaming: snapshot.isLoading)
        answer = parsed.text
        citedNumbers = parsed.references
        isLoading = snapshot.isLoading
        switch snapshot.phase {
        case .completed:
            notice = citedNumbers.isEmpty ? "未能标注出处" : nil
        case .incomplete:
            notice = citedNumbers.isEmpty ? "结果可能不完整 · 未能标注出处" : "结果可能不完整"
        case .failed:
            if !answer.isEmpty {
                notice = "生成中断，结果可能不完整。"
            } else if model?.isCodex == true, let error = snapshot.error {
                notice = error.localizedDescription
            } else if (snapshot.error as? URLError)?.code == .timedOut {
                notice = "等待模型回复超时，请重试。"
            } else {
                notice = "暂时无法生成回答，请重试。"
            }
        default:
            break
        }
    }

    private func sourcesAreEligible(_ ids: Set<UUID>) -> Bool {
        ids.allSatisfy { !excludedNoteIDs.contains($0) && sourceLocation($0) != nil }
    }

    private func discardIneligibleEvidence() {
        let current = evidence.filter { sourceLocation($0.chunk.noteID) != nil }
        if current.count != evidence.count {
            clearAnswer()
            setEvidence(current)
        }
    }

    private func setEvidence(_ items: [NoteAskEvidence]) {
        evidence = items.enumerated().map { index, item in
            NoteAskEvidence(number: index + 1, chunk: item.chunk, location: item.location)
        }
    }

    private func removeEvidence(for id: UUID) {
        cancelWork()
        clearAnswer()
        setEvidence(evidence.filter { $0.chunk.noteID != id })
        describeEvidence()
    }

    private func describeEvidence() {
        if question.isEmpty {
            notice = nil
        } else if evidence.isEmpty {
            notice = Self.noEvidenceMessage
        } else if !isModelAvailable {
            notice = switch destination {
            case .local: "本机模型不可用，以下为检索结果。"
            case .cloud: "尚未配置可用的云端模型，以下为检索结果。"
            case .configured: "所选模型不可用，以下为检索结果。"
            }
        } else {
            notice = nil
        }
    }

    private func clearAnswer() {
        answer = ""
        citedNumbers = []
        notice = nil
    }

    private func cancelWork() {
        generation += 1
        retrievalTask?.cancel()
        retrievalTask = nil
        answerRequested = false
        isRetrieving = false
        presentation.onUpdate = nil
        presentation.stop()
        isLoading = false
    }
}
