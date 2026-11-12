import Darwin
import Foundation

enum CodexLocalError: LocalizedError, Sendable {
    case incompatible(String)
    case unavailable
    case timedOut
    case requestFailed
    case methodUnavailable
    case loginFailed
    case loginURLInvalid
    case interrupted
    case terminationUnconfirmed
    case unverified(String)

    var errorDescription: String? {
        switch self {
        case let .incompatible(reason): "本机 Codex 隔离检查失败：\(reason)"
        case .unavailable: "无法启动或连接本机 Codex。请检查可执行路径和 ChatGPT 登录状态。"
        case .timedOut: "本机 Codex 请求超时。"
        case .requestFailed: "本机 Codex 请求失败。请检查模型、ChatGPT 登录状态和网络连接。"
        case .methodUnavailable: "当前 Codex 版本不支持此操作。"
        case .loginFailed: "ChatGPT 登录未完成，请重试。"
        case .loginURLInvalid: "Codex 未返回有效的官方 ChatGPT 登录地址。"
        case .interrupted: "已停止本机 Codex。"
        case .terminationUnconfirmed: "无法确认上一个本机 Codex 进程已退出。请重新启动 QuickNote。"
        case let .unverified(reason): "本机 Codex 自检未通过：\(reason)"
        }
    }
}

/// A sendable representation of the JSON-RPC payload. It never logs raw payloads.
enum CodexJSON: Codable, Sendable, Equatable, ExpressibleByStringLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral {
    case object([String: Self])
    case array([Self])
    case string(String)
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case null

    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .integer(value) }
    init(arrayLiteral elements: Self...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, Self)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(Int.self) { self = .integer(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode([String: Self].self) { self = .object(result) }
        else { self = try .array(value.decode([Self].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(result): try value.encode(result)
        case let .array(result): try value.encode(result)
        case let .string(result): try value.encode(result)
        case let .bool(result): try value.encode(result)
        case let .integer(result): try value.encode(result)
        case let .number(result): try value.encode(result)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> Self? { fields?[key] }
    var fields: [String: Self]? { if case let .object(value) = self { value } else { nil } }
    var elements: [Self]? { if case let .array(value) = self { value } else { nil } }
    var text: String? { if case let .string(value) = self { value } else { nil } }
    var int: Int? { if case let .integer(value) = self { value } else { nil } }
    var double: Double? {
        switch self {
        case let .number(value): value
        case let .integer(value): Double(value)
        default: nil
        }
    }
}

private extension Optional where Wrapped == CodexJSON {
    var absent: Bool { self == nil || self == .null }
}

struct CodexAccount: Sendable, Equatable {
    let email: String?
    let planType: String?

    static func parse(_ response: CodexJSON) -> Self? {
        guard let account = response["account"], account["type"] == "chatgpt" else { return nil }
        return .init(email: nonempty(account["email"]?.text), planType: nonempty(account["planType"]?.text))
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}

struct CodexRateLimitWindow: Sendable, Equatable {
    let usedPercent: Double
    let resetsAt: Date?
}

struct CodexRateLimits: Sendable, Equatable {
    let fiveHour: CodexRateLimitWindow?
    let weekly: CodexRateLimitWindow?

    static func parse(_ response: CodexJSON) -> Self {
        let legacy = response["rateLimits"]
        let legacyID = legacy?["limitId"]
        let compatibleLegacy = legacyID.absent || legacyID == "codex" ? legacy : nil
        let codexBucket = response["rateLimitsByLimitId"]?["codex"]
        let bucket = codexBucket?.fields == nil ? compatibleLegacy : codexBucket
        let windows = [bucket?["primary"], bucket?["secondary"]]
        func window(minutes: Int) -> CodexRateLimitWindow? {
            for item in windows {
                guard let item, item["windowDurationMins"]?.int == minutes,
                      let percent = item["usedPercent"]?.double, percent.isFinite, percent >= 0 else { continue }
                let reset = item["resetsAt"]?.double.flatMap {
                    $0.isFinite && $0 >= 0 ? Date(timeIntervalSince1970: $0) : nil
                }
                return .init(usedPercent: percent, resetsAt: reset)
            }
            return nil
        }
        return .init(fiveHour: window(minutes: 300), weekly: window(minutes: 10_080))
    }
}

struct CodexManagedLogin: Sendable, Equatable {
    let id: String
    let url: URL
}

struct CodexMCPRegistration: Sendable, Equatable {
    enum Transport: Sendable {
        case stdio
        case http
    }
    let transport: Transport
    let disabled: Bool
}

typealias CodexLocalProcessFactory =
    @Sendable (CodexLocalTarget, [String], URL, Bool, URL, URL) throws -> Process

final class CodexProcessExit: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]

    var hasExited: Bool { lock.withLock { exited } }

    func signal() {
        let observers = lock.withLock {
            exited = true
            let observers = Array(waiters.values)
            waiters.removeAll()
            return observers
        }
        for observer in observers {
            observer.yield(())
            observer.finish()
        }
    }

    func killIfRunning(_ pid: Int32) {
        lock.withLock {
            if !exited { _ = Darwin.kill(pid, SIGKILL) }
        }
    }

    func waitForExit() async -> Bool {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let alreadyExited = lock.withLock {
            if exited { return true }
            waiters[id] = continuation
            return false
        }
        if alreadyExited { return true }
        defer { _ = lock.withLock { waiters.removeValue(forKey: id) } }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let finished = await group.next() ?? false
            group.cancelAll()
            return finished || self.hasExited
        }
    }
}

actor CodexAppServer {
    typealias Deadline = ContinuousClock.Instant
    struct ThreadContext: Sendable {
        let id: String
        let model: String
    }

    private struct Pending {
        let continuation: CheckedContinuation<CodexJSON, Error>
        let timeout: Task<Void, Never>
    }

    private struct Events {
        let thread: String
        let continuation: AsyncThrowingStream<CodexJSON, Error>.Continuation
        let timeout: Task<Void, Never>
    }

    private struct LoginWaiter {
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }

    private struct LoginState {
        var id: String?
        var earlyCompletions: [String: Bool] = [:]
        var completed: Bool?
        var waiter: LoginWaiter?
    }

    private static let disabledFeatures = [
        "shell_tool", "apps", "plugins", "hooks", "shell_snapshot", "code_mode",
        "multi_agent", "multi_agent_v2", "browser_use", "browser_use_external", "in_app_browser",
        "computer_use", "view_image", "memories", "standalone_web_search", "remote_plugin",
        "skill_mcp_dependency_install", "skill_search", "goals", "daemon_auto_start",
        "stable_environment_tools", "tool_suggest", "request_permissions_tool", "deferred_executor",
        "sleep_tool", "realtime_conversation"
    ]
    private static let approvedItemTypes: Set<String> = ["userMessage", "agentMessage", "reasoning"]
    private static let maximumFrame = 8 * 1024 * 1024

    // Keep Process alive until its termination handler reaps the subprocess.
    private let process: Process
    private let pid: Int32
    private let exit: CodexProcessExit
    private let input: FileHandle
    private let output: FileHandle
    private let writer = DispatchQueue(label: "com.xixi.quicknote.codex.stdin")
    private var reader: Task<Void, Never>?
    private var outputSource: DispatchSourceRead?
    private var pending: [Int: Pending] = [:]
    private var events: Events?
    private var login: LoginState?
    private var buffer = Data()
    private var nextID = 0
    private var terminalError: CodexLocalError?

    private init(process: Process, exit: CodexProcessExit, input: FileHandle, output: FileHandle) {
        self.process = process
        self.pid = process.processIdentifier
        self.exit = exit
        self.input = input
        self.output = output
    }

    static func start(
        target: CodexLocalTarget, directory: URL, protectedDirectory: URL,
        workspacesDirectory: URL, discovery: Bool, registry: [String: CodexMCPRegistration],
        factory: CodexLocalProcessFactory, deadline: Deadline, metadataOnly: Bool = false
    ) async throws -> CodexAppServer {
        try CodexLocalSelfCheck.requireUnchanged(target)
        let arguments = try arguments(
            target: target, directory: directory, discovery: discovery, registry: registry,
            metadataOnly: metadataOnly
        )
        let process = try factory(target, arguments, directory, discovery, protectedDirectory, workspacesDirectory)
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let exit = CodexProcessExit()
        process.terminationHandler = { _ in exit.signal() }
        let outputDescriptor = stdout.fileHandleForReading.fileDescriptor
        let outputFlags = fcntl(outputDescriptor, F_GETFL)
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1,
              outputFlags != -1, fcntl(outputDescriptor, F_SETFL, outputFlags | O_NONBLOCK) != -1
        else { throw CodexLocalError.unavailable }
        do {
            try process.run()
        } catch {
            throw CodexLocalError.unavailable
        }
        let server = CodexAppServer(
            process: process, exit: exit, input: stdin.fileHandleForWriting,
            output: stdout.fileHandleForReading
        )
        await server.startReading()
        do {
            _ = try await server.call("initialize", params: [
                "clientInfo": ["name": "quicknote", "version": "1"],
                "capabilities": ["experimentalApi": true, "explicitGatewayOauth": true]
            ], deadline: deadline)
            try await server.write(["method": "initialized"])
            return server
        } catch {
            guard await server.close() else { throw CodexLocalError.terminationUnconfirmed }
            throw error
        }
    }

    private static func arguments(
        target: CodexLocalTarget, directory: URL,
        discovery: Bool, registry: [String: CodexMCPRegistration], metadataOnly: Bool
    ) throws -> [String] {
        let settings = [
            "approval_policy=\"never\"", "web_search=\"disabled\"", "model_provider=\"openai\"",
            "forced_login_method=\"chatgpt\"", "history.persistence=\"none\"", "notify=[]",
            "project_doc_max_bytes=0", "analytics.enabled=false", "feedback.enabled=false",
            "check_for_update_on_startup=false", "allow_login_shell=false", "agents.enabled=false",
            "chatgpt_base_url=\"https://chatgpt.com/backend-api/\"",
            "tools.update_plan.enabled=false", "tools.experimental_request_user_input.enabled=false",
            "developer_instructions=\"\"", "sandbox_mode=\"read-only\"", "thread_unload_delay_secs=1",
            "log_dir=\(try quoted(directory.path))"
        ]
        var args = ["app-server", "--listen", "stdio://"]
        for setting in settings { args += ["-c", setting] }
        for feature in disabledFeatures { args += ["--disable", feature] }
        args += ["--disable", "unified_exec", "--enable", "skip_host_skill_discovery"]
        if !discovery {
            if !metadataOnly {
                if let model = target.model { args += ["-c", "model=\(try quoted(model))"] }
                args += ["-c", "model_reasoning_effort=\(try quoted(target.effort))"]
            }
            if !registry.isEmpty {
                // An inline table preserves arbitrary dotted registration names as single keys.
                let overrides = try registry.keys.sorted().map { "\(try quoted($0))={enabled=false}" }
                args += ["-c", "mcp_servers={\(overrides.joined(separator: ","))}"]
            }
        }
        return args
    }

    private static func quoted(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    func configuration(
        cwd: URL, requiringDisabled: Bool, deadline: Deadline
    ) async throws -> [String: CodexMCPRegistration] {
        let reply = try await call("config/read", params: [
            "cwd": .string(cwd.path), "includeLayers": false
        ], deadline: deadline)
        guard let config = reply["config"], let registry = config["mcp_servers"]?.fields else {
            throw CodexLocalError.incompatible("无法识别 MCP 注册")
        }
        let features = config["features"]
        guard Self.disabledFeatures.allSatisfy({ features?[$0] == false }),
              features?["skip_host_skill_discovery"] == true,
              config["approval_policy"] == "never", config["web_search"] == "disabled",
              config["model_provider"] == "openai", config["forced_login_method"] == "chatgpt",
              config["sandbox_mode"] == "read-only", config["project_doc_max_bytes"] == 0,
              config["allow_login_shell"] == false, config["agents"]?["enabled"] == false,
              config["history"]?["persistence"] == "none",
              config["notify"].absent || config["notify"] == [],
              config["chatgpt_base_url"].absent ||
                config["chatgpt_base_url"] == "https://chatgpt.com/backend-api/" ||
                config["chatgpt_base_url"] == "https://chatgpt.com/backend-api",
              config["developer_instructions"].absent || config["developer_instructions"] == ""
        else { throw CodexLocalError.incompatible("有效配置与受限启动要求不一致") }

        return try registry.mapValues { registration in
            let transport: CodexMCPRegistration.Transport
            switch (registration["command"]?.text, registration["url"]?.text) {
            case (.some, nil): transport = .stdio
            case (nil, .some): transport = .http
            default: throw CodexLocalError.incompatible("MCP 传输类型无法识别")
            }
            let disabled = registration["enabled"] == false
            guard !requiringDisabled || disabled else {
                throw CodexLocalError.incompatible("仍有 MCP 服务处于启用状态")
            }
            return CodexMCPRegistration(transport: transport, disabled: disabled)
        }
    }

    func thread(in directory: URL, model: String?, deadline: Deadline) async throws -> ThreadContext {
        var params: [String: CodexJSON] = [
            "cwd": .string(directory.path), "approvalPolicy": "never", "sandbox": "read-only",
            "environments": [], "runtimeWorkspaceRoots": [], "selectedCapabilityRoots": [],
            "dynamicTools": [], "ephemeral": true, "allowProviderModelFallback": false
        ]
        if let model { params["model"] = .string(model) }
        let result = try await call("thread/start", params: .object(params), deadline: deadline)
        guard let thread = result["thread"], let id = thread["id"]?.text, !id.isEmpty,
              let actualModel = result["model"]?.text, !actualModel.isEmpty,
              thread["ephemeral"] == true, thread["path"].absent, thread["environments"] == [],
              result["approvalPolicy"] == "never", result["modelProvider"] == "openai",
              result["instructionSources"].absent || result["instructionSources"] == [],
              result["sandbox"]?["type"] == "readOnly",
              (result["sandbox"]?["networkAccess"]).absent || result["sandbox"]?["networkAccess"] == false,
              result["cwd"] == .string(directory.path)
        else { throw CodexLocalError.incompatible("线程未确认临时历史、无环境或只读设置") }
        return ThreadContext(id: id, model: actualModel)
    }

    func checkMCP(thread: String, registry: Set<String>, deadline: Deadline) async throws {
        var cursor: String?
        var previousCursors = Set<String>()
        var seen = Set<String>()
        repeat {
            var params: [String: CodexJSON] = ["threadId": .string(thread), "detail": "toolsAndAuthOnly"]
            if let cursor { params["cursor"] = .string(cursor) }
            let response = try await call("mcpServerStatus/list", params: .object(params), deadline: deadline)
            guard let rows = response["data"]?.elements else {
                throw CodexLocalError.incompatible("MCP 状态页无法识别")
            }
            for row in rows {
                guard let name = row["name"]?.text, registry.contains(name), seen.insert(name).inserted,
                      row["runtimeStatus"] == "disabled", row["tools"] == [:],
                      row["serverCapabilities"].absent,
                      row["resources"].absent || row["resources"] == [],
                      row["resourceTemplates"].absent || row["resourceTemplates"] == []
                else { throw CodexLocalError.incompatible("MCP 服务未完全禁用或仍提供工具") }
            }
            cursor = try Self.pageCursor(response, seen: &previousCursors)
        } while cursor != nil
        guard seen == registry else { throw CodexLocalError.incompatible("MCP 状态未覆盖全部注册") }
    }

    func models(deadline: Deadline) async throws -> [CodexLocalModel] {
        var cursor: String?
        var previousCursors = Set<String>()
        var seenModels = Set<String>()
        var models: [CodexLocalModel] = []
        repeat {
            var params: [String: CodexJSON] = ["includeHidden": false, "limit": 100]
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await call("model/list", params: .object(params), deadline: deadline)
            for model in try Self.parseModels(result) where seenModels.insert(model.id).inserted {
                models.append(model)
            }
            cursor = try Self.pageCursor(result, seen: &previousCursors)
        } while cursor != nil
        return models
    }

    static func parseModels(_ response: CodexJSON) throws -> [CodexLocalModel] {
        guard let rows = response["data"]?.elements else { throw CodexLocalError.requestFailed }
        return rows.compactMap { row in
            let model = row["model"]?.text
            guard row["hidden"] != true,
                  let id = model.flatMap({ $0.isEmpty ? nil : $0 }) ?? row["id"]?.text,
                  !id.isEmpty else { return nil }
            var seenEfforts = Set<String>()
            let efforts = row["supportedReasoningEfforts"]?.elements?.compactMap { item -> String? in
                guard let value = item["reasoningEffort"]?.text, !value.isEmpty,
                      seenEfforts.insert(value).inserted else { return nil }
                return value
            } ?? []
            let title = row["displayName"]?.text ?? ""
            let defaultEffort = row["defaultReasoningEffort"]?.text
            return .init(id: id, title: title.isEmpty ? id : title, efforts: efforts,
                         isDefault: row["isDefault"] == true,
                         defaultEffort: defaultEffort.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    func account(deadline: Deadline) async throws -> CodexAccount? {
        let response = try await call("account/read", params: ["refreshToken": false], deadline: deadline)
        guard response["account"] != nil || response["requiresOpenaiAuth"] == true ||
                response["requiresOpenaiAuth"] == false else { throw CodexLocalError.requestFailed }
        return CodexAccount.parse(response)
    }

    func rateLimits(deadline: Deadline) async throws -> CodexRateLimits {
        let response = try await call("account/rateLimits/read", params: .null, deadline: deadline)
        return CodexRateLimits.parse(response)
    }

    static func isOfficialLoginURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443 else {
            return false
        }
        return host == "auth.openai.com" || host == "chatgpt.com"
    }

    func startLogin(deadline: Deadline) async throws -> CodexManagedLogin {
        try Task.checkCancellation()
        guard login == nil else { throw CodexLocalError.requestFailed }
        // A fast completion can arrive before the start RPC response.
        login = LoginState()
        do {
            let response = try await call("account/login/start", params: ["type": "chatgpt"], deadline: deadline)
            guard response["type"] == "chatgpt", let id = response["loginId"]?.text, !id.isEmpty else {
                throw CodexLocalError.loginFailed
            }
            let completed = login?.earlyCompletions[id]
            login?.id = id
            login?.completed = completed
            login?.earlyCompletions.removeAll()
            guard let address = response["authUrl"]?.text, let url = URL(string: address),
                  Self.isOfficialLoginURL(url) else {
                try? await cancelLogin(id: id, deadline: .now + .seconds(2))
                throw CodexLocalError.loginURLInvalid
            }
            if Task.isCancelled {
                try? await cancelLogin(id: id, deadline: .now + .seconds(2))
                throw CancellationError()
            }
            return .init(id: id, url: url)
        } catch {
            endLogin(.failure(error), clear: true)
            throw error
        }
    }

    func waitForLogin(id: String, deadline: Deadline) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard deadline > .now else { throw CodexLocalError.timedOut }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard login?.id == id, login?.waiter == nil, terminalError == nil else {
                    continuation.resume(throwing: terminalError ?? .loginFailed)
                    return
                }
                if let completed = login?.completed {
                    login = nil
                    if completed { continuation.resume() }
                    else { continuation.resume(throwing: CodexLocalError.loginFailed) }
                    return
                }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    await self?.interruptLoginWait(id: id, error: CodexLocalError.timedOut)
                }
                login?.waiter = .init(continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            Task { await self.interruptLoginWait(id: id, error: CancellationError()) }
        }
    }

    func cancelLogin(id: String, deadline: Deadline) async throws {
        guard login?.id == id else { return }
        defer { endLogin(.failure(CancellationError()), clear: true) }
        let response = try await call("account/login/cancel", params: ["loginId": .string(id)], deadline: deadline)
        guard response["status"] == "canceled" || response["status"] == "notFound" else {
            throw CodexLocalError.requestFailed
        }
    }

    func logout(deadline: Deadline) async throws {
        guard login == nil else { throw CodexLocalError.requestFailed }
        _ = try await call("account/logout", params: .null, deadline: deadline)
    }

    private func receiveLoginCompletion(_ params: CodexJSON?) {
        guard let id = params?["loginId"]?.text, !id.isEmpty,
              case .bool(let success)? = params?["success"], login != nil else { return }
        guard let expected = login?.id else {
            // Do not grow state with unrelated or duplicate notifications.
            if let early = login?.earlyCompletions, early.count < 8, early[id] == nil {
                login?.earlyCompletions[id] = success
            }
            return
        }
        guard expected == id, login?.completed == nil else { return }
        login?.completed = success
        if login?.waiter != nil {
            endLogin(success ? .success(()) : .failure(CodexLocalError.loginFailed), clear: true)
        }
    }

    private func interruptLoginWait(id: String, error: Error) {
        guard login?.id == id else { return }
        // Retain the ID so the caller can send account/login/cancel after interruption.
        endLogin(.failure(error), clear: false)
    }

    private func endLogin(_ result: Result<Void, Error>, clear: Bool) {
        let waiter = login?.waiter
        if clear { login = nil }
        else { login?.waiter = nil }
        waiter?.timeout.cancel()
        waiter?.continuation.resume(with: result)
    }

    private static func pageCursor(_ response: CodexJSON, seen: inout Set<String>) throws -> String? {
        if response["nextCursor"].absent { return nil }
        guard let cursor = response["nextCursor"]?.text, !cursor.isEmpty,
              seen.count < 64, seen.insert(cursor).inserted
        else { throw CodexLocalError.incompatible("分页结果不完整") }
        return cursor
    }

    func observe(thread: String, deadline: Deadline) throws -> AsyncThrowingStream<CodexJSON, Error> {
        guard events == nil, terminalError == nil else {
            throw terminalError ?? CodexLocalError.incompatible("重复订阅回合")
        }
        let (stream, continuation) = AsyncThrowingStream<CodexJSON, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(1_024)
        )
        let timeout = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            await self?.endObservation(thread: thread, error: .timedOut)
        }
        events = Events(thread: thread, continuation: continuation, timeout: timeout)
        return stream
    }

    func endObservation(thread: String, error: CodexLocalError? = nil) {
        guard let current = events, current.thread == thread else { return }
        events = nil
        current.timeout.cancel()
        current.continuation.finish(throwing: error)
    }

    func turn(
        thread: String, directory: URL, request: CodexLocalRequest, image: URL?,
        effort: String, deadline: Deadline,
        beforeWrite: @escaping @Sendable () throws -> Void
    ) async throws -> String {
        var content: [CodexJSON] = [["type": "text", "text": .string(request.prompt), "text_elements": []]]
        if let image { content.append(["type": "localImage", "path": .string(image.path)]) }
        var params: [String: CodexJSON] = [
            "threadId": .string(thread), "cwd": .string(directory.path),
            "input": .array(content), "approvalPolicy": "never", "environments": [],
            "runtimeWorkspaceRoots": [], "effort": .string(effort),
            "sandboxPolicy": ["type": "readOnly", "networkAccess": false]
        ]
        if let schema = request.outputSchema {
            let decoded = try JSONDecoder().decode(CodexJSON.self, from: schema)
            guard decoded.fields != nil else { throw CodexLocalError.requestFailed }
            params["outputSchema"] = decoded
        }
        let result = try await call(
            "turn/start", params: .object(params), deadline: deadline, beforeWrite: beforeWrite
        )
        guard let turnID = result["turn"]?["id"]?.text, !turnID.isEmpty else {
            throw CodexLocalError.incompatible("回合标识无效")
        }
        return turnID
    }

    func interrupt(thread: String, turn: String, deadline: Deadline) async throws {
        _ = try await call("turn/interrupt", params: [
            "threadId": .string(thread), "turnId": .string(turn)
        ], deadline: deadline)
    }

    func unsubscribe(thread: String, deadline: Deadline) async throws {
        let result = try await call("thread/unsubscribe", params: ["threadId": .string(thread)], deadline: deadline)
        guard ["unsubscribed", "notSubscribed", "notLoaded"].contains(result["status"]?.text ?? "") else {
            throw CodexLocalError.incompatible("临时线程未解除订阅")
        }
    }

    func running() -> Bool { terminalError == nil && !exit.hasExited }

    @discardableResult
    func close() async -> Bool {
        fail(.unavailable)
        return await exit.waitForExit()
    }

    private func startReading() {
        let (bytes, feed) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let descriptor = output.fileDescriptor
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor, queue: DispatchQueue(label: "com.xixi.quicknote.codex.stdout")
        )
        source.setEventHandler {
            var chunk = Data(count: 64 * 1024)
            let count = chunk.withUnsafeMutableBytes { storage in
                Darwin.read(descriptor, storage.baseAddress, storage.count)
            }
            if count == 0 {
                feed.finish()
            } else if count < 0 {
                guard errno != EINTR && errno != EAGAIN else { return }
                feed.finish(throwing: CodexLocalError.unavailable)
            } else {
                chunk.count = count
                if case .dropped = feed.yield(chunk) {
                    feed.finish(throwing: CodexLocalError.incompatible("协议输出超过缓冲限制"))
                }
            }
        }
        source.setCancelHandler { [output] in
            try? output.close()
            feed.finish()
        }
        outputSource = source
        source.activate()
        reader = Task { [weak self] in
            do {
                for try await chunk in bytes { await self?.receive(chunk) }
                await self?.fail(.unavailable)
            } catch let error as CodexLocalError {
                await self?.fail(error)
            } catch {
                await self?.fail(.unavailable)
            }
        }
    }

    private func call(
        _ method: String, params: CodexJSON, deadline: Deadline,
        beforeWrite: (@Sendable () throws -> Void)? = nil
    ) async throws -> CodexJSON {
        if let terminalError { throw terminalError }
        guard deadline > .now else { throw CodexLocalError.timedOut }
        nextID += 1
        let id = nextID
        let data = try Self.frame(["id": .integer(id), "method": .string(method), "params": params])
        return try await withCheckedThrowingContinuation { continuation in
            let timeout = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                await self?.finish(id, result: .failure(.timedOut))
            }
            pending[id] = Pending(continuation: continuation, timeout: timeout)
            enqueue(data, id: id, beforeWrite: beforeWrite, deadline: deadline)
        }
    }

    private static func frame(_ payload: CodexJSON) throws -> Data {
        var data = try JSONEncoder().encode(payload)
        guard data.count < maximumFrame else { throw CodexLocalError.requestFailed }
        data.append(10)
        return data
    }

    private func write(_ payload: CodexJSON) throws {
        if let terminalError { throw terminalError }
        enqueue(try Self.frame(payload))
    }

    private func enqueue(
        _ data: Data, id: Int? = nil, beforeWrite: (@Sendable () throws -> Void)? = nil,
        deadline: Deadline? = nil
    ) {
        writer.async { [input, weak self] in
            do {
                if let deadline, deadline <= .now { throw CodexLocalError.timedOut }
                try beforeWrite?()
            } catch {
                if let id {
                    let safeError = error as? CodexLocalError ?? .requestFailed
                    Task { await self?.finish(id, result: .failure(safeError)) }
                }
                return
            }
            do { try input.write(contentsOf: data) }
            catch { Task { await self?.fail(.unavailable) } }
        }
    }

    private func receive(_ data: Data) {
        guard terminalError == nil else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            guard newline - buffer.startIndex < Self.maximumFrame else {
                fail(.incompatible("协议行超过限制"))
                return
            }
            let frame = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let message = try? JSONDecoder().decode(CodexJSON.self, from: frame),
                  message.fields != nil
            else {
                fail(.incompatible("无效的 JSON-RPC 响应"))
                return
            }
            receive(message)
            guard terminalError == nil else { return }
        }
        if buffer.count >= Self.maximumFrame { fail(.incompatible("协议行超过限制")) }
    }

    private func receive(_ message: CodexJSON) {
        if let method = message["method"]?.text {
            guard message["id"].absent else {
                fail(.incompatible("收到未授权的服务器请求"))
                return
            }
            let prohibited = ["command/", "mcpServer/", "item/mcpToolCall/", "item/fileChange/",
                              "item/commandExecution/", "hook/", "thread/realtime/"]
            guard !prohibited.contains(where: { method.hasPrefix($0) }),
                  !["turn/diff/updated", "turn/plan/updated", "model/rerouted"].contains(method)
            else {
                fail(.incompatible("检测到未授权的工具或模型变更事件"))
                return
            }
            let params = message["params"]
            if method == "account/login/completed" {
                receiveLoginCompletion(params)
                return
            }
            if method == "item/started" || method == "item/completed" {
                guard let type = params?["item"]?["type"]?.text, Self.approvedItemTypes.contains(type) else {
                    fail(.incompatible("检测到未授权的工具条目"))
                    return
                }
            }
            if let events, params?["threadId"]?.text == events.thread {
                if case .dropped = events.continuation.yield(message) {
                    fail(.incompatible("回合事件超过缓冲限制"))
                }
            }
            return
        }
        guard let id = message["id"]?.int else {
            fail(.incompatible("无效的 JSON-RPC 消息类型"))
            return
        }
        if let result = message["result"], result.fields != nil {
            finish(id, result: .success(result))
        } else {
            // The CLI can include user paths and configuration values in errors.
            let error: CodexLocalError = message["error"]?["code"]?.int == -32601
                ? .methodUnavailable : .requestFailed
            finish(id, result: .failure(error))
        }
    }

    private func finish(_ id: Int, result: Result<CodexJSON, CodexLocalError>) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.timeout.cancel()
        switch result {
        case let .success(value): item.continuation.resume(returning: value)
        case let .failure(error): item.continuation.resume(throwing: error)
        }
    }

    private func fail(_ error: CodexLocalError) {
        guard terminalError == nil else { return }
        terminalError = error
        exit.killIfRunning(pid)
        reader?.cancel()
        reader = nil
        outputSource?.cancel()
        outputSource = nil
        writer.async { [input] in try? input.close() }
        for id in Array(pending.keys) { finish(id, result: .failure(error)) }
        if let thread = events?.thread { endObservation(thread: thread, error: error) }
        endLogin(.failure(error), clear: true)
    }
}
