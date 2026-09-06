import AppKit
import ImageIO

/// Decodes only material explicitly dropped by the user. Never fetches URLs or opens attachments.
@MainActor
struct DesktopPetDrop {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .string, .URL]
    static let maximumBytes = 25 * 1024 * 1024
    let content: NSAttributedString
    let image: NSImage?
    let summary: String

    static func read(from pasteboard: NSPasteboard) throws -> Self {
        let items = pasteboard.pasteboardItems ?? []
        guard !items.isEmpty, items.count <= 10 else {
            throw NoteRecoveryError(message: "一次最多接收 10 项内容，请分批拖入。")
        }
        let content = NSMutableAttributedString()
        var totalBytes = 0
        var names: [String] = []
        var singleImage: NSImage?
        for item in items {
            if content.length > 0, !content.string.hasSuffix("\n") {
                content.append(NSAttributedString(string: "\n", attributes: [.font: EditorTextStyle.body.font]))
            }
            var data: Data?
            var filename = "图片.png"
            var requiresImage = false
            if let path = item.string(forType: .fileURL) {
                guard let url = URL(string: path), url.isFileURL else {
                    throw NoteRecoveryError(message: "请拖入本地文件，网页链接可以作为文字保存。")
                }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw NoteRecoveryError(message: "暂不接收文件夹、应用或替身，请拖入其中的具体文件。")
                }
                guard (values.fileSize ?? 0) <= maximumBytes - totalBytes else { throw tooLarge() }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                data = try file.read(upToCount: maximumBytes - totalBytes + 1) ?? Data()
                filename = url.lastPathComponent
            } else if let type = item.availableType(from: [.png, .tiff]) {
                data = item.data(forType: type)
                filename = type == .tiff ? "图片.tiff" : "图片.png"
                requiresImage = true
            }
            if let data {
                totalBytes += data.count
                guard totalBytes <= maximumBytes else { throw tooLarge() }
                let image = try decodedImage(data)
                guard !requiresImage || image != nil else { throw NoteRecoveryError(message: "这张图片无法读取，请重新拖入。") }
                let wrapper = FileWrapper(regularFileWithContents: data)
                wrapper.preferredFilename = filename
                let attachment = NSTextAttachment(fileWrapper: wrapper)
                if let image {
                    attachment.bounds.size = AttachmentPresentation.scaledSize(for: image.size, fitting: NSSize(width: 640, height: 640))
                }
                content.append(NSAttributedString(attachment: attachment))
                content.append(NSAttributedString(string: "\n", attributes: [.font: EditorTextStyle.body.font]))
                singleImage = image
                names.append(filename)
            } else if !requiresImage, let text = item.string(forType: .URL) ?? item.string(forType: .string),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard text.utf8.count <= 1024 * 1024 else { throw NoteRecoveryError(message: "文字太长了，请分段拖入（每项最多 1 MB）。") }
                totalBytes += text.utf8.count
                guard totalBytes <= maximumBytes else { throw tooLarge() }
                var attributes: [NSAttributedString.Key: Any] = [.font: EditorTextStyle.body.font]
                if let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                    attributes[.link] = url
                }
                content.append(NSAttributedString(string: text, attributes: attributes))
                singleImage = nil
                names.append(String(text.prefix(60)))
            } else {
                throw NoteRecoveryError(message: "暂时读不到这项内容，请先保存为文件或图片，再拖给我。")
            }
        }
        return Self(content: content, image: items.count == 1 ? singleImage : nil,
                    summary: names.count == 1 ? names[0] : "\(names.count) 项内容：\(names.joined(separator: "、"))")
    }

    private static func tooLarge() -> NoteRecoveryError {
        NoteRecoveryError(message: "这批内容超过 25 MB，请分批或压缩后再拖入。")
    }

    private static func decodedImage(_ data: Data) throws -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else { return nil }
        guard width > 0, height > 0, width * height <= 40_000_000 else {
            throw NoteRecoveryError(message: "图片分辨率过大，请缩小到 4000 万像素以内。")
        }
        return NSImage(data: data)
    }
}

@MainActor
final class DesktopPetDropController: NSObject, NSPopoverDelegate {
    private let session: NoteSession
    private let allNotes: () throws -> [NoteRecord]
    private weak var pet: DesktopPetController?
    private let showImage: (NSImage) -> Void
    let popover = NSPopover()
    private let notice = NSTextField(wrappingLabelWithString: "")
    private var storeButton: NSButton?
    private var targetID: UUID?
    private var targetRevision: Int?
    private var targetCursor: Int?
    private(set) var pending: DesktopPetDrop?

    init(session: NoteSession, allNotes: @escaping () throws -> [NoteRecord],
         pet: DesktopPetController, showImage: @escaping (NSImage) -> Void) {
        self.session = session
        self.allNotes = allNotes
        self.pet = pet
        self.showImage = showImage
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func present(_ drop: DesktopPetDrop) {
        guard pending == nil, let anchor = pet?.petPanel.contentView, pet?.isPresented == true else { return }
        pending = drop
        pet?.dropPreviewPresented = true
        targetID = session.currentNote?.id
        targetRevision = targetID.map(session.contentRevision)
        targetCursor = session.currentNote?.cursorLocation
        let controller = NSViewController()
        let stack = PetDropSurface()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 14, right: 16)
        let bird = NSImageView()
        bird.image = pet?.image(clip: "greeting", direction: "right", frame: 4)
        bird.imageScaling = .scaleProportionallyUpOrDown
        bird.setAccessibilityElement(false)
        let title = NSTextField(labelWithString: "接住啦～")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        let cancel = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "取消本次素材")!,
                              target: self, action: #selector(cancel))
        cancel.isBordered = false
        cancel.contentTintColor = .secondaryLabelColor
        cancel.keyEquivalent = "\u{1b}"
        cancel.toolTip = "取消，不保存这次素材"
        cancel.setAccessibilityLabel("取消本次素材")
        let header = NSStackView(views: [bird, title, NSView(), cancel])
        header.spacing = 8
        let thumbnail = NSImageView()
        thumbnail.image = drop.image ?? NSImage(systemSymbolName: "doc.text", accessibilityDescription: "拖入的素材")
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.identifier = NSUserInterfaceItemIdentifier("quicknote.pet.dropThumbnail")
        thumbnail.setAccessibilityLabel(drop.image == nil ? "拖入的素材" : "图片预览")
        let summary = NSTextField(wrappingLabelWithString: String(drop.summary.prefix(100)))
        summary.font = .systemFont(ofSize: 12)
        summary.maximumNumberOfLines = 2
        summary.lineBreakMode = .byTruncatingMiddle
        summary.toolTip = drop.summary
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let material = NSStackView(views: [thumbnail, summary])
        material.spacing = 10
        notice.stringValue = "还没存入，选个去处吧。"
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .secondaryLabelColor
        notice.maximumNumberOfLines = 0
        let buttons = NSStackView()
        buttons.spacing = 8
        buttons.distribution = .fillEqually
        let store = PetDropPrimaryButton(title: "存入便签…", target: self, action: #selector(chooseImport))
        store.isBordered = false
        store.keyEquivalent = "\r"
        store.attributedTitle = NSAttributedString(string: store.title,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
        store.identifier = NSUserInterfaceItemIdentifier("quicknote.pet.storeDrop")
        store.setAccessibilityRole(.button)
        store.setAccessibilityLabel("存入便签，选择目标与位置")
        storeButton = store
        buttons.addArrangedSubview(store)
        if drop.image != nil {
            let analyze = NSButton(title: "识别图片…", target: self, action: #selector(analyzeImage))
            analyze.bezelStyle = .rounded
            analyze.font = .systemFont(ofSize: 12)
            buttons.addArrangedSubview(analyze)
        }
        for view in [header, material, notice, buttons] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        NSLayoutConstraint.activate([
            bird.widthAnchor.constraint(equalToConstant: 32), bird.heightAnchor.constraint(equalToConstant: 32),
            cancel.widthAnchor.constraint(equalToConstant: 24), cancel.heightAnchor.constraint(equalToConstant: 24),
            thumbnail.widthAnchor.constraint(equalToConstant: 44), thumbnail.heightAnchor.constraint(equalToConstant: 44),
            store.heightAnchor.constraint(equalToConstant: 32),
            buttons.heightAnchor.constraint(equalToConstant: 32)
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 292).isActive = true
        controller.view = stack
        popover.contentViewController = controller
        popover.contentSize = stack.fittingSize
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    @objc func cancel() {
        pending = nil
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        pending = nil
        pet?.dropPreviewClosed()
    }

    @objc private func chooseImport() {
        guard pending != nil else { return }
        // Keep this batch alive while the native note picker takes focus.
        popover.behavior = .applicationDefined
        defer { popover.behavior = .transient }
        do {
            guard let choice = NoteImportPicker.choose(notes: try allNotes(), defaultID: targetID, revision: targetRevision) else { return }
            try confirmImport(choice)
        } catch let error as NoteContentAppliedError {
            // Retrying insertion would duplicate already-applied content. Existing save recovery owns it.
            pending = nil
            storeButton?.isEnabled = false
            showError(error.localizedDescription)
        } catch {
            showError("没有存入：\(error.localizedDescription)")
        }
    }

    private func showError(_ message: String) {
        notice.stringValue = message
        notice.toolTip = message
        notice.textColor = .systemRed
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = view.fittingSize
        }
        NSAccessibility.post(element: notice, notification: .valueChanged)
    }

    func confirmImport(_ choice: NoteImportPicker.Choice) throws {
        guard let pending else { return }
        if choice.position == .newNote, choice.newTitle == nil {
            throw NoteRecoveryError(message: "请先填写新便签的标题。")
        }
        do {
            try choice.insert(pending.content, session: session, originalCursor: targetCursor)
        } catch let error as NoteContentAppliedError {
            self.pending = nil
            pet?.notify("内容已接收，保存需重试", detail: "请查看便签中的保存提示，勿重复导入")
            throw error
        } catch {
            pet?.notify("这次没有存入", detail: "素材还在，请检查目标或重试")
            throw error
        }
        cancel()
        pet?.received()
    }

    @objc func analyzeImage() {
        guard let image = pending?.image else { return }
        cancel()
        pet?.notify("图片接住啦", detail: "确认图片与用途后，再开始识别", clip: "receive")
        showImage(image) // Existing image preview still requires its own explicit AI-send confirmation.
    }
}

private final class PetDropPrimaryButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        // The pet stays non-activating, so native default buttons otherwise lose their accent.
        let color = NSColor.systemBlue.blended(withFraction: 0.16, of: .black) ?? .systemBlue
        color.withAlphaComponent(isEnabled ? (isHighlighted ? 0.8 : 1) : 0.35).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 3), xRadius: 7, yRadius: 7).fill()
        super.draw(dirtyRect)
    }
}

private final class PetDropSurface: NSStackView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // A quiet solid surface stays legible above any desktop wallpaper, in either appearance.
        let color = NSColor.windowBackgroundColor.blended(withFraction: 0.035, of: .systemTeal)
            ?? .windowBackgroundColor
        color.setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
