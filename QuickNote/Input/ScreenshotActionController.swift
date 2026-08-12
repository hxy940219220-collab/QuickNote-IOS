import AppKit
import SwiftUI

@MainActor
final class ScreenshotActionController: NSObject, NSWindowDelegate {
    private let session: NoteSession
    private let aiStore: AIConfigurationStore
    private let showSettings: () -> Void
    private let state = ScreenshotActionState()
    private var analysisTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private lazy var panel = makePanel()

    init(
        session: NoteSession,
        aiStore: AIConfigurationStore = .shared,
        showSettings: @escaping () -> Void
    ) {
        self.session = session
        self.aiStore = aiStore
        self.showSettings = showSettings
        super.init()
    }

    func capture() {
        guard captureTask == nil else { return }
        analysisTask?.cancel()
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
        analysisTask?.cancel()
        state.reset()
    }

    private func analyze() {
        guard let imageData = state.imageData else { return }
        analysisTask?.cancel()
        state.result = ""
        state.resultImported = false
        state.provider = ""
        state.notice = ""
        state.needsConfiguration = false
        state.isLoading = true
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await AIImageAnalyzer.respond(
                    imageData: imageData,
                    prompt: state.prompt,
                    store: aiStore
                )
                guard !Task.isCancelled else { return }
                state.result = result.text
                state.provider = result.providerName
                state.isLoading = false
            } catch is CancellationError {
            } catch let error as AIAnalyzerError {
                state.isLoading = false
                if case .configurationRequired = error {
                    state.needsConfiguration = true
                }
                state.notice = error.localizedDescription
            } catch {
                state.isLoading = false
                state.notice = error.localizedDescription
            }
        }
    }

    private func setPromptAndAnalyze(_ prompt: String) {
        state.prompt = prompt
        analyze()
    }

    private func importImage() {
        guard let data = state.imageData else { return }
        do {
            try session.appendImage(data)
            state.imageImported = true
            state.notice = ""
        } catch {
            state.notice = "导入失败：\(error.localizedDescription)"
        }
    }

    private func importResult() {
        guard !state.result.isEmpty else { return }
        do {
            try session.appendAttributedText(SelectionResultFormatter.richText(
                from: state.result,
                asDocumentStart: session.document.string.isEmpty
            ))
            state.resultImported = true
            state.notice = ""
        } catch {
            state.notice = "导入失败：\(error.localizedDescription)"
        }
    }

    private func present(_ image: NSImage) {
        guard let data = ScreenshotImageProcessor.pngData(from: image) else {
            present(error: ScreenshotCaptureError.encodingFailed)
            return
        }
        state.image = image
        state.imageData = data
        showPanel()
    }

    private func present(error: Error) {
        state.notice = error.localizedDescription
        showPanel()
    }

    private func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "截图识图"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 620, height: 520)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ScreenshotActionView(
            state: state,
            analyze: { [weak self] in self?.analyze() },
            quickAnalyze: { [weak self] prompt in self?.setPromptAndAnalyze(prompt) },
            importImage: { [weak self] in self?.importImage() },
            importResult: { [weak self] in self?.importResult() },
            settings: showSettings
        ))
        return panel
    }
}

@MainActor
private final class ScreenshotActionState: ObservableObject {
    @Published var image: NSImage?
    @Published var imageData: Data?
    @Published var prompt = ""
    @Published var result = ""
    @Published var provider = ""
    @Published var notice = ""
    @Published var isLoading = false
    @Published var needsConfiguration = false
    @Published var imageImported = false
    @Published var resultImported = false

    func reset() {
        image = nil
        imageData = nil
        prompt = ""
        result = ""
        provider = ""
        notice = ""
        isLoading = false
        needsConfiguration = false
        imageImported = false
        resultImported = false
    }
}

private struct ScreenshotActionView: View {
    @ObservedObject var state: ScreenshotActionState
    let analyze: () -> Void
    let quickAnalyze: (String) -> Void
    let importImage: () -> Void
    let importResult: () -> Void
    let settings: () -> Void
    private let quickActions = [
        ("概括", "text.alignleft", "概括这张截图的主要内容和重点。"),
        ("提取文字", "doc.text.viewfinder", "准确提取截图中的全部文字，保持原有段落和列表结构。"),
        ("解释界面", "rectangle.3.group", "解释这个界面的用途、主要模块和当前状态。"),
        ("发现问题", "exclamationmark.magnifyingglass", "找出截图中的异常、错误或体验问题，并给出解决建议。"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("截图识图").font(.system(size: 18, weight: .semibold))
                    Text(state.provider.isEmpty ? "选择问题，或直接输入你想了解的内容" : state.provider)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: importImage) {
                    Label(state.imageImported ? "图片已导入" : "导入图片", systemImage: state.imageImported ? "checkmark" : "square.and.arrow.down")
                }
                .disabled(state.imageImported || state.image == nil)
            }

            if let image = state.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 150, maxHeight: state.result.isEmpty ? 260 : 190)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(Color.secondary.opacity(0.32), lineWidth: 1)
                    }
                    .shadow(color: Color.black.opacity(0.06), radius: 4, y: 1)

                HStack(spacing: 8) {
                    TextField("你想了解这张图片的什么？", text: $state.prompt)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(analyze)
                    Button(state.isLoading ? "分析中…" : "分析", action: analyze)
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isLoading)
                }
                HStack(spacing: 7) {
                    ForEach(quickActions, id: \.0) { action in
                        quickButton(action.0, icon: action.1, prompt: action.2)
                    }
                }
                .controlSize(.small)
            }

            if state.isLoading {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("正在调用图片模型…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 84, alignment: .center)
            } else if !state.result.isEmpty {
                HStack(spacing: 8) {
                    Text("分析结果").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(action: importResult) {
                        Label(
                            state.resultImported ? "已导入" : "导入分析",
                            systemImage: state.resultImported ? "checkmark" : "square.and.arrow.down"
                        )
                    }
                    .controlSize(.small)
                    .disabled(state.resultImported)
                }
                ScrollView {
                    Text(SelectionResultFormatter.attributedText(from: state.result))
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
            } else if !state.notice.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(state.notice).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if state.needsConfiguration {
                        Button("配置图片模型", action: settings).controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
    }

    private func quickButton(_ title: String, icon: String, prompt: String) -> some View {
        Button { quickAnalyze(prompt) } label: {
            Label(title, systemImage: icon)
        }
            .disabled(state.isLoading)
    }
}

enum ScreenshotImageProcessor {
    static let maximumLongEdge: CGFloat = 2_200

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
