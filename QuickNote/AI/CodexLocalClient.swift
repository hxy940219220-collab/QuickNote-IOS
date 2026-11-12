import Foundation

struct CodexLocalTarget: Sendable, Equatable {
    let executable: URL
    let sha256: String
    let version: String
    var model: String? = nil
    var effort: String = "low"

    func hasSameExecutable(as other: Self) -> Bool {
        executable == other.executable && sha256 == other.sha256 && version == other.version
    }

    func checking(model: String) -> Self {
        var target = self
        target.model = model
        return target
    }
}

struct CodexLocalModel: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let efforts: [String]
    let isDefault: Bool
    var defaultEffort: String? = nil
}

struct CodexQuotaUpdate: Sendable {
    let target: CodexLocalTarget
    let limits: CodexRateLimits?
    let problem: String?
}

struct CodexLocalRequest: Sendable {
    let prompt: String
    var image: Data? = nil
    var outputSchema: Data? = nil
}

private final class CodexLocalJob: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if isCancelled { throw CancellationError() } }
}

actor CodexLocalClient {
    static let shared = CodexLocalClient()

    private struct Resident: Sendable {
        let target: CodexLocalTarget
        let root: URL
        let protected: URL
        let workspaces: URL
        let state: URL
        let server: CodexAppServer
        let registry: [String: CodexMCPRegistration]
        let metadataOnly: Bool
    }

    private struct Prepared {
        let context: CodexAppServer.ThreadContext
        let directory: URL
    }

    private struct Flight {
        let server: CodexAppServer
        let thread: String
        var turn: String?
        var interrupt: Task<Void, Never>?
        var stopTimer: Task<Void, Never>?
        var stopDeadline: ContinuousClock.Instant?
    }

    private struct Waiter {
        let job: CodexLocalJob
        let continuation: CheckedContinuation<Void, Error>
    }

    private let processFactory: CodexLocalProcessFactory
    private let idleTimeout: Duration
    private let interruptTimeout: Duration
    private let textTimeout: Duration
    private let imageTimeout: Duration
    private var resident: Resident?
    private var retirement: Task<Bool, Never>?
    private var retirementFailed = false
    private var active: CodexLocalJob?
    private var flight: Flight?
    private var waiters: [Waiter] = []
    private var idleTask: Task<Void, Never>?
    private var idleGeneration = UUID()
    private var shuttingDown = false
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var quotaRefreshTask: Task<Void, Never>?
    private var quotaRefreshID = UUID()
    private var quotaObservers: [UUID: AsyncStream<CodexQuotaUpdate>.Continuation] = [:]

    init(
        processFactory: CodexLocalProcessFactory? = nil,
        idleTimeout: Duration = .seconds(600), interruptTimeout: Duration = .seconds(2),
        textTimeout: Duration = .seconds(90), imageTimeout: Duration = .seconds(120)
    ) {
        self.processFactory = processFactory ?? { target, args, cwd, offline, protected, workspaces in
            try CodexLocalIsolation.process(
                executable: target.executable, arguments: args, directory: cwd, offline: offline,
                protectedDirectory: protected, workspacesDirectory: workspaces
            )
        }
        self.idleTimeout = idleTimeout
        self.interruptTimeout = interruptTimeout
        self.textTimeout = textTimeout
        self.imageTimeout = imageTimeout
    }

    func models(for target: CodexLocalTarget) async throws -> [CodexLocalModel] {
        try await accountOperation(target: target) { resident, deadline in
            try await resident.server.models(deadline: deadline)
        }
    }

    func account(for target: CodexLocalTarget) async throws -> CodexAccount? {
        try await accountOperation(target: target) { resident, deadline in
            try await resident.server.account(deadline: deadline)
        }
    }

    func rateLimits(for target: CodexLocalTarget) async throws -> CodexRateLimits {
        try await accountOperation(target: target) { resident, deadline in
            try await resident.server.rateLimits(deadline: deadline)
        }
    }

    func quotaUpdates() -> AsyncStream<CodexQuotaUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CodexQuotaUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        quotaObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeQuotaObserver(id) }
        }
        return stream
    }

    func login(target: CodexLocalTarget, openURL: @escaping @MainActor @Sendable (URL) -> Bool) async throws {
        try await accountOperation(target: target) { resident, deadline in
            let login: CodexManagedLogin
            do {
                login = try await resident.server.startLogin(deadline: deadline)
            } catch CodexLocalError.methodUnavailable {
                await discard(resident)
                try await CodexLocalSelfCheck.loginWithCLI(target: target, openURL: openURL)
                CodexLocalSelfCheck.clearVerification()
                return
            } catch {
                await discard(resident)
                throw error
            }
            do {
                try Task.checkCancellation()
                guard await openURL(login.url) else { throw CodexLocalError.requestFailed }
                try await resident.server.waitForLogin(id: login.id, deadline: .now + .seconds(180))
                try Task.checkCancellation()
            } catch {
                do {
                    try await resident.server.cancelLogin(id: login.id, deadline: .now + .seconds(2))
                } catch {
                    await discard(resident)
                }
                throw error
            }
            CodexLocalSelfCheck.clearVerification()
            await discard(resident)
        }
    }

    func logout(target: CodexLocalTarget) async throws {
        try await accountOperation(target: target) { resident, deadline in
            try await resident.server.logout(deadline: deadline)
            CodexLocalSelfCheck.clearVerification()
            await discard(resident)
        }
    }

    private func accountOperation<Result: Sendable>(
        target: CodexLocalTarget, operation: (Resident, ContinuousClock.Instant) async throws -> Result
    ) async throws -> Result {
        let job = CodexLocalJob()
        return try await withTaskCancellationHandler {
            try await acquire(job)
            defer { release(job) }
            let deadline = ContinuousClock.now + .seconds(20)
            let resident = try await connection(for: target, job: job, deadline: deadline, metadataOnly: true)
            try job.check()
            let result = try await operation(resident, deadline)
            try job.check()
            return result
        } onCancel: {
            job.cancel()
            Task { await self.requestStop(job) }
        }
    }

    func selfCheck(target: CodexLocalTarget, force: Bool = false) async throws {
        let job = CodexLocalJob()
        try await withTaskCancellationHandler {
            try await acquire(job)
            defer { release(job) }
            let deadline = ContinuousClock.now + .seconds(90)
            let resident = try await connection(for: target, job: job, deadline: deadline)
            try await withPrepared(resident, model: target.model, job: job, deadline: deadline) { prepared in
                try await ensureVerified(
                    target: target, model: prepared.context.model, resident: resident,
                    job: job, deadline: deadline, force: force
                )
            }
        } onCancel: {
            job.cancel()
            Task { await self.requestStop(job) }
        }
    }

    func testConnection(target: CodexLocalTarget) async throws {
        let output = stream(
            .init(prompt: "仅回复 QUICKNOTE_CONNECTION_OK，不要添加其他文字。"), target: target,
            refreshQuota: false
        )
        var text = ""
        for try await delta in output { text += delta }
        guard text.contains("QUICKNOTE_CONNECTION_OK") else { throw CodexLocalError.requestFailed }
    }

    func stream(
        _ request: CodexLocalRequest, target: CodexLocalTarget,
        refreshQuota: Bool = true,
        preflight: @escaping @Sendable () async throws -> Void = {}
    ) -> AsyncThrowingStream<String, Error> {
        let job = CodexLocalJob()
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                job.cancel()
                Task { await self?.requestStop(job) }
            }
        }
        Task {
            do {
                try await acquire(job)
                defer { release(job) }
                let deadline = ContinuousClock.now + (request.image == nil ? textTimeout : imageTimeout)
                let resident = try await connection(for: target, job: job, deadline: deadline)
                try await withPrepared(resident, model: target.model, job: job, deadline: deadline) { prepared in
                    try await ensureVerified(
                        target: target, model: prepared.context.model, resident: resident,
                        job: job, deadline: deadline
                    )
                    let verifiedTarget = target.checking(model: prepared.context.model)
                    guard CodexLocalSelfCheck.isVerified(verifiedTarget) else {
                        throw CodexLocalError.unverified("当前模型尚未通过自检")
                    }
                    _ = try await run(
                        request, prepared: prepared, resident: resident, job: job, deadline: deadline,
                        preflight: preflight
                    ) { delta in
                        if !job.isCancelled { continuation.yield(delta) }
                    }
                }
                continuation.finish()
                if refreshQuota { scheduleQuotaRefresh(on: resident) }
            } catch {
                continuation.finish(throwing: job.isCancelled ? CancellationError() : error)
            }
        }
        return stream
    }

    func shutdown() async {
        shuttingDown = true
        idleTask?.cancel()
        idleTask = nil
        active?.cancel()
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.continuation.resume(throwing: CancellationError()) }
        if let resident { await discard(resident) }
        if active != nil {
            await withCheckedContinuation { continuation in
                shutdownWaiters.append(continuation)
            }
        }
        if let retirement { _ = await retirement.value }
        shuttingDown = false
    }

    private func removeQuotaObserver(_ id: UUID) {
        quotaObservers.removeValue(forKey: id)
    }

    private func scheduleQuotaRefresh(on value: Resident) {
        quotaRefreshTask?.cancel()
        let id = UUID()
        quotaRefreshID = id
        quotaRefreshTask = Task(priority: .utility) { [weak self] in
            let update: CodexQuotaUpdate
            do {
                let limits = try await value.server.rateLimits(deadline: .now + .seconds(8))
                update = CodexQuotaUpdate(target: value.target, limits: limits, problem: nil)
            } catch {
                update = CodexQuotaUpdate(target: value.target, limits: nil, problem: error.localizedDescription)
            }
            guard !Task.isCancelled, let self else { return }
            await self.publishQuota(update, id: id, server: value.server)
        }
    }

    private func publishQuota(_ update: CodexQuotaUpdate, id: UUID, server: CodexAppServer) {
        guard quotaRefreshID == id, resident?.server === server else { return }
        quotaRefreshTask = nil
        for observer in quotaObservers.values { observer.yield(update) }
    }

    private func acquire(_ job: CodexLocalJob) async throws {
        try job.check()
        guard !shuttingDown else { throw CancellationError() }
        if active == nil {
            idleTask?.cancel()
            idleTask = nil
            active = job
        } else {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(job: job, continuation: continuation))
            }
        }
        if job.isCancelled {
            release(job)
            throw CancellationError()
        }
    }

    private func release(_ job: CodexLocalJob) {
        guard active === job else { return }
        clearFlight(for: job)
        active = nil
        let shutdown = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in shutdown { waiter.resume() }
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            if next.job.isCancelled || shuttingDown {
                next.continuation.resume(throwing: CancellationError())
            } else {
                active = next.job
                next.continuation.resume()
                return
            }
        }
        guard resident != nil, !shuttingDown else { return }
        let generation = UUID()
        idleGeneration = generation
        idleTask = Task { [weak self, idleTimeout] in
            do { try await Task.sleep(for: idleTimeout) } catch { return }
            await self?.expireIdle(generation)
        }
    }

    private func expireIdle(_ generation: UUID) async {
        guard active == nil, generation == idleGeneration, let resident else { return }
        await discard(resident)
    }

    private func connection(
        for target: CodexLocalTarget, job: CodexLocalJob, deadline: ContinuousClock.Instant,
        metadataOnly: Bool = false
    ) async throws -> Resident {
        try CodexLocalSelfCheck.requireUnchanged(target)
        if let retirement, !(await retirement.value) { throw CodexLocalError.terminationUnconfirmed }
        guard !retirementFailed else { throw CodexLocalError.terminationUnconfirmed }
        if let resident {
            let reusable = metadataOnly ? resident.target.hasSameExecutable(as: target)
                : !resident.metadataOnly && resident.target == target
            if reusable, await resident.server.running() {
                try job.check()
                return resident
            }
            await discard(resident)
            guard !retirementFailed else { throw CodexLocalError.terminationUnconfirmed }
        }
        try job.check()

        let root = try Self.makeDirectory(
            inside: FileManager.default.temporaryDirectory.resolvingSymlinksInPath(), prefix: "quicknote-codex"
        )
        var live: CodexAppServer?
        do {
            let protected = try Self.makeDirectory(inside: root, prefix: "protected")
            let workspaces = try Self.makeDirectory(inside: root, prefix: "workspaces")
            let discovery = try Self.makeDirectory(inside: root, prefix: "discovery")
            let state = try Self.makeDirectory(inside: root, prefix: "state")
            let bootDeadline = min(deadline, ContinuousClock.now + .seconds(15))
            let probe = try await CodexAppServer.start(
                target: target, directory: discovery, protectedDirectory: protected,
                workspacesDirectory: workspaces, discovery: true, registry: [:],
                factory: processFactory, deadline: bootDeadline
            )
            let found: [String: CodexMCPRegistration]
            do {
                found = try await probe.configuration(cwd: discovery, requiringDisabled: false, deadline: bootDeadline)
            } catch {
                guard await probe.close() else { throw CodexLocalError.terminationUnconfirmed }
                throw error
            }
            guard await probe.close() else { throw CodexLocalError.terminationUnconfirmed }
            try? FileManager.default.removeItem(at: discovery)
            try job.check()
            let server = try await CodexAppServer.start(
                target: target, directory: state, protectedDirectory: protected,
                workspacesDirectory: workspaces, discovery: false, registry: found,
                factory: processFactory, deadline: bootDeadline, metadataOnly: metadataOnly
            )
            live = server
            let effective = try await server.configuration(cwd: state, requiringDisabled: true, deadline: bootDeadline)
            guard effective.mapValues(\.transport) == found.mapValues(\.transport) else {
                throw CodexLocalError.incompatible("MCP 配置在进程启动期间变化")
            }
            try job.check()
            let resident = Resident(
                target: target, root: root, protected: protected, workspaces: workspaces,
                state: state, server: server, registry: effective, metadataOnly: metadataOnly
            )
            self.resident = resident
            return resident
        } catch {
            if case CodexLocalError.terminationUnconfirmed = error {
                retirementFailed = true
                throw error
            }
            if let live, !(await live.close()) {
                retirementFailed = true
                throw CodexLocalError.terminationUnconfirmed
            }
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func withPrepared<T>(
        _ resident: Resident, model: String?, job: CodexLocalJob, deadline: ContinuousClock.Instant,
        operation: (Prepared) async throws -> T
    ) async throws -> T {
        try job.check()
        let directory = try Self.makeDirectory(inside: resident.workspaces, prefix: "request")
        defer { try? FileManager.default.removeItem(at: directory) }
        let context: CodexAppServer.ThreadContext
        do {
            // App-server resolves the effective config again when opening a thread.
            // Verify it before opening one and check the runtime catalog before dispatch.
            let effective = try await resident.server.configuration(
                cwd: directory, requiringDisabled: true, deadline: deadline
            )
            guard effective == resident.registry else {
                throw CodexLocalError.incompatible("MCP 配置已变化，需要重新启动")
            }
            try job.check()
            context = try await resident.server.thread(in: directory, model: model, deadline: deadline)
            guard model == nil || context.model == model else {
                throw CodexLocalError.incompatible("实际模型与选定模型不一致")
            }
        } catch {
            if !(error is CancellationError) { await discard(resident) }
            throw error
        }
        let result: Result<T, Error>
        do {
            result = .success(try await operation(Prepared(context: context, directory: directory)))
        } catch {
            result = .failure(error)
        }

        if await resident.server.running() {
            do {
                try await resident.server.unsubscribe(
                    thread: context.id, deadline: .now + .seconds(2)
                )
            } catch {
                await discard(resident)
                if case .success = result { throw error }
            }
        }
        return try result.get()
    }

    private func ensureVerified(
        target: CodexLocalTarget, model: String, resident: Resident, job: CodexLocalJob,
        deadline: ContinuousClock.Instant, force: Bool = false
    ) async throws {
        let checked = target.checking(model: model)
        if force { CodexLocalSelfCheck.invalidate(checked) }
        if CodexLocalSelfCheck.isVerified(checked) { return }
        if let failure = CodexLocalSelfCheck.failure(checked) {
            throw CodexLocalError.unverified(failure)
        }
        do {
            let checkedThread = try await withPrepared(
                resident, model: model, job: job, deadline: deadline
            ) { prepared in
                let challenge = try CodexLocalSelfCheck.makeChallenge(
                    protectedDirectory: resident.protected, workDirectory: prepared.directory
                )
                defer { challenge.close() }
                let answer = try await run(
                    .init(prompt: challenge.prompt), prepared: prepared, resident: resident,
                    job: job, deadline: deadline, preflight: {}
                ) { _ in }
                try challenge.validate(answer: answer)
                return prepared.context.id
            }
            try Self.assertNoLocalRollout(thread: checkedThread)
            try job.check()
            try CodexLocalSelfCheck.requireUnchanged(checked)
            CodexLocalSelfCheck.recordVerified(checked)
        } catch {
            if !job.isCancelled, !(error is CancellationError) {
                CodexLocalSelfCheck.recordFailure(checked, error: error)
                await discard(resident)
            }
            throw error
        }
    }

    private func run(
        _ request: CodexLocalRequest, prepared: Prepared, resident: Resident,
        job: CodexLocalJob, deadline: ContinuousClock.Instant,
        preflight: @escaping @Sendable () async throws -> Void, onDelta: (String) -> Void
    ) async throws -> String {
        let server = resident.server
        let thread = prepared.context.id
        let directory = prepared.directory
        let image = request.image.map { _ in resident.state.appendingPathComponent(UUID().uuidString + ".png") }
        if let image, let data = request.image { try data.write(to: image, options: .atomic) }
        defer { if let image { try? FileManager.default.removeItem(at: image) } }

        do {
            let effective = try await server.configuration(cwd: directory, requiringDisabled: true, deadline: deadline)
            guard effective == resident.registry else {
                throw CodexLocalError.incompatible("MCP 配置已变化，需要重新启动")
            }
            try await server.checkMCP(thread: thread, registry: Set(effective.keys), deadline: deadline)
        } catch {
            await discard(resident)
            throw error
        }
        try job.check()
        try await preflight()
        try job.check()
        try CodexLocalSelfCheck.requireUnchanged(resident.target)

        let events = try await server.observe(thread: thread, deadline: deadline)
        do { try job.check() } catch {
            await server.endObservation(thread: thread)
            throw error
        }
        flight = Flight(server: server, thread: thread)
        let result: Result<String, Error>
        do {
            let turn = try await server.turn(
                thread: thread, directory: directory, request: request, image: image,
                effort: resident.target.effort, deadline: deadline
            ) {
                guard !job.isCancelled else { throw CodexLocalError.interrupted }
                do { try CodexLocalSelfCheck.requireUnchanged(resident.target) }
                catch { throw CodexLocalError.incompatible("发送前检测到可执行文件变化") }
            }
            flight?.turn = turn
            sendInterruptIfReady(job)
            let answer = try await read(events, job: job, turn: turn, onDelta: onDelta)
            result = .success(answer)
        } catch {
            result = .failure(error)
            if case CodexLocalError.timedOut = error {
                // The deadline has already closed the observer. Ask the server
                // to interrupt, then retire it because completion is unobservable.
                let turn = flight?.turn
                clearFlight(for: job)
                if let turn {
                    try? await server.interrupt(
                        thread: thread, turn: turn, deadline: .now + interruptTimeout
                    )
                }
                await discard(resident)
            } else if !job.isCancelled {
                await discard(resident)
            }
        }
        clearFlight(for: job)
        await server.endObservation(thread: thread)
        return try result.get()
    }

    private func read(
        _ events: AsyncThrowingStream<CodexJSON, Error>, job: CodexLocalJob,
        turn: String, onDelta: (String) -> Void
    ) async throws -> String {
        var byItem: [String: String] = [:]
        var answer = ""
        var latestFinal: String?
        for try await event in events {
            let method = event["method"]?.text
            let params = event["params"]
            if method == "turn/completed", params?["turn"]?["id"]?.text == turn {
                try job.check()
                guard params?["turn"]?["status"] == "completed" else {
                    throw CodexLocalError.requestFailed
                }
                let text = latestFinal ?? answer
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CodexLocalError.requestFailed
                }
                return text
            }
            if job.isCancelled || params?["turnId"]?.text != turn { continue }
            if method == "item/agentMessage/delta", let itemID = params?["itemId"]?.text,
               let delta = params?["delta"]?.text, !delta.isEmpty {
                byItem[itemID, default: ""] += delta
                answer += delta
                onDelta(delta)
            } else if method == "item/completed", let item = params?["item"],
                      item["type"] == "agentMessage", let itemID = item["id"]?.text,
                      let text = item["text"]?.text {
                let existing = byItem[itemID, default: ""]
                if text.hasPrefix(existing), text.count > existing.count {
                    let remainder = String(text.dropFirst(existing.count))
                    byItem[itemID] = text
                    answer += remainder
                    onDelta(remainder)
                }
                latestFinal = text
            }
        }
        throw CodexLocalError.unavailable
    }

    private func requestStop(_ job: CodexLocalJob) {
        if active !== job {
            if let index = waiters.firstIndex(where: { $0.job === job }) {
                let waiter = waiters.remove(at: index)
                waiter.continuation.resume(throwing: CancellationError())
            }
            return
        }
        guard flight != nil, flight?.stopTimer == nil else { return }
        let deadline = ContinuousClock.now + interruptTimeout
        let thread = flight?.thread
        flight?.stopDeadline = deadline
        flight?.stopTimer = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            await self?.forceStop(job, thread: thread)
        }
        sendInterruptIfReady(job)
    }

    private func sendInterruptIfReady(_ job: CodexLocalJob) {
        guard let current = flight, let turn = current.turn, let deadline = current.stopDeadline,
              current.interrupt == nil else { return }
        flight?.interrupt = Task { [weak self] in
            do { try await current.server.interrupt(thread: current.thread, turn: turn, deadline: deadline) }
            catch { await self?.forceStop(job, thread: current.thread) }
        }
    }

    private func forceStop(_ job: CodexLocalJob, thread: String?) async {
        guard active === job, flight?.thread == thread, let resident else { return }
        await discard(resident)
    }

    private func clearFlight(for job: CodexLocalJob) {
        guard active === job else { return }
        flight?.stopTimer?.cancel()
        flight?.interrupt?.cancel()
        flight = nil
    }

    private func discard(_ value: Resident) async {
        guard resident?.server === value.server else {
            if let retirement { _ = await retirement.value }
            return
        }
        quotaRefreshTask?.cancel()
        quotaRefreshTask = nil
        quotaRefreshID = UUID()
        resident = nil
        let closing = Task {
            guard await value.server.close() else { return false }
            try? FileManager.default.removeItem(at: value.root)
            return true
        }
        retirement = closing
        retirementFailed = !(await closing.value)
        retirement = nil
    }

    private static func makeDirectory(inside parent: URL, prefix: String) throws -> URL {
        let directory = parent.appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private static func assertNoLocalRollout(thread: String) throws {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        for name in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(name, isDirectory: true)
            var unreadable = false
            let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) { _, error in
                if (error as NSError).code != NSFileReadNoSuchFileError { unreadable = true }
                return false
            }
            if let entries {
                for case let file as URL in entries where file.lastPathComponent.contains(thread) {
                    throw CodexLocalError.incompatible("自检线程生成了本地历史")
                }
            }
            if unreadable { throw CodexLocalError.incompatible("无法确认自检线程的本地历史") }
        }
    }
}
