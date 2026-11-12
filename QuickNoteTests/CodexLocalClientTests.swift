import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import QuickNote

@MainActor
final class CodexLocalClientTests: XCTestCase {
    func testFakeChatGPTLoginAndLogoutRoundTrip() async throws {
        try await withFixture { fixture in
            let client = fixture.client()
            let initial = try await client.account(for: fixture.target)
            XCTAssertNil(initial)
            var openedURL: URL?
            try await client.login(target: fixture.target) { url in
                openedURL = url
                return true
            }
            XCTAssertEqual(openedURL?.host, "auth.openai.com")
            XCTAssertEqual(openedURL?.path, "/oauth/authorize")
            let account = try await client.account(for: fixture.target)
            XCTAssertEqual(account, CodexAccount(email: "demo@example.test", planType: "plus"))
            try await client.logout(target: fixture.target)
            let final = try await client.account(for: fixture.target)
            XCTAssertNil(final)
            XCTAssertFalse(CodexLocalSelfCheck.isVerified(fixture.target))
            await client.shutdown()
            let methods = try fixture.trace().map(\.method)
            XCTAssertEqual(methods.filter { $0 == "account/login/start" }.count, 1)
            XCTAssertEqual(methods.filter { $0 == "account/logout" }.count, 1)
            XCTAssertFalse(methods.contains("turn/start"))
        }
    }

    func testFakeRejectedBrowserCancelsLogin() async throws {
        try await withFixture { fixture in
            let client = fixture.client(behavior: "pendingLogin")
            do {
                try await client.login(target: fixture.target) { _ in false }
                XCTFail("Failed browser launch must cancel login")
            } catch CodexLocalError.requestFailed {}
            await client.shutdown()
            XCTAssertTrue(try fixture.trace().contains { $0.method == "account/login/cancel" })
        }
    }

    func testFakeSettingsReadPagesAndQuotaRefreshesAfterCompletion() async throws {
        try await withFixture { fixture in
            let client = fixture.client()
            let models = try await client.models(for: fixture.target)
            XCTAssertEqual(models.map(\.id), ["synthetic-model", "secondary-model"])
            XCTAssertEqual(models.filter(\.isDefault).map(\.id), ["synthetic-model"])
            XCTAssertEqual(models.first?.title, "Synthetic Default")
            let limits = try await client.rateLimits(for: fixture.target)
            XCTAssertEqual(limits.fiveHour?.usedPercent, 23)
            XCTAssertEqual(limits.weekly?.usedPercent, 64)
            XCTAssertEqual(limits.weekly?.resetsAt, Date(timeIntervalSince1970: 1_900_000_000))
            let events = await client.quotaUpdates()
            let observer = expectation(description: "quota after completed request")
            let observation = Task {
                for await update in events {
                    XCTAssertEqual(update.limits, limits)
                    XCTAssertNil(update.problem)
                    observer.fulfill()
                    return
                }
            }
            defer { observation.cancel() }
            let answer = try await collect(client, fixture.target, request: .init(prompt: "quota refresh"))
            XCTAssertEqual(answer.joined(), "合成回复")
            await fulfillment(of: [observer], timeout: 5)
            await client.shutdown()
            XCTAssertEqual(try fixture.trace().filter { $0.method == "account/rateLimits/read" }.count, 2)
        }
    }

    func testLiveReadOnlyAccountMetadata() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["QUICKNOTE_TEST_REAL_CODEX_ACCOUNT"] == "1")
        let target = try await CodexLocalSelfCheck.target(
            executablePath: environment["QUICKNOTE_TEST_CODEX_PATH"] ?? "", model: nil, effort: "low"
        )
        let client = CodexLocalClient()
        do {
            let account = try await client.account(for: target)
            let models = try await client.models(for: target)
            let limits = try await client.rateLimits(for: target)
            XCTAssertTrue(account != nil, "Expected a signed-in ChatGPT account")
            XCTAssertFalse(models.isEmpty)
            XCTAssertEqual(models.filter(\.isDefault).count, 1)
            print("Codex metadata: \(models.count) models; 5h window: \(limits.fiveHour != nil); weekly window: \(limits.weekly != nil)")
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    func testFakeStreamsOnOneProcessWithFreshWorkspacesAndDynamicMCP() async throws {
        try await withFixture { fixture in
            let client = fixture.client()
            let first = try await collect(client, fixture.target, request: .init(prompt: "first"))
            let schema = Data(#"{"type":"object"}"#.utf8)
            let second = try await collect(client, fixture.target, request: .init(prompt: "second", image: Data([1]), outputSchema: schema))
            await client.shutdown()

            XCTAssertEqual(first, ["合成", "回复"])
            XCTAssertEqual(second, ["合成", "回复"])
            let starts = try fixture.trace().filter { $0.method == "thread/start" }
            XCTAssertEqual(starts.count, 2)
            XCTAssertEqual(Set(starts.map(\.pid)).count, 1)
            XCTAssertEqual(Set(starts.compactMap(\.cwd)).count, 2)
            XCTAssertTrue(starts.allSatisfy { $0.cwd.map { !FileManager.default.fileExists(atPath: $0) } ?? false })
            let methods = try fixture.trace().map(\.method)
            XCTAssertEqual(methods.filter { $0 == "mcpServerStatus/list" }.count, 2)
        }
    }

    func testFakeMCPRegistrationWithToolsPreventsSending() async throws {
        try await withFixture { fixture in
            let client = fixture.client(behavior: "unsafe")
            do {
                _ = try await collect(client, fixture.target, request: .init(prompt: "blocked"))
                XCTFail("Expected the MCP safety gate to reject the turn")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("MCP"))
            }
            await client.shutdown()
            XCTAssertFalse(try fixture.trace().contains { $0.method == "turn/start" })
        }
    }

    func testNewVersionOrModelMustPassSyntheticCheckBeforeRealInput() async throws {
        try await withFixture { fixture in
            let updated = CodexLocalTarget(executable: fixture.target.executable, sha256: fixture.target.sha256,
                                           version: "0.162.2", model: "new-model", effort: "low")
            let rejected = fixture.client(behavior: "badCheck")
            do {
                _ = try await collect(rejected, updated, request: .init(prompt: "real-input"))
                XCTFail("A failed self-check must block the user turn")
            } catch {
                XCTAssertNotNil(CodexLocalSelfCheck.failure(updated))
            }
            await rejected.shutdown()
            XCTAssertFalse(try fixture.trace().contains { $0.method == "real-input" })

            let verified = fixture.client()
            try await verified.selfCheck(target: updated, force: true)
            let pieces = try await collect(verified, updated, request: .init(prompt: "real-input"))
            await verified.shutdown()
            XCTAssertEqual(pieces.joined(), "合成回复")
            XCTAssertTrue(CodexLocalSelfCheck.isVerified(updated))
            let trace = try fixture.trace().map(\.method)
            XCTAssertEqual(trace.filter { $0 == "synthetic-check" }.count, 2)
            XCTAssertEqual(trace.filter { $0 == "real-input" }.count, 1)
        }
    }

    func testFakeInterruptKeepsResidentAndSuppressesLateOutput() async throws {
        try await checkInterruption(behavior: "normal", expectsReuse: true)
    }

    func testFakeInterruptTimeoutRestartsResident() async throws {
        try await checkInterruption(behavior: "ignoreInterrupt", expectsReuse: false)
    }

    func testFakeNonzeroExitFailsWithoutReply() async throws {
        try await withFixture { fixture in
            let client = fixture.client(behavior: "exit")
            do {
                _ = try await collect(client, fixture.target, request: .init(prompt: "exit"))
                XCTFail("Expected failure on nonzero process exit")
            } catch {
                XCTAssertFalse(error is CancellationError)
            }
            await client.shutdown()
        }
    }

    func testFakeIdleProcessIsReapedAndNextRequestRestarts() async throws {
        try await withFixture { fixture in
            let client = fixture.client(idleTimeout: .milliseconds(100))
            _ = try await collect(client, fixture.target, request: .init(prompt: "first"))
            try await Task.sleep(for: .milliseconds(400))
            _ = try await collect(client, fixture.target, request: .init(prompt: "next"))
            await client.shutdown()
            let starts = try fixture.trace().filter { $0.method == "thread/start" }
            XCTAssertEqual(starts.count, 2)
            XCTAssertEqual(Set(starts.map(\.pid)).count, 2)
        }
    }

    func testFakeRequestTimeoutReportsFailure() async throws {
        try await withFixture { fixture in
            let client = fixture.client(textTimeout: .seconds(2))
            do {
                _ = try await collect(client, fixture.target, request: .init(prompt: "hold"))
                XCTFail("Expected the text request to time out")
            } catch {
                guard case CodexLocalError.timedOut = error else {
                    return XCTFail("Expected timeout, got \(error)")
                }
            }
            await client.shutdown()
            XCTAssertTrue(try fixture.trace().contains { $0.method == "turn/interrupt" })
        }
    }

    func testStatusMustBeAnActiveChatGPTLogin() {
        XCTAssertTrue(CodexLocalSelfCheck.isChatGPTLogin(output: "Logged in using ChatGPT\n", exitCode: 0))
        XCTAssertFalse(CodexLocalSelfCheck.isChatGPTLogin(output: "Not logged in\n", exitCode: 1))
        XCTAssertFalse(CodexLocalSelfCheck.isChatGPTLogin(output: "Logged in using API key\n", exitCode: 0))
        XCTAssertFalse(CodexLocalSelfCheck.isChatGPTLogin(output: "Logged in using ChatGPT", exitCode: 1))
    }

    func testUnsignedNativeBinaryUsesSHA256Identity() async throws {
        try await withFixture { fixture in
            let binary = try fixture.makeIdentity(unsigned: true)
            let hash = SHA256.hash(data: try Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined()
            let target = CodexLocalTarget(executable: binary, sha256: hash, version: "0.162.1")
            try CodexLocalSelfCheck.requireUnchanged(target)
            let mismatch = CodexLocalTarget(executable: binary, sha256: "previous-hash", version: "0.162.1")
            XCTAssertThrowsError(try CodexLocalSelfCheck.requireUnchanged(mismatch))
        }
    }

    func testMissingExecutableReportedBeforeLaunch() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        let inspection = await CodexLocalSelfCheck.inspect(executablePath: missing, model: nil, effort: "low")
        XCTAssertNil(inspection.target)
        XCTAssertEqual(inspection.problem, CodexLocalEnvironmentError.executableMissing.localizedDescription)
    }

    func testLiveSelectionUsesChatGPTOnlyWhenExplicitlyEnabled() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QUICKNOTE_TEST_REAL_CODEX"] == "1")
        let key = "quicknote.codexLocal.selfCheck.v1"
        let previous = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let path = ProcessInfo.processInfo.environment["QUICKNOTE_TEST_CODEX_PATH"] ?? ""
        let target = try await CodexLocalSelfCheck.target(executablePath: path, model: nil, effort: "low")
        let client = CodexLocalClient()
        do {
            try await client.selfCheck(target: target, force: true)
            let pieces = try await collect(
                client, target, request: .init(prompt: "请只输出这四个汉字：合成测试")
            )
            XCTAssertEqual(pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines), "合成测试")
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    func testAppleLocalImageSelectionFailsWithAnExplicitReason() async throws {
        do {
            for try await _ in FeatureAI.imageStream(imageData: Data([1]), prompt: "", route: .system) {}
            XCTFail("Apple local source cannot analyze images")
        } catch AIAnalyzerError.imageUnsupported {
            // The selected source must fail without contacting another service.
        }
    }

    func testLiveSegmentTwoUsesOnlySyntheticInputs() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["QUICKNOTE_TEST_REAL_CODEX_SEGMENT2"] == "1")
        let key = "quicknote.codexLocal.selfCheck.v1"
        let previous = UserDefaults.standard.data(forKey: key)
        let client = CodexLocalClient.shared
        let preferences = CodexLocalPreferences(executablePath: environment["QUICKNOTE_TEST_CODEX_PATH"] ?? "",
                                                model: "gpt-6.1-sol", effort: "low")
        let route = AIFeatureRoute.codex(preferences)
        defer { UserDefaults.standard.set(previous, forKey: key) }

        do {
            let image = NSImage(size: NSSize(width: 240, height: 120), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 26, y: 22, width: 76, height: 76)).fill()
                NSColor.systemBlue.setFill()
                NSRect(x: 138, y: 22, width: 76, height: 76).fill()
                return true
            }
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let vision = try await finishedText(FeatureAI.imageStream(
                imageData: png, prompt: "请用中文从左到右说出两个图形的颜色与形状。", route: route
            ))
            XCTAssertTrue(["红", "圆", "蓝", "方"].allSatisfy(vision.text.contains))

            let editor = RichTextEditorController()
            let document = NSAttributedString(string: "社区菜园春季计划\n一、浇水安排\n每周二和周五浇水，雨天暂停。")
            let source = try editor.aiFormattingSource(document: document)
            let formatting = try await FeatureAI.textRespond(
                instruction: AIFormattingPlan.instruction, text: source.material, route: route,
                outputSchema: AIFormattingPlan.outputSchema
            )
            let plan = try AIFormattingPlan.parse(formatting.text)
            XCTAssertEqual(Set(plan.assignments.map(\.index)), Set(0..<3))
            XCTAssertEqual(try editor.formattedDocument(plan, source: source).string, document.string)

            let polish = try await FeatureAI.textRespond(
                instruction: DesktopPetVoiceController.polishingInstruction,
                text: "嗯，我们明天上午九点，嗯，去社区菜园集合。", route: route, forDictation: true
            )
            XCTAssertTrue(polish.text.contains("菜园"))
            XCTAssertTrue(polish.text.contains("九点") || polish.text.contains("9点"))
            XCTAssertFalse(polish.text.contains("嗯"))

            let evidence = NoteAskEvidence(
                number: 1, chunk: NoteIndexChunk(noteID: UUID(), title: "合成便签",
                    text: "社区菜园下次开放日期是十一月二十日。", range: NSRange(location: 0, length: 19), revision: 1),
                location: "合成位置"
            )
            let answer = try await finishedText(FeatureAI.noteAskStream(
                request: NoteAskRequest(question: "社区菜园下次什么时候开放？", evidence: [evidence]), route: route
            ))
            let cited = AskCitationParser.parse(answer.text, validNumbers: [1], streaming: false)
            XCTAssertEqual(cited.references, [1])
            XCTAssertTrue(cited.text.contains("二十") || cited.text.contains("20"))
            XCTAssertEqual(answer.providerName, CodexLocalPreferences.destinationName)
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }

    private func finishedText(_ stream: AsyncThrowingStream<AIStreamEvent, Error>) async throws -> AIStreamCompletion {
        var completion: AIStreamCompletion?
        for try await event in stream {
            if case .completed(let result) = event { completion = result }
        }
        return try XCTUnwrap(completion)
    }

    private func checkInterruption(behavior: String, expectsReuse: Bool) async throws {
        try await withFixture { fixture in
            let client = fixture.client(behavior: behavior)
            let task = Task {
                try await collect(client, fixture.target, request: .init(prompt: "hold"))
            }
            try await fixture.waitFor("hold-ready")
            task.cancel()
            _ = await task.result
            try await fixture.waitFor("turn/interrupt")
            if expectsReuse {
                try await fixture.waitFor("thread/unsubscribe")
            } else {
                try await Task.sleep(for: .milliseconds(350))
            }
            let pieces = try await collect(client, fixture.target, request: .init(prompt: "next"))
            await client.shutdown()
            XCTAssertEqual(pieces, ["合成", "回复"])
            let starts = try fixture.trace().filter { $0.method == "thread/start" }
            XCTAssertEqual(starts.count, 2)
            XCTAssertEqual(Set(starts.map(\.pid)).count, expectsReuse ? 1 : 2)
        }
    }

    private func collect(
        _ client: CodexLocalClient, _ target: CodexLocalTarget, request: CodexLocalRequest
    ) async throws -> [String] {
        let stream = await client.stream(request, target: target)
        var pieces: [String] = []
        for try await chunk in stream { pieces.append(chunk) }
        return pieces
    }

    private func withFixture(_ run: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        // The app host and its test host may share a preference domain.
        let key = "quicknote.codexLocal.selfCheck.v1"
        let previous = UserDefaults.standard.data(forKey: key)
        CodexLocalSelfCheck.recordVerified(fixture.target)
        defer {
            UserDefaults.standard.set(previous, forKey: key)
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        try await run(fixture)
    }

    private struct Trace: Decodable {
        let method: String
        let pid: Int
        let cwd: String?
    }

    private struct Fixture {
        let directory: URL
        let script: URL
        let tracePath: URL
        let target: CodexLocalTarget

        init() throws {
            directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("codex-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            script = directory.appendingPathComponent("fake-codex.py")
            tracePath = directory.appendingPathComponent("trace.jsonl")
            try Data(Self.scriptContents.utf8).write(to: script)
            let binary = try Self.makeIdentity(in: directory, unsigned: false)
            let hash = SHA256.hash(data: try Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined()
            target = .init(executable: binary, sha256: hash, version: "0.162.1",
                           model: "synthetic-model", effort: "low")
        }

        func makeIdentity(unsigned: Bool) throws -> URL {
            try Self.makeIdentity(in: directory, unsigned: unsigned)
        }

        private static func makeIdentity(in directory: URL, unsigned: Bool) throws -> URL {
            let binary = directory.appendingPathComponent("fake-codex-identity-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
            let signing = Process()
            signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signing.arguments = unsigned ? ["--remove-signature", binary.path]
                : ["--force", "--sign", "-", "--identifier", "quicknote.codex.fixture", binary.path]
            signing.standardOutput = FileHandle.nullDevice
            signing.standardError = FileHandle.nullDevice
            try signing.run()
            signing.waitUntilExit()
            guard signing.terminationStatus == 0 else { throw CodexLocalEnvironmentError.signatureInvalid }
            return binary
        }

        func client(
            behavior: String = "normal", idleTimeout: Duration = .seconds(600),
            textTimeout: Duration = .seconds(90)
        ) -> CodexLocalClient {
            let script = script.path
            let trace = tracePath.path
            return CodexLocalClient(
                processFactory: { _, arguments, directory, offline, _, _ in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.currentDirectoryURL = directory
                    let flags = try JSONEncoder().encode(arguments)
                    process.arguments = ["-B", script, offline ? "discover" : "resident", behavior,
                                         trace, String(decoding: flags, as: UTF8.self)]
                    return process
                },
                idleTimeout: idleTimeout, interruptTimeout: .milliseconds(100), textTimeout: textTimeout
            )
        }

        func trace() throws -> [Trace] {
            guard FileManager.default.fileExists(atPath: tracePath.path) else { return [] }
            let lines = try String(contentsOf: tracePath, encoding: .utf8).split(separator: "\n")
            return lines.compactMap { try? JSONDecoder().decode(Trace.self, from: Data($0.utf8)) }
        }

        func waitFor(_ method: String) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if try trace().contains(where: { $0.method == method }) { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CodexLocalEnvironmentError.selfCheckFailed
        }

        private static let scriptContents = #"""
import json
import os
import sys
import uuid

mode, behavior, trace, encoded = sys.argv[1:]
flags = json.loads(encoded)
name = "synthetic.server-42"
disabled = mode == "resident"
held = {}
signed_in = trace + ".signed-in"

def observe(method, cwd=None):
    with open(trace, "a") as out:
        out.write(json.dumps({"method": method, "pid": os.getpid(), "cwd": cwd}) + "\n")

def send(message):
    print(json.dumps(message, ensure_ascii=False), flush=True)

def event(method, **params):
    send({"method": method, "params": params})

for line in sys.stdin:
    message = json.loads(line)
    method = message["method"]
    params = message.get("params") or {}
    ident = message.get("id")
    observe(method, params.get("cwd"))

    def reply(result):
        send({"id": ident, "result": result})

    if mode == "discover" and method not in ("initialize", "initialized", "config/read"):
        sys.exit(42)
    if method == "initialize":
        reply({})
    elif method == "initialized":
        continue
    elif method == "config/read":
        features = {flags[i+1]: False for i, flag in enumerate(flags) if flag == "--disable"}
        features["skip_host_skill_discovery"] = True
        if disabled:
            assert any(x.startswith("mcp_servers={") and name in x and "enabled=false" in x for x in flags)
        reply({"config": {"features": features, "approval_policy": "never", "web_search": "disabled",
                          "model_provider": "openai", "forced_login_method": "chatgpt",
                          "history": {"persistence": "none"}, "sandbox_mode": "read-only",
                          "allow_login_shell": False, "agents": {"enabled": False},
                          "project_doc_max_bytes": 0,
                          "mcp_servers": {name: {"enabled": not disabled, "command": "unused"}}}})
    elif method == "account/read":
        assert params == {"refreshToken": False}
        account = {"type": "chatgpt", "email": "demo@example.test", "planType": "plus"} if os.path.exists(signed_in) else None
        reply({"account": account, "requiresOpenaiAuth": True})
    elif method == "account/login/start":
        assert params == {"type": "chatgpt"}
        if behavior != "pendingLogin":
            event("account/login/completed", loginId="other", success=False, error="unrelated")
            with open(signed_in, "w") as state:
                state.write("synthetic")
            event("account/login/completed", loginId="login-fixture", success=True, error=None)
        reply({"type": "chatgpt", "loginId": "login-fixture",
               "authUrl": "https://auth.openai.com/oauth/authorize?state=synthetic"})
    elif method == "account/login/cancel":
        assert params == {"loginId": "login-fixture"}
        reply({"status": "canceled"})
    elif method == "account/logout":
        assert message.get("params") is None
        os.remove(signed_in)
        reply({})
    elif method == "account/rateLimits/read":
        assert message.get("params") is None
        reply({"rateLimitsByLimitId": {"codex": {
            "primary": {"usedPercent": 64, "windowDurationMins": 10080, "resetsAt": 1900000000},
            "secondary": {"usedPercent": 23, "windowDurationMins": 300, "resetsAt": 1899500000}}}})
    elif method == "model/list":
        assert not any(x.startswith(("model=", "model_reasoning_effort=")) for x in flags)
        second_page = params.get("cursor") == "next"
        reply({"data": [{"id": "secondary-model" if second_page else "synthetic-model",
                         "displayName": "Synthetic Alternate" if second_page else "Synthetic Default",
                         "defaultReasoningEffort": "low", "isDefault": not second_page,
                         "supportedReasoningEfforts": [{"reasoningEffort": "low"}]}],
               "nextCursor": None if second_page else "next"})
    elif method == "thread/start":
        assert params["ephemeral"] and not params["environments"] and not params["dynamicTools"]
        assert os.listdir(params["cwd"]) == []
        reply({"thread": {"id": str(uuid.uuid4()), "ephemeral": True, "path": None, "environments": []},
               "model": params.get("model", "synthetic-model"), "approvalPolicy": "never", "modelProvider": "openai",
               "sandbox": {"type": "readOnly", "networkAccess": False}, "cwd": params["cwd"]})
    elif method == "mcpServerStatus/list":
        unsafe = behavior == "unsafe"
        reply({"data": [{"name": name, "runtimeStatus": "connected" if unsafe else "disabled",
                         "tools": {"unsafe": {}} if unsafe else {}, "serverCapabilities": None}]})
    elif method == "turn/start":
        assert params["environments"] == [] and params["approvalPolicy"] == "never"
        assert params["sandboxPolicy"] == {"type": "readOnly", "networkAccess": False}
        thread, turn, item = params["threadId"], str(uuid.uuid4()), "agent-item"
        text = params["input"][0]["text"]
        selfcheck = "synthetic-canary" in text
        if selfcheck:
            observe("synthetic-check")
        elif text == "real-input":
            observe("real-input")
        if behavior == "exit":
            sys.exit(73)
        if text == "second":
            assert params["input"][1]["type"] == "localImage"
            assert open(params["input"][1]["path"], "rb").read() == bytes([1])
            assert params["outputSchema"] == {"type": "object"}
        reply({"turn": {"id": turn, "status": "inProgress", "items": []}})
        event("turn/started", threadId=thread, turn={"id": turn, "status": "inProgress"})
        event("item/started", threadId=thread, turnId=turn,
              item={"id": item, "type": "agentMessage", "text": "", "phase": "final_answer"})
        if selfcheck:
            answer = "错误内容" if behavior == "badCheck" else "松风路社区菜园"
            event("item/agentMessage/delta", threadId=thread, turnId=turn, itemId=item, delta=answer)
            event("item/completed", threadId=thread, turnId=turn,
                  item={"id": item, "type": "agentMessage", "text": answer, "phase": "final_answer"})
            event("turn/completed", threadId=thread, turn={"id": turn, "status": "completed"})
            continue
        event("item/agentMessage/delta", threadId=thread, turnId=turn, itemId=item, delta="合成")
        if text == "hold":
            held[thread] = (turn, item)
            observe("hold-ready")
            continue
        event("item/agentMessage/delta", threadId=thread, turnId=turn, itemId=item, delta="回复")
        event("item/completed", threadId=thread, turnId=turn,
              item={"id": item, "type": "agentMessage", "text": "合成回复", "phase": "final_answer"})
        event("turn/completed", threadId=thread, turn={"id": turn, "status": "completed"})
    elif method == "turn/interrupt":
        if behavior == "ignoreInterrupt":
            continue
        thread = params["threadId"]
        turn, item = held.pop(thread)
        assert turn == params["turnId"]
        reply({})
        event("item/agentMessage/delta", threadId=thread, turnId=turn, itemId=item, delta="迟到")
        event("turn/completed", threadId=thread, turn={"id": turn, "status": "interrupted"})
    elif method == "thread/unsubscribe":
        reply({"status": "unsubscribed"})
    else:
        sys.exit(43)
"""#
    }
}
