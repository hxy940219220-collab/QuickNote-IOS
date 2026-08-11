import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class SelectionActionController {
    private let session: NoteSession
    private let showSettings: () -> Void
    private let aiStore: AIConfigurationStore
    private let state = SelectionActionState()
    private var analysisTask: Task<Void, Never>?
    private lazy var panel = makePanel()

    init(
        session: NoteSession,
        showSettings: @escaping () -> Void,
        aiStore: AIConfigurationStore = .shared
    ) {
        self.session = session
        self.showSettings = showSettings
        self.aiStore = aiStore
    }

    func captureSelection() {
        analysisTask?.cancel()
        state.reset()
        do {
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
                throw SelectionCaptureError.noApplication
            }
            state.source = try SelectedTextReader.read(from: pid)
        } catch {
            state.notice = error.localizedDescription
        }
        resize(height: state.source.isEmpty ? 200 : SelectionPanelLayout.resultHeight(for: state.source))
        positionNearPointer()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func append(_ text: String, kind: SelectionImportKind, formatted: Bool = false) {
        do {
            if formatted {
                try session.appendAttributedText(SelectionResultFormatter.richText(
                    from: text,
                    asDocumentStart: session.document.string.isEmpty
                ))
            } else {
                try session.appendPlainText(text)
            }
            state.importedKind = kind
            state.notice = ""
        } catch {
            state.notice = "导入失败：\(error.localizedDescription)"
        }
    }

    private func run(_ action: AITextAction) {
        guard !state.source.isEmpty else { return }
        analysisTask?.cancel()
        state.activeAction = action
        state.isLoading = true
        state.result = ""
        state.resultProvider = ""
        state.notice = ""
        resize(height: 220)
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await AITextAnalyzer.respond(to: action, text: state.source, store: aiStore)
                guard !Task.isCancelled else { return }
                let displayedResult = action == .translate
                    ? SelectionResultFormatter.enforcingPronunciationLimit(
                        in: result.text,
                        source: state.source
                    )
                    : result.text
                state.result = displayedResult
                state.resultProvider = result.providerName
                state.needsConfiguration = false
                state.isLoading = false
                resize(height: SelectionPanelLayout.resultHeight(for: SelectionResultFormatter.plainText(from: displayedResult)))
            } catch is CancellationError {
            } catch let error as AIAnalyzerError {
                state.isLoading = false
                if case .configurationRequired = error {
                    state.needsConfiguration = true
                } else {
                    state.needsConfiguration = false
                }
                state.notice = error.localizedDescription
                resize(height: 240)
            } catch {
                state.isLoading = false
                state.needsConfiguration = false
                state.notice = error.localizedDescription
                resize(height: 240)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 185),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentMinSize = NSSize(width: 500, height: 185)
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: SelectionActionView(
                state: state,
                importSource: { [weak self] in
                    self?.append(self?.state.source ?? "", kind: .source)
                },
                perform: { [weak self] action in self?.run(action) },
                importResult: { [weak self] in
                    self?.append(
                        self?.state.result ?? "",
                        kind: .result,
                        formatted: true
                    )
                },
                settings: showSettings,
                close: { [weak panel] in panel?.orderOut(nil) }
            )
        )
        return panel
    }

    private func resize(height: CGFloat) {
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }

    private func positionNearPointer() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frame = panel.frame
        let x = min(max(pointer.x - frame.width / 2, visible.minX + 12), visible.maxX - frame.width - 12)
        let preferredY = pointer.y - frame.height - 18
        let y = min(max(preferredY, visible.minY + 12), visible.maxY - frame.height - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

enum SelectionPanelLayout {
    static let sourcePreviewMaximumHeight: CGFloat = .infinity

    static func resultHeight(for text: String) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: 470, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        return min(max(230 + ceil(bounds.height), 300), 390)
    }
}

enum SelectionSourceFormatter {
    static func normalized(_ text: String) -> String {
        // ponytail: AX returns plain text; extend this only when another surviving structural marker is observed.
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"(?<!\n)[\t ]+(?=[•◦▪][\t ])"#,
                with: "\n",
                options: .regularExpression
            )
    }
}

enum SelectionResultFormatter {
    private static let hanPattern = try? NSRegularExpression(pattern: #"\p{Han}"#)
    private static let englishWordPattern = try? NSRegularExpression(
        pattern: #"[A-Za-z]+(?:['’][A-Za-z]+)?"#
    )

    enum PronunciationKind {
        case pinyin
        case ipa

        var languageCode: String {
            switch self {
            case .pinyin: "zh-CN"
            case .ipa: "en-US"
            }
        }
    }

    static func attributedText(from text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func plainText(from text: String) -> String {
        String(attributedText(from: text).characters)
    }

    static func richText(from text: String, asDocumentStart: Bool = true) -> NSAttributedString {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = NSMutableAttributedString()
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        let lines = text.components(separatedBy: "\n")
        let firstContentIndex = lines.firstIndex {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        for (index, originalLine) in lines.enumerated() {
            let (line, baseFont, forceBold, bulletLevel, boldPrefixLength) = richTextLine(
                originalLine,
                isDocumentTitle: asDocumentStart && index == firstContentIndex
            )
            let lineStart = result.length
            let parsed = (try? AttributedString(markdown: line, options: options)) ?? AttributedString(line)
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent
                var font = intent?.contains(.code) == true ? EditorTextStyle.monospaced.font : baseFont
                var traits = font.fontDescriptor.symbolicTraits
                if forceBold || intent?.contains(.stronglyEmphasized) == true { traits.insert(.bold) }
                if intent?.contains(.emphasized) == true { traits.insert(.italic) }
                font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font

                var attributes: [NSAttributedString.Key: Any] = [.font: font]
                if bulletLevel > 0 {
                    let style = NSMutableParagraphStyle()
                    style.firstLineHeadIndent = bulletLevel == 1 ? 0 : 14
                    style.headIndent = bulletLevel == 1 ? 14 : 28
                    attributes[.paragraphStyle] = style
                }
                if intent?.contains(.strikethrough) == true {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if let link = run.link { attributes[.link] = link }
                result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
            if boldPrefixLength > 0 {
                result.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: EditorTextStyle.body.font.pointSize, weight: .bold),
                    range: NSRange(location: lineStart, length: boldPrefixLength)
                )
            }
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: EditorTextStyle.body.font]))
            }
        }
        return result
    }

    private static func richTextLine(
        _ line: String,
        isDocumentTitle: Bool
    ) -> (String, NSFont, Bool, Int, Int) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let marks = trimmed.prefix { $0 == "#" }
        let content = (1...6).contains(marks.count) && trimmed.dropFirst(marks.count).first == " "
            ? String(trimmed.dropFirst(marks.count + 1))
            : trimmed

        if isDocumentTitle {
            return (content, EditorTextStyle.title.font, true, 0, 0)
        }
        if !marks.isEmpty {
            return (content, EditorTextStyle.body.font, true, 0, 0)
        }
        if numberedSection(content) {
            return (content, EditorTextStyle.body.font, true, 0, 0)
        }

        let indentation = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) {
            $0 + ($1 == "\t" ? 4 : 1)
        }
        guard content.hasPrefix("- ") else {
            return (line, EditorTextStyle.body.font, false, 0, 0)
        }
        let item = String(content.dropFirst(2))
        if indentation == 0, let (label, length) = boldLabel(item) {
            return (label, EditorTextStyle.body.font, false, 0, length)
        }
        let level = indentation >= 4 ? 2 : 1
        return ("\(level == 1 ? "•" : "◦") \(item)", EditorTextStyle.body.font, false, level, 0)
    }

    private static func numberedSection(_ line: String) -> Bool {
        guard let dot = line.firstIndex(of: "."),
              !line[..<dot].isEmpty,
              line[..<dot].allSatisfy(\.isNumber) else { return false }
        return line.index(after: dot) < line.endIndex && line[line.index(after: dot)] == " "
    }

    private static func boldLabel(_ line: String) -> (String, Int)? {
        guard let colon = line.firstIndex(where: { $0 == "：" || $0 == ":" }),
              line.distance(from: line.startIndex, to: colon) <= 12 else { return nil }
        let end = line.index(after: colon)
        let label = String(line[..<end])
        let detail = line[end...].trimmingCharacters(in: .whitespaces)
        return (label + detail, (label as NSString).length)
    }

    static func pronunciationKind(for line: String) -> PronunciationKind? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("拼音：") || line.hasPrefix("拼音:") { return .pinyin }
        if line.hasPrefix("音标：") || line.hasPrefix("音标:") { return .ipa }
        return nil
    }

    static func pronunciationSource(in lines: [String], before index: Int) -> String? {
        guard index > 0 else { return nil }
        for line in lines[..<index].reversed() {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { continue }
            guard pronunciationKind(for: candidate) == nil else { continue }
            return plainText(from: candidate)
        }
        return nil
    }

    static func enforcingPronunciationLimit(in result: String, source: String) -> String {
        guard !pronunciationIsAllowed(for: source) else { return result }
        return result
            .components(separatedBy: .newlines)
            .filter { pronunciationKind(for: $0) == nil }
            .joined(separator: "\n")
    }

    static func pronunciationIsAllowed(for source: String) -> Bool {
        let source = source.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "",
            options: .regularExpression
        )
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let hanCount = hanPattern?.numberOfMatches(in: source, range: range) ?? 0
        if hanCount > 0 { return hanCount <= 10 }
        let wordCount = englishWordPattern?.numberOfMatches(in: source, range: range) ?? 0
        return wordCount <= 10
    }
}

private enum SelectionImportKind {
    case source
    case result
}

@MainActor
private final class SelectionActionState: ObservableObject {
    @Published var source = ""
    @Published var result = ""
    @Published var resultProvider = ""
    @Published var notice = ""
    @Published var isLoading = false
    @Published var activeAction: AITextAction?
    @Published var importedKind: SelectionImportKind?
    @Published var needsConfiguration = false

    func reset() {
        source = ""
        result = ""
        resultProvider = ""
        notice = ""
        isLoading = false
        activeAction = nil
        importedKind = nil
        needsConfiguration = false
    }
}

private struct SelectionActionView: View {
    @ObservedObject var state: SelectionActionState
    let importSource: () -> Void
    let perform: (AITextAction) -> Void
    let importResult: () -> Void
    let settings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            sourcePreview
            response
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("选中内容")
                .font(.system(size: 15, weight: .semibold))
                .fixedSize()
            Spacer(minLength: 8)
            actions
            Spacer(minLength: 8)
            importButton(imported: state.importedKind == .source, action: importSource)
                .disabled(state.source.isEmpty)
                .help("将选中文字导入便签")
            iconButton("关闭", image: "xmark", action: close)
                .padding(.leading, 8)
        }
    }

    private var sourcePreview: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Text(state.source.isEmpty ? state.notice : state.source)
                .font(.system(size: 13))
                .foregroundStyle(state.source.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
        }
        .scrollIndicators(.visible)
        .frame(
            maxWidth: .infinity,
            minHeight: 48,
            maxHeight: SelectionPanelLayout.sourcePreviewMaximumHeight,
            alignment: .topLeading
        )
        .layoutPriority(state.result.isEmpty && !state.isLoading ? 1 : 0)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var actions: some View {
        HStack(spacing: 5) {
            ForEach([AITextAction.explain, .analyze, .translate, .expand], id: \.rawValue) { action in
                Button { perform(action) } label: {
                    Label(action.title, systemImage: action.icon)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(state.source.isEmpty || state.isLoading)
    }

    @ViewBuilder
    private var response: some View {
        if state.isLoading {
            Divider()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在\(state.activeAction?.title ?? "处理")…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else if !state.result.isEmpty {
            Divider()
            HStack(spacing: 0) {
                Text(state.activeAction?.title ?? "结果")
                    .font(.system(size: 12, weight: .semibold))
                Text(state.resultProvider)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 8)
                Spacer()
                importButton(imported: state.importedKind == .result, action: importResult)
                Color.clear.frame(width: 30, height: 22)
            }
            ScrollView {
                SelectionResultContent(text: state.result)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !state.notice.isEmpty && !state.source.isEmpty {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Text(state.notice)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if state.needsConfiguration {
                    Button("配置 AI", action: settings)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    private func iconButton(_ label: String, image: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func importButton(imported: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("导入便签", systemImage: "square.and.arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
                .frame(width: 92, height: 28)
                .background(
                    Color(nsColor: imported ? .systemGreen : .controlAccentColor),
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .layoutPriority(2)
        .help(imported ? "已导入便签" : "导入便签")
        .accessibilityLabel(imported ? "已导入便签" : "导入便签")
    }
}

private struct SelectionResultContent: View {
    let text: String
    @StateObject private var speech = SpeechPlaybackController()

    private var lines: [String] { text.components(separatedBy: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                if let kind = SelectionResultFormatter.pronunciationKind(for: line),
                   let source = SelectionResultFormatter.pronunciationSource(in: lines, before: index) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(SelectionResultFormatter.attributedText(from: line))
                        Button {
                            speech.toggle(source, language: kind.languageCode)
                        } label: {
                            Image(systemName: speech.isSpeaking(source) ? "stop.circle.fill" : "speaker.wave.2")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help(speech.isSpeaking(source) ? "停止播放" : "播放译文")
                        .accessibilityLabel(speech.isSpeaking(source) ? "停止播放" : "播放译文")
                    }
                } else {
                    Text(SelectionResultFormatter.attributedText(from: line))
                }
            }
        }
        .font(.system(size: 13))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private final class SpeechPlaybackController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    @Published private(set) var currentText = ""

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var speaking: Bool { synthesizer.isSpeaking }

    func isSpeaking(_ text: String) -> Bool {
        speaking && currentText == text
    }

    func toggle(_ text: String, language: String) {
        if isSpeaking(text) {
            synthesizer.stopSpeaking(at: .immediate)
            currentText = ""
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        currentText = text
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let speechString = utterance.speechString
        Task { @MainActor in
            if currentText == speechString { currentText = "" }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let speechString = utterance.speechString
        Task { @MainActor in
            if currentText == speechString { currentText = "" }
        }
    }
}

private enum SelectedTextReader {
    static func read(from processIdentifier: pid_t) throws -> String {
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            throw SelectionCaptureError.accessibilityPermission
        }

        let application = AXUIElementCreateApplication(processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else {
            throw SelectionCaptureError.noSelection
        }

        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedValue as! AXUIElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success,
              let text = selectedValue as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelectionCaptureError.noSelection
        }
        return SelectionSourceFormatter.normalized(text)
    }
}

private enum SelectionCaptureError: LocalizedError {
    case noApplication
    case accessibilityPermission
    case noSelection

    var errorDescription: String? {
        switch self {
        case .noApplication:
            "未找到当前应用，请重新选中文字后再试。"
        case .accessibilityPermission:
            "请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 QuickNote。"
        case .noSelection:
            "没有读取到选中文字。请先选中文字，再按 ⌥Space。"
        }
    }
}
