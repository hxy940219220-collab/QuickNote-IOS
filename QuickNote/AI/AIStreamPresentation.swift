import Foundation

enum AIStreamPhase: Equatable {
    case idle
    case streaming
    case completed
    case incomplete
    case stopped
    case failed
}

struct AIStreamPresentationState {
    var text = ""
    var providerName = ""
    var phase = AIStreamPhase.idle
    var notice = ""
    var error: (any Error)?

    var isLoading: Bool { phase == .streaming }
    var canImport: Bool { !isLoading && !text.isEmpty }
    var isPartial: Bool {
        !text.isEmpty && (phase == .incomplete || phase == .stopped || phase == .failed)
    }
}

/// Owns the lifetime and visible state of one analysis, independently of its panel.
@MainActor
final class AIStreamPresentation {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private(set) var snapshot = AIStreamPresentationState()
    var onUpdate: ((AIStreamPresentationState) -> Void)?
    private let interval: Duration
    private let sleep: Sleep
    private var generation = 0
    private var pendingText = ""
    private var consumerTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?

    init(interval: Duration = .milliseconds(50), sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.interval = interval
        self.sleep = sleep
    }

    @discardableResult
    func begin() -> Int {
        consumerTask?.cancel()
        consumerTask = nil
        cancelFlush()
        generation += 1
        pendingText = ""
        snapshot = AIStreamPresentationState(phase: .streaming)
        publish()
        return generation
    }

    func start(
        _ stream: AsyncThrowingStream<AIStreamEvent, Error>,
        finalTransform: @escaping @MainActor (String) -> String = { $0 }
    ) {
        let current = begin()
        consumerTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard let self, !Task.isCancelled, self.accepts(current) else { return }
                    if case .completed(let completion) = event, completion.isComplete {
                        self.receive(.completed(AIStreamCompletion(
                            text: finalTransform(completion.text),
                            providerName: completion.providerName,
                            finishReason: completion.finishReason
                        )), generation: current)
                    } else {
                        self.receive(event, generation: current)
                    }
                }
                guard let self, !Task.isCancelled, self.accepts(current) else { return }
                self.fail(AIStreamingError.unexpectedEnd, generation: current)
            } catch {
                guard let self, !Task.isCancelled, self.accepts(current) else { return }
                self.fail(error, generation: current)
            }
        }
    }

    func receive(_ event: AIStreamEvent, generation expected: Int) {
        guard accepts(expected) else { return }
        switch event {
        case .started(let providerName):
            cancelFlush()
            pendingText = ""
            snapshot.text = ""
            snapshot.providerName = providerName
            publish()
        case .delta(let text):
            pendingText += text
            scheduleFlush(generation: expected)
        case .snapshot(let text):
            pendingText = text
            scheduleFlush(generation: expected)
        case .completed(let completion):
            cancelFlush()
            pendingText = completion.text
            snapshot.text = completion.text
            if !completion.providerName.isEmpty { snapshot.providerName = completion.providerName }
            snapshot.phase = completion.isComplete ? .completed : .incomplete
            snapshot.notice = completion.isComplete ? "" : "结果可能不完整"
            publish()
        }
    }

    func fail(_ error: any Error, generation expected: Int) {
        guard accepts(expected) else { return }
        cancelFlush()
        snapshot.text = pendingText
        snapshot.phase = .failed
        snapshot.error = error
        snapshot.notice = error.localizedDescription
        if !snapshot.text.isEmpty { snapshot.notice += "\n结果可能不完整" }
        publish()
    }

    func stop() {
        generation += 1
        consumerTask?.cancel()
        consumerTask = nil
        cancelFlush()
        pendingText = snapshot.text
        guard snapshot.isLoading else { return }
        snapshot.phase = .stopped
        snapshot.notice = snapshot.text.isEmpty ? "已停止" : "已停止，结果可能不完整"
        publish()
    }

    /// Adapts callers that must retain their existing complete-response contract.
    static func singleResult(
        _ operation: @escaping @MainActor () async throws -> AITextResult
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let result = try await operation()
                    try Task.checkCancellation()
                    continuation.yield(.completed(AIStreamCompletion(text: result.text, providerName: result.providerName)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func accepts(_ expected: Int) -> Bool {
        generation == expected && snapshot.isLoading
    }

    private func scheduleFlush(generation expected: Int) {
        guard flushTask == nil, pendingText != snapshot.text else { return }
        let sleep = sleep
        let interval = interval
        flushTask = Task { [weak self] in
            do { try await sleep(interval) } catch { return }
            guard let self, !Task.isCancelled, self.accepts(expected) else { return }
            self.flushTask = nil
            self.snapshot.text = self.pendingText
            self.publish()
        }
    }

    private func cancelFlush() {
        flushTask?.cancel()
        flushTask = nil
    }

    private func publish() { onUpdate?(snapshot) }
}
