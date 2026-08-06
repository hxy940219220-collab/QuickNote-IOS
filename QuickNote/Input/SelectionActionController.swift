import AppKit
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
        resize(height: state.source.isEmpty ? 200 : 185)
        positionNearPointer()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func append(_ text: String, kind: SelectionImportKind) {
        do {
            try session.appendPlainText(text)
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
                state.result = result.text
                state.resultProvider = result.providerName
                state.isLoading = false
                resize(height: SelectionPanelLayout.resultHeight(for: SelectionResultFormatter.plainText(from: result.text)))
            } catch is CancellationError {
            } catch {
                state.isLoading = false
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
                        SelectionResultFormatter.plainText(from: self?.state.result ?? ""),
                        kind: .result
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
    static func resultHeight(for text: String) -> CGFloat {
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: 470, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        return min(max(230 + ceil(bounds.height), 300), 390)
    }
}

enum SelectionResultFormatter {
    static func attributedText(from text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func plainText(from text: String) -> String {
        String(attributedText(from: text).characters)
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

    func reset() {
        source = ""
        result = ""
        resultProvider = ""
        notice = ""
        isLoading = false
        activeAction = nil
        importedKind = nil
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
        Text(state.source.isEmpty ? state.notice : state.source)
            .font(.system(size: 13))
            .foregroundStyle(state.source.isEmpty ? .secondary : .primary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
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
                Text(SelectionResultFormatter.attributedText(from: state.result))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                Button("配置 AI", action: settings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
