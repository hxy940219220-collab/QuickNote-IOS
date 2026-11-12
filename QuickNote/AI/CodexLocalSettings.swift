import AppKit
import SwiftUI

struct CodexLocalPreferences: Equatable, Sendable {
    static let destinationName = "Codex（ChatGPT 账号）"

    var executablePath = ""
    var model = ""
    var effort = "low"

    var modelOverride: String? { model.isEmpty ? nil : model }
}

enum AIFeature: String, CaseIterable, Identifiable, Sendable {
    case selection, screenshot, formatting, voiceOrganization, noteQuestion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selection: "划词"
        case .screenshot: "识图"
        case .formatting: "AI 排版"
        case .voiceOrganization: "语音整理"
        case .noteQuestion: "问我的便签"
        }
    }

    var modality: AIInputModality { self == .screenshot ? .image : .text }
}

enum AIFeatureSource: Hashable, Sendable {
    case automatic, codex, system, routedAPI, api(AIProfileSlot)

    init?(savedValue: String) {
        switch savedValue {
        case "automatic": self = .automatic
        case "codex": self = .codex
        case "system": self = .system
        case "api": self = .routedAPI
        default:
            guard savedValue.hasPrefix("api."),
                  let rawSlot = Int(savedValue.dropFirst(4)),
                  let slot = AIProfileSlot(rawValue: rawSlot) else { return nil }
            self = .api(slot)
        }
    }

    var savedValue: String {
        switch self {
        case .automatic: "automatic"
        case .codex: "codex"
        case .system: "system"
        case .routedAPI: "api"
        case .api(let slot): "api.\(slot.rawValue)"
        }
    }
}

enum AIDefaultSource: Hashable {
    case codex, api
}

enum AIAPITextSource: Hashable {
    case api, apple
}

enum AIDefaultSourceDecision {
    enum APIConfiguration: Equatable {
        case empty, configured, unreadable
    }

    static func resolve(saved: AIFeatureSource, apiConfiguration: APIConfiguration) -> AIFeatureSource {
        guard saved == .automatic else { return saved }
        return apiConfiguration == .empty ? .codex : .routedAPI
    }

    static func persistInitialChoice(
        saved: AIFeatureSource, apiConfiguration: APIConfiguration, codexVerified: Bool
    ) -> AIFeatureSource? {
        guard saved == .automatic else { return nil }
        switch apiConfiguration {
        case .configured: return .routedAPI
        case .empty: return codexVerified ? .codex : nil
        case .unreadable: return nil
        }
    }
}

enum AIFeatureRoute: Sendable {
    case codex(CodexLocalPreferences), api([AIRoutedConfiguration]), system

    var isCodex: Bool {
        if case .codex = self { return true }
        return false
    }
}

enum CodexEffortScale {
    private static let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    static func options(_ advertised: [String]) -> [String] {
        var seen = Set<String>()
        let unique = advertised.filter { !$0.isEmpty && seen.insert($0).inserted }
        let known = order.filter { unique.contains($0) }
        return known + unique.filter { !order.contains($0) }
    }

    static func nearest(_ current: String, advertised: [String], defaultEffort: String?) -> String? {
        let choices = options(advertised)
        if choices.contains(current) { return current }
        let preferred = defaultEffort.flatMap { choices.contains($0) ? $0 : nil }
        guard let currentIndex = order.firstIndex(of: current) else { return preferred ?? choices.first }
        let ranked = choices.compactMap { effort in
            order.firstIndex(of: effort).map { (effort, abs($0 - currentIndex)) }
        }
        guard let distance = ranked.map(\.1).min() else { return preferred ?? choices.first }
        let closest = ranked.filter { $0.1 == distance }.map(\.0)
        return preferred.flatMap { closest.contains($0) ? $0 : nil } ?? closest.first
    }

    static func title(_ effort: String) -> String {
        switch effort {
        case "none": "无"
        case "minimal": "极低"
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        case "xhigh": "极高"
        case "max": "最高"
        case "ultra": "极限"
        default: effort
        }
    }
}

@MainActor
final class CodexSettingsPresentation: ObservableObject {
    struct Fixture {
        let inspection: CodexLocalInspection
        var account: CodexAccount? = nil
        var models: [CodexLocalModel] = []
        var rateLimits: CodexRateLimits? = nil
    }

    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    private enum Action {
        case login, logout, verify
    }

    @Published private(set) var preferences: CodexLocalPreferences
    @Published private(set) var inspection: CodexLocalInspection?
    @Published private(set) var account: CodexAccount?
    @Published private(set) var models: [CodexLocalModel] = []
    @Published private(set) var rateLimits: CodexRateLimits?
    @Published private(set) var modelsState: LoadState = .idle
    @Published private(set) var rateLimitsState: LoadState = .idle
    @Published private(set) var accountProblem: String?
    @Published private(set) var feedback: String?
    @Published private(set) var failed = false
    @Published private(set) var defaultSourceRevision = 0
    @Published private var action: Action?

    private let store: AIConfigurationStore
    private let isFixture: Bool
    private var inspectionTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    private var modelsTask: Task<Void, Never>?
    private var rateLimitsTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var quotaUpdatesTask: Task<Void, Never>?
    private var generation = 0
    private var quotaGeneration = 0

    var isBusy: Bool { action != nil }
    var isLoggingIn: Bool { action == .login }

    var activeModel: CodexLocalModel? {
        preferences.model.isEmpty
            ? models.first(where: \.isDefault)
            : models.first { $0.id == preferences.model }
    }

    init(store: AIConfigurationStore, fixture: Fixture? = nil) {
        self.store = store
        preferences = store.codexPreferences
        isFixture = fixture != nil
        if let fixture {
            inspection = fixture.inspection
            account = fixture.account
            models = fixture.models
            rateLimits = fixture.rateLimits
            if fixture.inspection.loggedIn {
                modelsState = .loaded
                rateLimitsState = .loaded
            }
        }
    }

    deinit {
        inspectionTask?.cancel()
        accountTask?.cancel()
        modelsTask?.cancel()
        rateLimitsTask?.cancel()
        actionTask?.cancel()
        quotaUpdatesTask?.cancel()
    }

    func refresh(clearModels: Bool = false) {
        guard !isFixture, !isBusy else { return }
        observeQuotaUpdates()
        let previous = inspection?.accountTarget
        let nextPreferences = store.codexPreferences
        let keepMetadata = !clearModels && nextPreferences.executablePath == preferences.executablePath
        preferences = nextPreferences
        cancelReads()
        if !keepMetadata { clearMetadata() }
        feedback = nil
        failed = false
        accountProblem = nil
        inspection = nil
        modelsState = .loading
        rateLimitsState = .loading
        let revision = generation
        inspectionTask = Task { [weak self] in
            let result = await Self.inspect(nextPreferences)
            guard !Task.isCancelled, let self, generation == revision else { return }
            inspection = result
            guard let target = result.accountTarget, result.loggedIn else {
                clearMetadata()
                return
            }
            if !keepMetadata || !Self.sameInstallation(previous, target) { clearMetadata() }
            readAccount(target: target, generation: revision)
            retryModels()
            retryRateLimits()
        }
    }

    func retryModels() {
        guard !isFixture, !isBusy, let target = inspection?.accountTarget, inspection?.loggedIn == true else { return }
        modelsTask?.cancel()
        modelsState = .loading
        let revision = generation
        modelsTask = Task { [weak self] in
            do {
                let items = try await CodexLocalClient.shared.models(for: target)
                guard !Task.isCancelled, let self, generation == revision else { return }
                models = items
                modelsState = .loaded
                if let model = activeModel,
                   let effort = CodexEffortScale.nearest(preferences.effort, advertised: model.efforts,
                                                          defaultEffort: model.defaultEffort) {
                    updateModel(preferences.model, effort: effort)
                }
                refreshVerification()
            } catch {
                guard !Task.isCancelled, let self, generation == revision else { return }
                modelsState = .failed(error.localizedDescription)
            }
        }
    }

    func retryRateLimits() {
        guard !isFixture, !isBusy, let target = inspection?.accountTarget, inspection?.loggedIn == true else { return }
        rateLimitsTask?.cancel()
        rateLimitsState = .loading
        quotaGeneration += 1
        let revision = generation
        let quotaRevision = quotaGeneration
        rateLimitsTask = Task { [weak self] in
            do {
                let limits = try await CodexLocalClient.shared.rateLimits(for: target)
                guard !Task.isCancelled, let self, generation == revision, quotaGeneration == quotaRevision else { return }
                rateLimits = limits
                rateLimitsState = .loaded
            } catch {
                guard !Task.isCancelled, let self, generation == revision, quotaGeneration == quotaRevision else { return }
                rateLimits = nil
                rateLimitsState = .failed(error.localizedDescription)
            }
        }
    }

    func changePath(_ path: String) {
        guard !isFixture, !isBusy, path != preferences.executablePath else { return }
        preferences.executablePath = path
        store.codexPreferences = preferences
        refresh(clearModels: true)
    }

    func selectModel(_ id: String) {
        guard !isFixture, !isBusy, id != preferences.model else { return }
        let model = id.isEmpty ? models.first(where: \.isDefault) : models.first { $0.id == id }
        let effort = model.flatMap {
            CodexEffortScale.nearest(preferences.effort, advertised: $0.efforts, defaultEffort: $0.defaultEffort)
        } ?? preferences.effort
        updateModel(id, effort: effort)
        refreshVerification()
    }

    func selectEffort(_ effort: String) {
        guard !isFixture, !isBusy, activeModel?.efforts.contains(effort) == true else { return }
        updateModel(preferences.model, effort: effort)
        refreshVerification()
    }

    func login() {
        guard let target = inspection?.accountTarget, inspection?.loggedIn == false else { return }
        perform(.login, success: "已登录 ChatGPT。", refreshAfter: true) {
            try await CodexLocalClient.shared.login(target: target) { url in NSWorkspace.shared.open(url) }
        }
    }

    func cancelLogin() {
        guard action == .login else { return }
        actionTask?.cancel()
    }

    func logout() {
        guard let target = inspection?.accountTarget, inspection?.loggedIn == true else { return }
        perform(.logout, success: "已退出登录。", refreshAfter: true) {
            try await CodexLocalClient.shared.logout(target: target)
        }
    }

    func testConnection(force: Bool) {
        guard var target = inspection?.target else { return }
        target.model = preferences.modelOverride
        target.effort = preferences.effort
        let requestedTarget = target
        perform(.verify, success: force ? "重新自检通过。" : "连接与自检通过。", refreshAfter: false) {
            if force { try await CodexLocalClient.shared.selfCheck(target: requestedTarget, force: true) }
            else { try await CodexLocalClient.shared.testConnection(target: requestedTarget) }
        }
    }

    private func perform(_ requested: Action, success: String, refreshAfter: Bool,
                         operation: @escaping () async throws -> Void) {
        guard !isFixture, !isBusy else { return }
        if refreshAfter { cancelReads() }
        action = requested
        feedback = nil
        failed = false
        actionTask = Task { [weak self] in
            do {
                try await operation()
                guard let self else { return }
                action = nil
                if refreshAfter { refresh(clearModels: true) }
                else { refreshVerification() }
                feedback = success
            } catch {
                guard let self else { return }
                action = nil
                if refreshAfter { refresh() }
                else { refreshVerification() }
                if !(error is CancellationError) {
                    feedback = error.localizedDescription
                    failed = true
                }
            }
        }
    }

    private func readAccount(target: CodexLocalTarget, generation revision: Int) {
        accountTask = Task { [weak self] in
            do {
                let current = try await CodexLocalClient.shared.account(for: target)
                guard !Task.isCancelled, let self, generation == revision else { return }
                if current == nil {
                    cancelReads()
                    inspection?.loggedIn = false
                    inspection?.target = nil
                    inspection?.verified = false
                    clearMetadata()
                    return
                }
                account = current
                refreshVerification()
            } catch {
                guard !Task.isCancelled, let self, generation == revision else { return }
                accountProblem = error.localizedDescription
            }
        }
    }

    private func observeQuotaUpdates() {
        guard quotaUpdatesTask == nil else { return }
        quotaUpdatesTask = Task { [weak self] in
            let updates = await CodexLocalClient.shared.quotaUpdates()
            for await update in updates {
                guard let self else { return }
                guard !isLoggingIn, action != .logout, inspection?.loggedIn == true,
                      Self.sameInstallation(inspection?.accountTarget, update.target) else { continue }
                rateLimitsTask?.cancel()
                quotaGeneration += 1
                rateLimits = update.limits
                rateLimitsState = update.problem.map { .failed($0) } ?? .loaded
                refreshVerification()
            }
        }
    }

    private func updateModel(_ id: String, effort: String) {
        guard preferences.model != id || preferences.effort != effort else { return }
        var updated = preferences
        updated.model = id
        updated.effort = effort
        preferences = updated
        store.codexPreferences = updated
        inspection?.verified = false
        inspection?.problem = nil
        inspection?.target?.model = updated.modelOverride
        inspection?.target?.effort = updated.effort
    }

    private func refreshVerification() {
        guard inspection?.loggedIn == true, var target = inspection?.target else { return }
        let model = preferences.modelOverride ?? activeModel?.id
        if let model { target = target.checking(model: model) }
        target.effort = preferences.effort
        let verified = model != nil && CodexLocalSelfCheck.isVerified(target)
        inspection?.verified = verified
        inspection?.problem = CodexLocalSelfCheck.failure(target)
        if verified {
            store.considerVerifiedCodexDefault()
            defaultSourceRevision += 1
        }
    }

    private func cancelReads() {
        generation += 1
        inspectionTask?.cancel()
        accountTask?.cancel()
        modelsTask?.cancel()
        rateLimitsTask?.cancel()
    }

    private func clearMetadata() {
        account = nil
        accountProblem = nil
        models = []
        rateLimits = nil
        modelsState = .idle
        rateLimitsState = .idle
    }

    private static func sameInstallation(_ previous: CodexLocalTarget?, _ target: CodexLocalTarget) -> Bool {
        previous?.hasSameExecutable(as: target) == true
    }

    private static func inspect(_ preferences: CodexLocalPreferences) async -> CodexLocalInspection {
        await CodexLocalSelfCheck.inspect(
            executablePath: preferences.executablePath,
            model: preferences.modelOverride,
            effort: preferences.effort
        )
    }
}

enum CodexQuotaPresentation: Equatable {
    struct Row: Equatable, Identifiable {
        enum Period: String {
            case fiveHour = "5 小时"
            case weekly = "每周"
        }

        var id: Period { period }
        let period: Period
        let window: CodexRateLimitWindow
    }

    case hidden
    case loading([Row])
    case usage([Row])
    case failed(String)

    init(state: CodexSettingsPresentation.LoadState, limits: CodexRateLimits?) {
        var rows: [Row] = []
        if let window = limits?.fiveHour { rows.append(Row(period: .fiveHour, window: window)) }
        if let window = limits?.weekly { rows.append(Row(period: .weekly, window: window)) }
        switch state {
        case .idle: self = .hidden
        case .loading: self = .loading(rows)
        case .loaded: self = rows.isEmpty ? .hidden : .usage(rows)
        case .failed(let reason): self = .failed(reason)
        }
    }
}

struct CodexLocalSettingsSection: View {
    @ObservedObject var presentation: CodexSettingsPresentation
    @State private var pathDraft: String
    @State private var advancedExpanded: Bool
    @State private var installHelpPresented = false
    @State private var logoutConfirmation = false
    @State private var didCopyInstall = false

    private static let installCommand = "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
    private static let installGuide = URL(string: "https://learn.chatgpt.com/docs/codex/cli#install-codex")!
    private static let officialDownload = URL(string: "https://github.com/openai/codex/releases/latest")!

    init(store: AIConfigurationStore, presentation: CodexSettingsPresentation, initiallyAdvancedExpanded: Bool = false) {
        self.presentation = presentation
        _pathDraft = State(initialValue: store.codexPreferences.executablePath)
        _advancedExpanded = State(initialValue: initiallyAdvancedExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("ChatGPT 账号（Codex）", systemImage: "terminal")
                .font(.system(size: 14, weight: .semibold))
            accountSection
            if presentation.inspection?.loggedIn == true {
                quotaSection
                modelSection
            }
            Divider()
            DisclosureGroup("高级", isExpanded: $advancedExpanded) {
                pathSection.padding(.top, 9)
            }
            if let feedback = presentation.feedback, feedback != presentation.inspection?.problem {
                status(feedback, isError: presentation.failed)
            }
        }
        .onChange(of: presentation.preferences.executablePath) { _, path in pathDraft = path }
        .alert("退出登录", isPresented: $logoutConfirmation) {
            Button("退出登录", role: .destructive) { presentation.logout() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出后，终端和 Codex App 中的 ChatGPT 登录也会一起退出。确定退出吗？")
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        if let inspection = presentation.inspection {
            if inspection.isMissing {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Text("安装 Codex").font(.system(size: 12, weight: .medium))
                        AIHelpButton(title: "安装 Codex 说明",
                                     message: "在终端运行官方安装命令，完成后重新检测。",
                                     isPresented: $installHelpPresented)
                    }
                    Text(Self.installCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Button(didCopyInstall ? "已复制" : "复制安装命令", action: copyInstallCommand)
                        Link("官方下载", destination: Self.officialDownload)
                        Link("官方安装说明", destination: Self.installGuide)
                        Button("重新检测") { presentation.refresh(clearModels: true) }
                    }
                }
            } else if inspection.accountTarget != nil {
                HStack(spacing: 8) {
                    Text(inspection.loggedIn ? "已登录" : "未登录")
                        .font(.system(size: 12, weight: .medium))
                    if inspection.loggedIn {
                        if inspection.verified, inspection.problem == nil {
                            Circle().fill(.green).frame(width: 6, height: 6)
                                .help("安全自检已通过")
                                .accessibilityElement()
                                .accessibilityLabel("安全自检已通过")
                        } else {
                            Text(inspection.problem == nil ? "待自检" : "自检未通过")
                                .foregroundStyle(inspection.problem == nil ? Color.secondary : Color.red)
                        }
                    }
                    if let account = presentation.account {
                        if let email = account.email { Text(email).textSelection(.enabled) }
                        if let plan = account.planType { Text(planLabel(plan)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if inspection.loggedIn {
                        Button("退出登录") { logoutConfirmation = true }
                            .disabled(presentation.isBusy)
                    } else if presentation.isLoggingIn {
                        ProgressView().controlSize(.small)
                        Text("等待浏览器登录…").foregroundStyle(.secondary)
                        Button("取消登录") { presentation.cancelLogin() }
                    } else {
                        Button("登录 ChatGPT") { presentation.login() }
                            .disabled(presentation.isBusy)
                    }
                    Button("重新检测") { presentation.refresh(clearModels: true) }
                        .disabled(presentation.isBusy)
                }
                .font(.system(size: 11))
                if inspection.loggedIn, let problem = inspection.problem {
                    status(problem, isError: true)
                }
            } else {
                HStack {
                    status(inspection.problem ?? "Codex 当前不可用。", isError: true)
                    Spacer()
                    Button("重新检测") { presentation.refresh(clearModels: true) }
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检测 Codex…").font(.system(size: 11))
            }
        }
        if let problem = presentation.accountProblem {
            status("账号信息暂无法读取。\(problem)", isError: true)
        }
    }

    @ViewBuilder
    private var quotaSection: some View {
        switch CodexQuotaPresentation(state: presentation.rateLimitsState, limits: presentation.rateLimits) {
        case .hidden:
            EmptyView()
        case .loading(let rows):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    quotaTitle
                    ProgressView().controlSize(.small)
                    Text("读取中…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ForEach(rows) { quotaRow($0) }
            }
        case .usage(let rows):
            VStack(alignment: .leading, spacing: 6) {
                quotaTitle
                ForEach(rows) { quotaRow($0) }
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                quotaTitle
                HStack {
                    status("暂无法获取额度", isError: true)
                    Spacer()
                    Button("重试") { presentation.retryRateLimits() }
                }
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var quotaTitle: some View {
        Text("Codex 额度").font(.system(size: 12, weight: .medium))
    }

    private func quotaRow(_ row: CodexQuotaPresentation.Row) -> some View {
        let window = row.window
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.period.rawValue).fontWeight(.medium)
                Spacer()
                Text("已用 \(window.usedPercent.formatted(.number.precision(.fractionLength(0...2))))%")
                if let date = window.resetsAt {
                    Text("重置 \(date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("重置时间暂不可用").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            ProgressView(value: min(window.usedPercent, 100), total: 100)
                .accessibilityLabel(row.period.rawValue)
                .accessibilityValue("已用 \(window.usedPercent.formatted())%")
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("模型", selection: Binding(
                get: { presentation.preferences.model },
                set: { presentation.selectModel($0) }
            )) {
                if presentation.modelsState == .loading {
                    Text("读取中…").tag(presentation.preferences.model)
                } else {
                    Text(defaultModelTitle).tag("")
                    if !presentation.preferences.model.isEmpty && presentation.activeModel == nil {
                        Text("\(presentation.preferences.model)（不可用）").tag(presentation.preferences.model)
                    }
                    ForEach(presentation.models) { model in
                        Text(model.isDefault ? "\(model.title)（默认）" : model.title).tag(model.id)
                    }
                }
            }
            .disabled(presentation.isBusy || presentation.modelsState == .loading || presentation.models.isEmpty)
            if case let .failed(reason) = presentation.modelsState {
                failureRow(reason, retry: presentation.retryModels)
            } else if presentation.modelsState == .loaded, presentation.models.isEmpty {
                failureRow("Codex 未返回可用模型。", retry: presentation.retryModels)
            }
            effortControl
        }
    }

    @ViewBuilder
    private var effortControl: some View {
        let options = CodexEffortScale.options(presentation.activeModel?.efforts ?? [])
        if options.count > 1 {
            let position = Binding<Double>(
                get: { Double(options.firstIndex(of: presentation.preferences.effort) ?? 0) },
                set: { value in
                    let index = Int(value.rounded())
                    if options.indices.contains(index) { presentation.selectEffort(options[index]) }
                }
            )
            Slider(value: position, in: 0...Double(options.count - 1), step: 1) {
                Text("推理强度")
            } minimumValueLabel: {
                Text(CodexEffortScale.title(options[0]))
            } maximumValueLabel: {
                Text(CodexEffortScale.title(options[options.count - 1]))
            }
            .accessibilityValue(CodexEffortScale.title(presentation.preferences.effort))
            .help(CodexEffortScale.title(presentation.preferences.effort))
            .disabled(presentation.isBusy || presentation.modelsState == .loading)
            Text("当前档位 · \(CodexEffortScale.title(presentation.preferences.effort))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Text("推理强度 · \(options.first.map(CodexEffortScale.title) ?? "暂无法读取档位")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("自动查找 Codex，可输入绝对路径", text: $pathDraft)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Codex 可执行文件路径")
                    .onSubmit(applyPath)
                Button("应用路径", action: applyPath)
                    .disabled(pathDraft == presentation.preferences.executablePath)
            }
            .disabled(presentation.isBusy)
            if let executable = presentation.inspection?.executable {
                Text(executable.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let inspection = presentation.inspection, let version = inspection.version {
                let baseline = CodexLocalSelfCheck.verifiedCLIVersion
                HStack(spacing: 16) {
                    Text(version == baseline ? "版本 \(version)" : "版本 \(version)（验证基准 \(baseline)）")
                    Text("安全自检 \(checkStatus)")
                    if inspection.loggedIn {
                        Spacer()
                        Button("测试连接") { presentation.testConnection(force: false) }
                        Button("重新自检") { presentation.testConnection(force: true) }
                    }
                }
                .font(.system(size: 11))
                .disabled(presentation.isBusy)
            }
        }
    }

    private var checkStatus: String {
        guard let inspection = presentation.inspection, inspection.loggedIn else { return "—" }
        if inspection.problem != nil { return "未通过" }
        return inspection.verified ? "已通过" : "待自检"
    }

    private var defaultModelTitle: String {
        guard let model = presentation.models.first(where: \.isDefault) else { return "Codex 默认" }
        return "Codex 默认（\(model.title)）"
    }

    private func failureRow(_ reason: String, retry: @escaping () -> Void) -> some View {
        HStack {
            status(reason, isError: true)
            Spacer()
            Button("重试", action: retry)
        }
    }

    private func status(_ text: String, isError: Bool) -> some View {
        Label(text, systemImage: isError ? "exclamationmark.circle" : "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func planLabel(_ plan: String) -> String {
        switch plan.lowercased() {
        case "free": "Free"
        case "go": "Go"
        case "plus": "Plus"
        case "pro": "Pro"
        case "team": "Team"
        case "business": "Business"
        case "enterprise": "Enterprise"
        case "edu": "Edu"
        default: plan
        }
    }

    private func applyPath() {
        let path = pathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        pathDraft = path
        presentation.changePath(path)
    }

    private func copyInstallCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        didCopyInstall = pasteboard.setString(Self.installCommand, forType: .string)
    }
}

struct AIFeatureSourcesSection: View {
    let store: AIConfigurationStore
    @State private var expanded: Bool
    @State private var perFeature: [AIFeature: AIFeatureSource]

    init(store: AIConfigurationStore, initiallyExpanded: Bool = false) {
        self.store = store
        _expanded = State(initialValue: initiallyExpanded)
        _perFeature = State(initialValue: Dictionary(uniqueKeysWithValues: AIFeature.allCases.compactMap { feature in
            store.featureSource(for: feature).map { (feature, $0) }
        }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            DisclosureGroup("按功能单独设置来源", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(AIFeature.allCases) { feature in
                        Picker(feature.title, selection: featureBinding(feature)) {
                            Text("使用默认来源").tag(Optional<AIFeatureSource>.none)
                            Text("本机 Codex").tag(Optional.some(AIFeatureSource.codex))
                            Text("API 路由").tag(Optional.some(AIFeatureSource.routedAPI))
                            if feature.modality == .text || perFeature[feature] == .system {
                                Text(feature.modality == .text ? "Apple 本机模型" : "Apple 本机模型（不支持识图）")
                                    .tag(Optional.some(AIFeatureSource.system))
                                    .disabled(feature.modality == .image)
                            }
                            apiOptions(for: feature)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
        .pickerStyle(.menu)
    }

    private func featureBinding(_ feature: AIFeature) -> Binding<AIFeatureSource?> {
        Binding(get: { perFeature[feature] }, set: { source in
            perFeature[feature] = source
            store.setFeatureSource(source, for: feature)
        })
    }

    private func apiOptions(for feature: AIFeature) -> some View {
        ForEach(AIProfileSlot.allCases) { slot in
            Text("API · \(store.displayName(for: slot))")
                .tag(Optional.some(AIFeatureSource.api(slot)))
                .disabled(store.draft(for: slot).apiKey.isEmpty ||
                          !store.inputModalities(for: slot).contains(feature.modality))
        }
    }
}
