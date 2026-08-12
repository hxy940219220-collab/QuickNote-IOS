import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor
final class ScreenshotActionController: NSObject, NSWindowDelegate {
    private let aiStore: AIConfigurationStore
    private let showSettings: () -> Void
    private let state = ScreenshotActionState()
    private var analysisTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private lazy var panel = makePanel()

    init(
        aiStore: AIConfigurationStore = .shared,
        showSettings: @escaping () -> Void
    ) {
        self.aiStore = aiStore
        self.showSettings = showSettings
        super.init()
    }

    func capture(_ mode: CommandEventMonitor.ScreenshotMode) {
        guard captureTask == nil else { return }
        analysisTask?.cancel()
        panel.orderOut(nil)
        state.reset()
        captureTask = Task { [weak self] in
            guard let self else { return }
            defer { captureTask = nil }
            do {
                let image = try await ScreenshotCapture.capture(mode)
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

    private func dismiss() {
        analysisTask?.cancel()
        panel.orderOut(nil)
        state.reset()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "截图识图"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 560, height: 480)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ScreenshotActionView(
            state: state,
            analyze: { [weak self] in self?.analyze() },
            quickAnalyze: { [weak self] prompt in self?.setPromptAndAnalyze(prompt) },
            settings: showSettings,
            close: { [weak self] in self?.dismiss() }
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

    func reset() {
        image = nil
        imageData = nil
        prompt = ""
        result = ""
        provider = ""
        notice = ""
        isLoading = false
        needsConfiguration = false
    }
}

private struct ScreenshotActionView: View {
    @ObservedObject var state: ScreenshotActionState
    let analyze: () -> Void
    let quickAnalyze: (String) -> Void
    let settings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("截图识图", systemImage: "viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("关闭", action: close)
            }

            if let image = state.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 280)
                    .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 8) {
                    TextField("你想了解这张图片的什么？", text: $state.prompt)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(analyze)
                    Button(state.isLoading ? "分析中…" : "分析", action: analyze)
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isLoading)
                }
                HStack(spacing: 6) {
                    quickButton("概括内容", prompt: "概括这张截图的主要内容和重点。")
                    quickButton("提取文字", prompt: "准确提取截图中的全部文字，保持原有段落和列表结构。")
                    quickButton("解释界面", prompt: "解释这个界面的用途、主要模块和当前状态。")
                    quickButton("查找问题", prompt: "找出截图中的异常、错误或体验问题，并给出解决建议。")
                }
                .controlSize(.small)
            }

            if state.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在调用图片模型…").foregroundStyle(.secondary)
                }
            } else if !state.result.isEmpty {
                HStack(spacing: 8) {
                    Text("分析结果").font(.system(size: 13, weight: .semibold))
                    Text(state.provider).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                ScrollView {
                    Text(SelectionResultFormatter.attributedText(from: state.result))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        .padding(18)
        .frame(minWidth: 560, minHeight: 480)
    }

    private func quickButton(_ title: String, prompt: String) -> some View {
        Button(title) { quickAnalyze(prompt) }
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
    static func capture(_ mode: CommandEventMonitor.ScreenshotMode) async throws -> NSImage {
        switch mode {
        case .region:
            return try await interactive(arguments: ["-i", "-s"])
        case .window:
            return try await interactive(arguments: ["-i", "-w"])
        case .screen:
            return try await currentScreen()
        }
    }

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

    private static func currentScreen() async throws -> NSImage {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let displayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw ScreenshotCaptureError.noDisplay
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenshotCaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

private enum ScreenshotCaptureError: LocalizedError, Equatable {
    case cancelled
    case noDisplay
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .cancelled: "已取消截图。"
        case .noDisplay: "没有找到可截图的显示器。"
        case .encodingFailed: "截图无法读取，请重试。"
        }
    }
}
