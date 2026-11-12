import AppKit
import SwiftUI

@MainActor
final class ScreenshotActionController: NSObject, NSWindowDelegate {
    private let session: NoteSession
    private let aiStore: AIConfigurationStore
    private let allNotes: () throws -> [NoteRecord]
    private let streamRespond: ((Data, String) -> AsyncThrowingStream<AIStreamEvent, Error>)?
    private let confirmSending: (AIFeatureRoute) -> Bool
    private var isConfirming = false
    private var targetNoteID: UUID?
    private var targetRevision: Int?
    private var targetCursor: Int?
    private let showSettings: () -> Void
    private let state = ScreenshotActionState()
    private lazy var streamPresentation: AIStreamPresentation = {
        let presentation = AIStreamPresentation()
        presentation.onUpdate = { [weak self] in self?.applyStreamState($0) }
        return presentation
    }()
    private let desktopPet: DesktopPetController?
    private var petTaskID: UUID?
    private var captureTask: Task<Void, Never>?
    private lazy var panel = makePanel()
    private var panelIsPresented = false
    private var applyingPanelFrame = false
    private var userIsResizing = false
    private var manualContentSize: CGSize?

    init(
        session: NoteSession,
        allNotes: @escaping () throws -> [NoteRecord],
        aiStore: AIConfigurationStore = .shared,
        showSettings: @escaping () -> Void,
        desktopPet: DesktopPetController? = nil,
        streamRespond: ((Data, String) -> AsyncThrowingStream<AIStreamEvent, Error>)? = nil,
        confirmSending: ((AIFeatureRoute) -> Bool)? = nil
    ) {
        self.session = session
        self.allNotes = allNotes
        self.aiStore = aiStore
        self.showSettings = showSettings
        self.desktopPet = desktopPet
        self.streamRespond = streamRespond
        self.confirmSending = confirmSending ?? { route in
            aiStore.confirmSending(.screenshot, content: "仅发送面板中的图片与问题，用于图片分析。", route: route)
        }
        super.init()
    }

    func capture() {
        guard captureTask == nil else { return }
        panelIsPresented = false
        stopAnalysis()
        panel.orderOut(nil)
        state.reset()
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { captureTask = nil }
            do {
                let image = try await ScreenshotCapture.capture()
                guard !Task.isCancelled else { return }
                present(image)
            } catch is CancellationError {
            } catch ScreenshotCaptureError.cancelled {
            } catch {
                present(error: error)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        panelIsPresented = false
        stopAnalysis()
        state.reset()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        userIsResizing = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        userIsResizing = false
        manualContentSize = panel.contentRect(forFrameRect: panel.frame).size
        fitPanel()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard userIsResizing, let visible = sender.screen?.visibleFrame else { return frameSize }
        return NSSize(width: min(frameSize.width, visible.width), height: min(frameSize.height, visible.height))
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        manualContentSize = window.contentRect(forFrameRect: newFrame).size
        return true
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard panelIsPresented, !applyingPanelFrame, !userIsResizing else { return }
        fitPanel()
    }

    private func analyze() {
        guard !isConfirming, state.controls.canRunActions, let imageData = state.imageData else { return }
        let prompt = state.prompt
        let presentationID = state.presentationID
        let route = aiStore.resolvedSource(for: .screenshot)
        stopAnalysis()
        state.deliveryNotice = deliveryNotice(for: route)
        isConfirming = true
        defer { isConfirming = false }
        // The modal alert runs a nested event loop. A replacement or closed image
        // must not start a request after consent for the previous presentation.
        guard confirmSending(route), state.presentationID == presentationID else { return }
        let petID = desktopPet?.begin(message: "正在看图片…", detail: "图片识别 · 目标：\(state.targetTitle)")
        petTaskID = petID
        state.resultImported = false
        if case .codex = route { state.usesCodex = true } else { state.usesCodex = false }
        streamPresentation.start(streamRespond?(imageData, prompt) ??
            FeatureAI.imageStream(imageData: imageData, prompt: prompt, route: route))
    }

    private func applyStreamState(_ update: AIStreamPresentationState) {
        state.result = update.text
        state.provider = update.providerName
        state.isLoading = update.isLoading
        state.phase = AIActionPanelPhase.from(streamPhase: update.phase, hasResult: !update.text.isEmpty)
        state.resultIsComplete = update.phase == .completed
        state.resultIsPartial = update.isPartial
        state.notice = update.notice
        if let error = update.error as? AIAnalyzerError, case .configurationRequired = error {
            state.needsConfiguration = true
        } else {
            state.needsConfiguration = false
        }
        fitPanelIfAutomatic()
        guard update.phase != .streaming, update.phase != .idle else { return }
        if let petTaskID {
            let message = update.phase == .completed ? "图片分析好了"
                : update.phase == .stopped ? "已停止分析" : "识别遇到问题"
            desktopPet?.finish(petTaskID, message: message, clip: update.phase == .completed ? "complete" : "attention")
            self.petTaskID = nil
        }
    }

    private func setPromptAndAnalyze(_ prompt: String) {
        state.prompt = prompt
        analyze()
    }

    private func importImage() {
        guard state.controls.canStoreSource, let data = state.imageData else { return }
        do {
            guard let choice = NoteImportPicker.choose(notes: try allNotes(), defaultID: targetNoteID,
                revision: targetRevision) else { return }
            let wrapper = FileWrapper(regularFileWithContents: data)
            wrapper.preferredFilename = "截图.png"
            let content = NSMutableAttributedString()
            if choice.startsDocument {
                content.append(NSAttributedString(string: "图片\n", attributes: [.font: EditorTextStyle.title.font]))
            }
            content.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            try choice.insert(content, session: session, originalCursor: targetCursor)
            desktopPet?.received()
            state.imageImported = true
            state.notice = ""
        } catch let error as NoteContentAppliedError {
            state.imageImported = true
            state.notice = error.localizedDescription
        } catch {
            state.notice = "导入失败：\(error.localizedDescription)"
        }
        fitPanelIfAutomatic()
    }

    private func importResult() {
        guard state.controls.canStoreResult else { return }
        do {
            guard let choice = NoteImportPicker.choose(notes: try allNotes(), defaultID: targetNoteID,
                revision: targetRevision, preselectedDestination: state.resultDestination) else { return }
            let content = SelectionResultFormatter.richText(from: state.result, asDocumentStart: choice.startsDocument)
            try choice.insert(content, session: session, originalCursor: targetCursor)
            desktopPet?.received()
            state.resultImported = true
            state.notice = ""
        } catch let error as NoteContentAppliedError {
            state.resultImported = true
            state.notice = error.localizedDescription
        } catch {
            state.notice = "导入失败：\(error.localizedDescription)"
        }
        fitPanelIfAutomatic()
    }

    func present(_ image: NSImage, pasteboard: NSPasteboard = .general) {
        panelIsPresented = false
        stopAnalysis()
        state.reset()
        targetNoteID = session.currentNote?.id
        targetRevision = targetNoteID.map(session.contentRevision)
        targetCursor = session.currentNote?.cursorLocation
        state.targetTitle = session.currentNote?.title ?? "新便签"
        state.deliveryNotice = deliveryNotice(for: aiStore.resolvedSource(for: .screenshot))
        guard let data = ScreenshotImageProcessor.pngData(from: image) else {
            present(error: ScreenshotCaptureError.encodingFailed)
            return
        }
        _ = ScreenshotImageProcessor.copyToPasteboard(data, to: pasteboard)
        state.image = image
        state.imageData = data
        showPanel()
    }

    private func deliveryNotice(for route: AIFeatureRoute) -> String {
        "仅发送面板中的图片与问题。\(aiStore.dataDestinationDescription(for: .screenshot, route: route))"
    }

    private func present(error: Error) {
        state.phase = .failed
        state.notice = error.localizedDescription
        showPanel()
    }

    private func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let screen { fitPanel(in: screen.visibleFrame, center: true) }
        else { panel.center() }
        panelIsPresented = true
        panel.makeKeyAndOrderFront(nil)
    }

    private func fitPanelIfAutomatic() {
        guard manualContentSize == nil, !userIsResizing else { return }
        fitPanel()
    }

    private func fitPanel() {
        guard panelIsPresented, !applyingPanelFrame, let screen = panel.screen ?? NSScreen.main else { return }
        fitPanel(in: screen.visibleFrame, center: false)
    }

    private func fitPanel(in visibleFrame: CGRect, center: Bool) {
        let windowFrame = panel.frame
        let titlebarHeight = windowFrame.height - panel.contentRect(forFrameRect: windowFrame).height
        let availableContentHeight = max(0, visibleFrame.height - titlebarHeight)
        let referenceHeight = min(availableContentHeight, ScreenshotPanelLayout.maximumContentHeight)
        if state.previewReferenceHeight != referenceHeight { state.previewReferenceHeight = referenceHeight }

        let width = min(manualContentSize?.width ?? ScreenshotPanelLayout.preferredContentWidth, visibleFrame.width)
        let previewHeight = state.image.map {
            ScreenshotPreviewLayout.size(imageSize: $0.size,
                contentSize: CGSize(width: width, height: referenceHeight)).height
        } ?? 0
        let preferredHeight = ScreenshotPanelLayout.contentHeight(previewHeight: previewHeight, phase: state.phase,
            resultHeight: state.resultHeight(for: width), noticeHeight: state.noticeHeight(for: width),
            availableHeight: availableContentHeight, manualHeight: manualContentSize?.height)

        // Anchor the initial compact window at the top of its full-size envelope.
        // When output arrives, the bottom edge can grow without moving the controls.
        let envelopeHeight = (manualContentSize == nil ? referenceHeight : preferredHeight) + titlebarHeight
        let anchor = center
            ? CGRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - envelopeHeight / 2,
                     width: width, height: envelopeHeight)
            : CGRect(x: windowFrame.minX, y: windowFrame.minY,
                     width: width, height: windowFrame.height)
        let frame = ScreenshotPanelLayout.frame(current: anchor, contentHeight: preferredHeight,
            titlebarHeight: titlebarHeight, visibleFrame: visibleFrame)
        guard frame != windowFrame else { return }
        applyingPanelFrame = true
        defer { applyingPanelFrame = false }
        panel.contentMinSize = NSSize(width: min(620, visibleFrame.width),
            height: max(0, min(ScreenshotPanelLayout.minimumUserContentHeight, frame.height - titlebarHeight)))
        panel.setFrame(frame, display: true, animate: false)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: ScreenshotPanelLayout.preferredContentWidth,
                height: ScreenshotPanelLayout.maximumContentHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "图片识别"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ScreenshotActionView(
            state: state,
            analyze: { [weak self] in self?.analyze() },
            quickAnalyze: { [weak self] prompt in self?.setPromptAndAnalyze(prompt) },
            importResult: { [weak self] in self?.importResult() },
            settings: showSettings,
            stop: { [weak self] in self?.stopAnalysis() },
            close: { [weak self] in self?.panel.performClose(nil) },
            resultDestinations: { [weak self] in
                guard let self, let notes = try? allNotes() else { return [] }
                return notes.map { AIResultDestination(id: $0.id, title: $0.title) }
            }
        ))
        ScreenshotActionView.addImportButton(to: panel, state: state) { [weak self] in self?.importImage() }
        return panel
    }

    private func stopAnalysis() {
        streamPresentation.stop()
        state.isLoading = false
        if let petTaskID { desktopPet?.finish(petTaskID, message: "已停止分析", clip: "attention") }
        petTaskID = nil
    }
}

@MainActor
final class ScreenshotActionState: ObservableObject {
    private(set) var presentationID = UUID()
    @Published var image: NSImage?
    @Published var imageData: Data?
    @Published var prompt = ""
    @Published var result = ""
    @Published var provider = ""
    @Published var notice = ""
    @Published var isLoading = false
    @Published var resultIsComplete = false
    @Published var resultIsPartial = false
    @Published var usesCodex = false
    @Published var needsConfiguration = false
    @Published var imageImported = false
    @Published var resultImported = false
    @Published var targetTitle = ""
    @Published var resultDestination: AIResultDestination?
    @Published var showsResultHelp = false
    @Published var deliveryNotice = ""
    @Published var phase = AIActionPanelPhase.idle
    @Published var previewReferenceHeight: CGFloat?

    var controls: AIActionPanelControls {
        AIActionPanelControls(phase: phase, hasSource: image != nil, hasResult: !result.isEmpty,
            sourceConsumed: imageImported, resultConsumed: resultImported)
    }

    func resultHeight(for contentWidth: CGFloat) -> CGFloat? {
        guard !result.isEmpty else { return nil }
        let text = resultIsComplete ? SelectionResultFormatter.plainText(from: result) : result
        let padding = ScreenshotPanelLayout.resultPadding * 2
        return ScreenshotPanelLayout.textHeight(text, width: ScreenshotPreviewLayout.containerWidth(for: contentWidth) - padding,
            fontSize: 13, lineSpacing: 3) + padding
    }

    func noticeHeight(for contentWidth: CGFloat) -> CGFloat {
        guard !notice.isEmpty else { return 0 }
        let width = ScreenshotPreviewLayout.containerWidth(for: contentWidth) - (needsConfiguration ? 132 : 22)
        let height = min(42, ScreenshotPanelLayout.textHeight(notice, width: width, fontSize: 11))
        return max(needsConfiguration ? 24 : 14, height)
    }

    func reset() {
        presentationID = UUID()
        image = nil
        imageData = nil
        prompt = ""
        result = ""
        provider = ""
        notice = ""
        isLoading = false
        resultIsComplete = false
        resultIsPartial = false
        usesCodex = false
        needsConfiguration = false
        imageImported = false
        resultImported = false
        resultDestination = nil
        showsResultHelp = false
        deliveryNotice = ""
        phase = .idle
    }
}

enum ScreenshotPanelLayout {
    static let preferredContentWidth: CGFloat = 720
    static let maximumContentHeight: CGFloat = 640
    static let minimumUserContentHeight: CGFloat = 160
    static let quickActionsHeight: CGFloat = 26
    static let questionHeight: CGFloat = 24
    static let progressHeight: CGFloat = 25
    static let footerHeight: CGFloat = 25
    static let minimumResultHeight: CGFloat = 52
    static let resultPadding: CGFloat = 12
    static let rowSpacing: CGFloat = 8

    static func contentHeight(previewHeight: CGFloat, phase: AIActionPanelPhase, resultHeight: CGFloat? = nil,
                              noticeHeight: CGFloat = 0, availableHeight: CGFloat, manualHeight: CGFloat? = nil) -> CGFloat {
        let available = max(0, availableHeight)
        if let manualHeight { return min(max(0, manualHeight), available) }
        var rows: [CGFloat] = []
        if previewHeight > 0 { rows = [previewHeight, quickActionsHeight, questionHeight] }
        if phase == .running, resultHeight != nil { rows.append(progressHeight) }
        if phase == .running || resultHeight != nil {
            rows.append(max(minimumResultHeight, resultHeight ?? 0))
        }
        if (phase == .result || phase == .failed), resultHeight != nil { rows.append(footerHeight) }
        if noticeHeight > 0 { rows.append(noticeHeight) }

        let height = rows.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * rowSpacing
            + ScreenshotPreviewLayout.contentPadding * 2
        return min(height, maximumContentHeight, available)
    }

    static func frame(current: CGRect, contentHeight: CGFloat, titlebarHeight: CGFloat, visibleFrame: CGRect) -> CGRect {
        let width = min(current.width, visibleFrame.width)
        let desiredHeight = min(contentHeight + titlebarHeight, visibleFrame.height)
        let minimumHeight = min(desiredHeight, minimumUserContentHeight + titlebarHeight)
        let top = min(max(current.maxY, visibleFrame.minY + minimumHeight), visibleFrame.maxY)
        let height = min(desiredHeight, top - visibleFrame.minY)
        let x = min(max(current.minX, visibleFrame.minX), visibleFrame.maxX - width)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    static func textHeight(_ text: String, width: CGFloat, fontSize: CGFloat, lineSpacing: CGFloat = 0) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: paragraph]
        )
        return ceil(bounds.height)
    }
}

/// Returns the preview's outer size, including its own padding.
enum ScreenshotPreviewLayout {
    static let padding: CGFloat = 8
    static let contentPadding: CGFloat = 16
    static let maximumHeightFraction: CGFloat = 0.5
    static let minimumControlsHeight: CGFloat = 220

    static func containerWidth(for contentWidth: CGFloat) -> CGFloat {
        guard contentWidth.isFinite else { return 0 }
        return max(0, contentWidth - contentPadding * 2)
    }

    static func size(imageSize: CGSize, contentSize: CGSize) -> CGSize {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              contentSize.width.isFinite, contentSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              contentSize.width > 0, contentSize.height > 0 else { return .zero }
        let outerHeight = min(contentSize.height * maximumHeightFraction,
            max(0, contentSize.height - minimumControlsHeight))
        return size(imageSize: imageSize, contentWidth: contentSize.width, maximumHeight: outerHeight)
    }

    static func size(imageSize: CGSize, contentWidth: CGFloat, maximumHeight: CGFloat) -> CGSize {
        guard imageSize.width.isFinite, imageSize.height.isFinite, maximumHeight.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let width = containerWidth(for: contentWidth) - padding * 2
        let height = maximumHeight - padding * 2
        guard width > 0, height > 0 else { return .zero }
        let scale = min(1, min(width / imageSize.width, height / imageSize.height))
        return CGSize(width: imageSize.width * scale + padding * 2,
            height: imageSize.height * scale + padding * 2)
    }
}

struct ScreenshotActionView: View {
    @ObservedObject var state: ScreenshotActionState
    let analyze: () -> Void
    let quickAnalyze: (String) -> Void
    let importResult: () -> Void
    let settings: () -> Void
    let stop: () -> Void
    let close: () -> Void
    var resultDestinations: () -> [AIResultDestination] = { [] }
    @State private var loadedDestinations: [AIResultDestination] = []
    private let quickActions = [
        ("总结要点", "text.alignleft", "用简洁的条目总结截图中的核心内容和重点。"),
        ("提取原文", "doc.text.viewfinder", "准确提取截图中的全部文字，保持原有段落和列表结构。"),
        ("翻译中文", "character.book.closed", "提取截图中的文字并翻译成自然、准确的中文，保留原有结构。"),
        ("整理表格", "tablecells", "识别截图中的表格或结构化数据，并整理成清晰的 Markdown 表格。"),
        ("生成待办", "checklist", "从截图内容中提取需要执行的事项，每项使用 Markdown - [ ] 格式；已完成项使用 - [x]，保持原意。"),
        ("排查问题", "exclamationmark.magnifyingglass", "找出截图中的异常、错误或体验问题，并给出可执行的解决建议。"),
    ]

    var body: some View {
        GeometryReader { geometry in
            content(in: geometry.size)
        }
        .onExitCommand {
            if state.showsResultHelp { state.showsResultHelp = false }
            else { close() }
        }
    }

    private func content(in contentSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: ScreenshotPanelLayout.rowSpacing) {
            if let image = state.image {
                preview(image, contentSize: contentSize, noticeHeight: state.noticeHeight(for: contentSize.width))
                quickActionButtons
                    .frame(height: ScreenshotPanelLayout.quickActionsHeight)
                promptField
                    .frame(height: ScreenshotPanelLayout.questionHeight)
            }

            if state.controls.canStop, !state.result.isEmpty {
                progressRow.frame(height: ScreenshotPanelLayout.progressHeight)
            }
            if state.controls.canStop || !state.result.isEmpty {
                Group {
                    if state.result.isEmpty {
                        progressRow.padding(.horizontal, ScreenshotPanelLayout.resultPadding)
                    } else {
                        ScrollView {
                        Text(state.resultIsComplete ? SelectionResultFormatter.attributedText(from: state.result) : AttributedString(state.result))
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(ScreenshotPanelLayout.resultPadding)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                if state.controls.primaryAction == .storeResult {
                    AIResultFooter(destinationTitle: state.resultDestination?.title ?? state.targetTitle,
                        imported: state.resultImported, canStore: state.controls.canStoreResult,
                        partial: state.resultIsPartial, destinations: loadedDestinations,
                        provider: state.provider, deliveryNotice: state.deliveryNotice, showsHelp: $state.showsResultHelp,
                        selectDestination: { state.resultDestination = $0 }, store: importResult)
                    .frame(height: ScreenshotPanelLayout.footerHeight)
                    .task { loadedDestinations = resultDestinations() }
                }
            }
            if !state.notice.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(state.notice)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .help(state.notice)
                    Spacer(minLength: 0)
                    if state.needsConfiguration {
                        Button("配置图片模型", action: settings).controlSize(.small)
                    }
                }
                .frame(height: state.noticeHeight(for: contentSize.width), alignment: .top)
            }
        }
        .padding(ScreenshotPreviewLayout.contentPadding)
        .frame(width: max(0, contentSize.width), height: max(0, contentSize.height), alignment: .topLeading)
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(state.usesCodex && state.result.isEmpty ? "正在等待 Codex…" : "正在调用图片模型…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("停止", action: stop).controlSize(.small)
        }
    }

    @MainActor
    static func addImportButton(to window: NSWindow, state: ScreenshotActionState, action: @escaping () -> Void) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        let host = NSHostingView(rootView: ScreenshotImageImportButton(state: state, action: action))
        host.frame.size = NSSize(width: 36, height: 26)
        accessory.view = host
        window.addTitlebarAccessoryViewController(accessory)
    }

    @ViewBuilder
    private func preview(_ image: NSImage, contentSize: CGSize, noticeHeight: CGFloat) -> some View {
        let referenceSize = CGSize(width: contentSize.width, height: state.previewReferenceHeight ?? contentSize.height)
        let idealSize = ScreenshotPreviewLayout.size(imageSize: image.size, contentSize: referenceSize)
        let controlsHeight = ScreenshotPanelLayout.contentHeight(previewHeight: 1, phase: state.phase,
            resultHeight: state.result.isEmpty ? nil : ScreenshotPanelLayout.minimumResultHeight,
            noticeHeight: noticeHeight, availableHeight: ScreenshotPanelLayout.maximumContentHeight) - 1
        let size = ScreenshotPreviewLayout.size(imageSize: image.size, contentWidth: contentSize.width,
            maximumHeight: min(idealSize.height, max(0, contentSize.height - controlsHeight)))
        if size.width > 0, size.height > 0 {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size.width - ScreenshotPreviewLayout.padding * 2,
                    height: size.height - ScreenshotPreviewLayout.padding * 2)
                .padding(ScreenshotPreviewLayout.padding)
                .frame(width: ScreenshotPreviewLayout.containerWidth(for: contentSize.width), height: size.height)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
                .accessibilityLabel("截图预览")
        }
    }

    private var quickActionButtons: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(quickActions, id: \.0) { action in
                    quickButton(action.0, icon: action.1, prompt: action.2)
                }
            }
            .padding(.vertical, 2)
        }
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var promptField: some View {
        AIPanelQuestionField(placeholder: "输入问题，让 AI 解答这张图片", text: $state.prompt,
            canSubmit: state.controls.canRunActions, sendLabel: "发送图片分析问题", submit: analyze)
    }

    private func quickButton(_ title: String, icon: String, prompt: String) -> some View {
        Button { quickAnalyze(prompt) } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11))
                .fixedSize()
        }
        .buttonStyle(.bordered)
        .disabled(!state.controls.canRunActions)
    }
}

private struct ScreenshotImageImportButton: View {
    @ObservedObject var state: ScreenshotActionState
    let action: () -> Void

    var body: some View {
        let title = state.imageImported ? "图片已导入" : "导入图片"
        Button(action: action) {
            Image(systemName: state.imageImported ? "checkmark" : "square.and.arrow.down")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!state.controls.canStoreSource)
        .help(title)
        .accessibilityLabel(title)
    }
}

enum ScreenshotImageProcessor {
    static let maximumLongEdge: CGFloat = 2_200

    static func image(from pasteboard: NSPasteboard) -> NSImage? {
        if let image = NSImage(pasteboard: pasteboard) {
            return image
        }
        guard let url = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )?.first as? URL else { return nil }
        return NSImage(contentsOf: url)
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let scale = min(1, maximumLongEdge / max(width, height))
        let pixelWidth = max(1, Int(floor(width * scale)))
        let pixelHeight = max(1, Int(floor(height * scale)))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let rendered = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])
    }

    @discardableResult
    static func copyToPasteboard(_ pngData: Data, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let image = NSImage(data: pngData), let tiffData = image.tiffRepresentation else { return false }
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        item.setData(tiffData, forType: .tiff)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

private enum ScreenshotCapture {
    static func capture() async throws -> NSImage { try await interactive(arguments: ["-i", "-s"]) }

    private static func interactive(arguments: [String]) async throws -> NSImage {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "QuickNote-Screenshot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + ["-x", "-t", "png", url.path]
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else { throw ScreenshotCaptureError.cancelled }
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else { throw ScreenshotCaptureError.encodingFailed }
        return image
    }

}

private enum ScreenshotCaptureError: LocalizedError, Equatable {
    case cancelled
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .cancelled: "已取消截图。"
        case .encodingFailed: "截图无法读取，请重试。"
        }
    }
}
