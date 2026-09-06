import AppKit
import QuartzCore

struct DesktopPetActivity {
    struct Entry {
        let id: UUID
        let message: String
        let detail: String
    }
    private var tasks: [Entry] = []
    var current: Entry? { tasks.last }

    mutating func begin(_ id: UUID, message: String, detail: String) {
        tasks.removeAll { $0.id == id }
        tasks.append(Entry(id: id, message: message, detail: detail))
    }

    @discardableResult mutating func finish(_ id: UUID) -> Bool {
        guard tasks.contains(where: { $0.id == id }) else { return false }
        tasks.removeAll { $0.id == id }
        return true
    }
}

/// Independent desktop companion; commands reuse the app's existing consent and editing flows.
@MainActor
final class DesktopPetController: NSObject, NSMenuDelegate {
    static let enabledKey = "desktopPet.enabled"
    static let positionKey = "desktopPet.position"
    static let scaleKey = "desktopPet.scale"
    static let soundKey = "desktopPet.soundEnabled"
    static let canvasSide: CGFloat = 100
    static let scaleRange: ClosedRange<CGFloat> = 0.5...1.5
    static let idlePauseSeconds = 0.8...1.4
    static let quickActionSize = NSSize(width: 80, height: 180)
    static let quickActionsCloseDelay: TimeInterval = 0.32
    enum Action: Int, CaseIterable {
        case openNote, newNote, screenshot, selection, settings, voice
        var title: String {
            switch self {
            case .openNote: "打开便签"
            case .newNote: "新建便签"
            case .screenshot: "截图识别…"
            case .selection: "分析选中文字…"
            case .settings: "AI 设置…"
            case .voice: "语音便签"
            }
        }
    }
    var onAction: ((Action, pid_t?) -> Void)?
    var onDrop: ((DesktopPetDrop) -> Void)?
    var canReceiveDrop: (() -> Bool)?
    var onHidden: (() -> Void)?
    var quickActionsSuppressed = false {
        didSet { if quickActionsSuppressed { setQuickActionsVisible(false, animated: false) } }
    }
    var audioFeedbackSuppressed = false { didSet { if audioFeedbackSuppressed { chirp?.stop() } } }
    var dropPreviewPresented = false {
        didSet { if dropPreviewPresented { bubblePanel.orderOut(nil) } }
    }
    struct Clip: Decodable {
        let id: String
        let frameDurationsMs: [Int]
    }
    private struct Manifest: Decodable { let clips: [Clip] }
    let clips: [Clip]
    private let defaults: UserDefaults
    private let resourceURL: URL?
    private var images: [String: NSImage] = [:]
    private let bird = DesktopPetImageView(frame: NSRect(x: 0, y: 0, width: canvasSide, height: canvasSide))
    private let label = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    let petPanel = DesktopPetController.makePanel(size: NSSize(width: canvasSide, height: canvasSide))
    let quickActionsPanel = DesktopPetController.makePanel(size: quickActionSize)
    private let bubblePanel = DesktopPetController.makePanel(size: NSSize(width: 210, height: 54))
    private var quickButtons: [DesktopPetQuickButton] = []
    private var focusedQuickAction: Int?
    private var globalHoverMonitor: Any?
    private var localHoverMonitor: Any?
    private var quickActionsDismissTask: Task<Void, Never>?
    private var quickActionsFadeTask: Task<Void, Never>?
    private var suppressQuickActionsUntilExit = false
    private(set) var quickActionsExpanded = false
    private var activity = DesktopPetActivity()
    private var playback: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private var dismissBubble: Task<Void, Never>?
    private var importantBubble = false
    private var direction = "right"
    private var idleClipIndex = 0
    private var touchIndex = 0
    private var lastTouchTime = -Double.infinity
    private lazy var chirp = NSSound(data: Self.chirpData())
    private var interacting = false
    private var positioned = false
    private var menuSourcePID: pid_t?
    private(set) var isEnabled: Bool
    private(set) var sizeScale: CGFloat = 1
    private(set) var soundEnabled: Bool
    private(set) var isPresented = false
    private(set) var message = ""
    var hasScheduledPlayback: Bool { playback != nil || idle != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        soundEnabled = defaults.object(forKey: Self.soundKey) as? Bool ?? true
        resourceURL = Bundle(for: DesktopPetController.self).resourceURL?.appendingPathComponent("DesktopPet")
        clips = resourceURL.flatMap { try? Data(contentsOf: $0.appendingPathComponent("manifest.json")) }
            .flatMap { try? JSONDecoder().decode(Manifest.self, from: $0).clips } ?? []
        super.init()
        petPanel.title = "小胖鸟桌宠"
        petPanel.ignoresMouseEvents = false
        petPanel.acceptsMouseMovedEvents = true
        petPanel.contentView = bird
        bird.autoresizingMask = [.width, .height]
        bird.makeMenu = { [weak self] in self?.makeMenu() }
        bird.petted = { [weak self] in self?.reactToTouch() }
        bird.acceptsDrop = { [weak self] in
            guard let self else { return false }
            return isPresented && onDrop != nil && canReceiveDrop?() != false
        }
        bird.dropHover = { [weak self] hovering in
            guard let self, isPresented else { return }
            if hovering {
                setQuickActionsVisible(false, animated: false)
                show("交给我吧", detail: "松手后选择用途，不会自动保存")
                play("receive")
            } else {
                dismissBubble?.cancel()
                bubblePanel.orderOut(nil)
                message = ""
                resumeAfterInteraction()
            }
        }
        bird.dropped = { [weak self] board in
            guard let self, isPresented, canReceiveDrop?() != false else { return false }
            do {
                let drop = try DesktopPetDrop.read(from: board)
                dismissBubble?.cancel()
                bubblePanel.orderOut(nil)
                message = ""
                play("receive")
                playChirp()
                DispatchQueue.main.async { [weak self] in
                    guard let self, isPresented else { return }
                    onDrop?(drop)
                }
                return true
            } catch {
                show("这次没接住", detail: error.localizedDescription)
                play("attention")
                return false
            }
        }
        bird.registerForDraggedTypes(DesktopPetDrop.types)
        bird.dragStarted = { [weak self] in self?.pauseForInteraction() }
        bird.dragged = { [weak self] origin in self?.move(to: origin, save: false) }
        bird.dragEnded = { [weak self] in
            guard let self else { return }
            move(to: petPanel.frame.origin, save: true)
            resumeAfterInteraction()
        }
        bird.imageScaling = .scaleProportionallyUpOrDown
        configureQuickActions()
        bird.setAccessibilityElement(true)
        bird.setAccessibilityRole(.button)
        bird.setAccessibilityLabel("小胖鸟桌宠")
        bird.setAccessibilityHelp("靠近小鸟可展开语音、便签和 AI 设置；点击摸摸头，拖动可移动，右键也可打开所有功能")
        let bubble = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 54))
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 11
        bubble.layer?.borderWidth = 0.5
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.frame = NSRect(x: 12, y: 29, width: 186, height: 16)
        detailLabel.font = .systemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x: 12, y: 10, width: 186, height: 14)
        for field in [label, detailLabel] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            bubble.addSubview(field)
        }
        bubblePanel.contentView = bubble
        bubblePanel.title = "小胖鸟状态"
        bubblePanel.hasShadow = true
        NotificationCenter.default.addObserver(self, selector: #selector(reposition), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(motionChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        setScale(CGFloat(defaults.object(forKey: Self.scaleKey) as? Double ?? 1))
    }

    func start() { setVisible(isEnabled) }

    isolated deinit {
        if let globalHoverMonitor { NSEvent.removeMonitor(globalHoverMonitor) }
        if let localHoverMonitor { NSEvent.removeMonitor(localHoverMonitor) }
        quickActionsDismissTask?.cancel()
        quickActionsFadeTask?.cancel()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        setVisible(enabled)
    }

    func setVisible(_ visible: Bool) {
        guard visible, isEnabled, !clips.isEmpty else {
            isPresented = false
            suppressQuickActionsUntilExit = false
            removeHoverMonitors()
            setQuickActionsVisible(false, animated: false)
            stopPlayback()
            dismissBubble?.cancel()
            dismissBubble = nil
            message = ""
            chirp?.stop()
            onHidden?()
            petPanel.orderOut(nil)
            bubblePanel.orderOut(nil)
            return
        }
        guard !isPresented else { reposition(); return }
        isPresented = true
        reposition()
        startHoverMonitors()
        petPanel.orderFrontRegardless()
        if let task = activity.current {
            show(task.message, detail: task.detail, transient: false)
            play("working", loop: true)
        } else {
            show("我在这里", detail: "点我摸摸头，也可以把素材拖给我")
            play("greeting")
        }
    }

    @discardableResult func begin(id: UUID = UUID(), message: String, detail: String) -> UUID {
        activity.begin(id, message: message, detail: detail)
        if isPresented && !interacting {
            show(message, detail: detail, transient: false)
            play("working", loop: true)
        }
        return id
    }

    func finish(_ id: UUID, message: String = "完成啦", detail: String = "可在对应面板查看", clip: String = "complete") {
        guard activity.finish(id), isPresented, !interacting else { return }
        if let task = activity.current {
            show(task.message, detail: task.detail, transient: false)
            play("working", loop: true)
        } else {
            show(message, detail: detail, important: true)
            play(clip)
        }
    }

    func received() {
        notify("收好啦", detail: "内容已导入便签", clip: "receive")
    }

    func notify(_ message: String, detail: String, clip: String = "attention") {
        guard isPresented, !interacting, activity.current == nil else { return }
        show(message, detail: detail, important: true)
        play(clip)
    }

    func reactToTouch() {
        let now = ProcessInfo.processInfo.systemUptime
        guard isPresented, !interacting, !dropPreviewPresented, now - lastTouchTime >= 1 else { return }
        lastTouchTime = now
        let reactions = [("嘿，我在呢", "greeting"), ("摸摸头，心情变好了", "idle_look"), ("有你陪着真好", "complete")]
        let reaction = reactions[touchIndex % reactions.count]
        touchIndex += 1
        if activity.current == nil { show(reaction.0, detail: "拖入素材我能帮你收好", important: true) }
        play(reaction.1)
        playChirp()
    }

    func setSoundEnabled(_ enabled: Bool) {
        soundEnabled = enabled
        defaults.set(enabled, forKey: Self.soundKey)
        if !enabled { chirp?.stop() }
    }

    private func playChirp() {
        guard soundEnabled, !audioFeedbackSuppressed, chirp?.isPlaying != true else { return }
        chirp?.volume = 0.35
        chirp?.play()
    }

    // Local, enveloped two-note whistle. No downloaded sound or idle-time audio.
    static func chirpData() -> Data {
        let sampleRate = 22_050
        let count = sampleRate * 2 / 5
        var samples = Data(capacity: count * 2)
        var phase = 0.0
        for index in 0..<count {
            let time = Double(index) / Double(sampleRate)
            let start = time < 0.18 ? 0.02 : 0.22
            let local = time - start
            let duration = 0.13
            var value = Int16(0)
            if local >= 0, local < duration {
                let progress = local / duration
                let frequency = (start < 0.1 ? 1800.0 : 2200.0) + 650 * sin(progress * .pi)
                phase += 2 * .pi * frequency / Double(sampleRate)
                value = Int16(9000 * pow(sin(progress * .pi), 2) * sin(phase))
            }
            var sample = value.littleEndian
            withUnsafeBytes(of: &sample) { samples.append(contentsOf: $0) }
        }
        var data = Data("RIFF".utf8)
        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + samples.count))
        data.append(Data("WAVEfmt ".utf8))
        append(16)
        data.append(contentsOf: [1, 0, 1, 0]) // PCM, mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        data.append(contentsOf: [2, 0, 16, 0])
        data.append(Data("data".utf8))
        append(UInt32(samples.count))
        data.append(samples)
        return data
    }

    func stop() {
        setVisible(false)
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func image(clip: String, direction: String, frame: Int) -> NSImage? {
        let path = "frames/\(direction)/\(clip)/\(String(format: "%02d", frame)).png"
        if let cached = images[path] { return cached }
        guard let url = resourceURL?.appendingPathComponent(path), let image = NSImage(contentsOf: url) else { return nil }
        images[path] = image
        return image
    }

    private func show(_ text: String, detail: String, transient: Bool = true, important: Bool = false) {
        dismissBubble?.cancel()
        importantBubble = important || !transient
        message = text
        label.stringValue = text
        detailLabel.stringValue = detail
        detailLabel.toolTip = detail
        detailLabel.setAccessibilityLabel(detail)
        bird.setAccessibilityLabel("小胖鸟：\(text)，\(detail)")
        if dropPreviewPresented {
            bubblePanel.orderOut(nil)
        } else {
            reposition()
            bubblePanel.orderFrontRegardless()
            NSAccessibility.post(element: label, notification: .valueChanged)
        }
        guard transient else { return }
        dismissBubble = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            message = ""
            importantBubble = false
            bubblePanel.orderOut(nil)
            bird.setAccessibilityLabel("小胖鸟桌宠")
            dismissBubble = nil
        }
    }

    private func play(_ name: String, loop: Bool = false) {
        stopPlayback()
        guard isPresented, !interacting else { return }
        reposition()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let clip = clips.first(where: { $0.id == name }) else {
            bird.image = image(clip: "greeting", direction: direction, frame: 0)
            return
        }
        let isIdle = name.hasPrefix("idle_")
        // Capture only weak self across sleeps, so closing the companion releases its work.
        playback = Task { @MainActor [weak self] in
            repeat {
                let facing = self?.facingDirection() ?? "right"
                for (frame, milliseconds) in clip.frameDurationsMs.enumerated() {
                    guard !Task.isCancelled, self?.isPresented == true else { return }
                    self?.bird.image = self?.image(clip: name, direction: facing, frame: frame)
                    // Asset previews contain long neutral holds; the desktop scheduler owns those pauses.
                    let duration = isIdle && (frame == 0 || frame == clip.frameDurationsMs.count - 1)
                        ? min(milliseconds, 200) : milliseconds
                    try? await Task.sleep(for: .milliseconds(duration))
                }
            } while loop && !Task.isCancelled && self?.isPresented == true
            guard !Task.isCancelled, let self else { return }
            playback = nil
            reposition()
            bird.image = image(clip: "greeting", direction: direction, frame: 0)
            if let task = activity.current {
                show(task.message, detail: task.detail, transient: false)
                play("working", loop: true)
            } else {
                scheduleIdle()
            }
        }
    }

    private func stopPlayback() {
        playback?.cancel()
        idle?.cancel()
        playback = nil
        idle = nil
    }

    private func scheduleIdle() {
        idle?.cancel()
        guard isPresented, !interacting, activity.current == nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        idle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double.random(in: Self.idlePauseSeconds)))
            guard !Task.isCancelled, let self, isPresented, activity.current == nil else { return }
            // Rotate visible body gestures with blinks; repeated tiny blinks look frozen at desktop scale.
            let names = ["idle_look", "idle_blink", "idle_stretch"]
            let name = names[idleClipIndex]
            idleClipIndex = (idleClipIndex + 1) % names.count
            play(name)
        }
    }

    private func pauseForInteraction() {
        interacting = true
        setQuickActionsVisible(false, animated: false)
        stopPlayback()
        bird.image = image(clip: "greeting", direction: direction, frame: 0)
        bubblePanel.orderOut(nil)
    }

    private func resumeAfterInteraction() {
        interacting = false
        stopPlayback()
        guard isPresented else { return }
        if let task = activity.current {
            show(task.message, detail: task.detail, transient: false)
            play("working", loop: true)
        } else {
            bird.image = image(clip: "greeting", direction: facingDirection(), frame: 0)
            scheduleIdle()
        }
    }

    func dropPreviewClosed() {
        dropPreviewPresented = false
        guard isPresented, !interacting else { return }
        if let task = activity.current { show(task.message, detail: task.detail, transient: false) }
        else if !importantBubble {
            dismissBubble?.cancel()
            bubblePanel.orderOut(nil)
            message = ""
        }
    }

    func makeMenu() -> NSMenu {
        menuSourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let menu = NSMenu()
        menu.delegate = self
        for action in Action.allCases {
            let item = menu.addItem(withTitle: action.title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.tag = action.rawValue
            item.target = self
        }
        menu.addItem(.separator())
        let sizes = NSMenu(title: "桌宠大小")
        for (percent, title) in [(50, "缩小 50%"), (100, "标准大小"), (150, "放大 50%（上限）")] {
            let item = sizes.addItem(withTitle: title, action: #selector(resizeFromMenu(_:)), keyEquivalent: "")
            item.tag = percent
            item.target = self
            item.state = abs(sizeScale * 100 - CGFloat(percent)) < 0.01 ? .on : .off
        }
        menu.addItem(withTitle: sizes.title, action: nil, keyEquivalent: "").submenu = sizes
        let sound = menu.addItem(withTitle: "互动音效", action: #selector(toggleSound), keyEquivalent: "")
        sound.state = soundEnabled ? .on : .off
        sound.target = self
        let hide = menu.addItem(withTitle: "隐藏桌宠", action: #selector(hideFromMenu), keyEquivalent: "")
        hide.target = self
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { pauseForInteraction() }
    func menuDidClose(_ menu: NSMenu) { resumeAfterInteraction() }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let action = Action(rawValue: sender.tag) else { return }
        let pid = menuSourcePID
        // Leave menu tracking before opening another panel or requesting permissions.
        DispatchQueue.main.async { [weak self] in self?.onAction?(action, pid) }
    }

    @objc private func hideFromMenu() { setEnabled(false) }
    @objc private func toggleSound() { setSoundEnabled(!soundEnabled) }

    @objc private func resizeFromMenu(_ sender: NSMenuItem) {
        setScale(CGFloat(sender.tag) / 100)
    }

    func setScale(_ proposed: CGFloat) {
        guard proposed.isFinite else { return }
        setQuickActionsVisible(false, animated: false)
        sizeScale = min(max(proposed, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        let oldFrame = petPanel.frame
        let side = Self.canvasSide * sizeScale
        petPanel.setContentSize(NSSize(width: side, height: side))
        if positioned {
            // Keep the bottom centre stable, then clamp the larger canvas to the display.
            move(to: NSPoint(x: oldFrame.midX - side / 2, y: oldFrame.minY), save: true)
        }
        defaults.set(Double(sizeScale), forKey: Self.scaleKey)
    }

    func move(to origin: NSPoint, save: Bool) {
        guard origin.x.isFinite, origin.y.isFinite else { return }
        let proposed = NSRect(origin: origin, size: petPanel.frame.size)
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard let screen = Self.closestScreen(to: proposed, screens: screens) else { return }
        petPanel.setFrame(Self.clamped(proposed, in: screen), display: true)
        positioned = true
        repositionBubble(in: screen)
        positionQuickActions(in: screen)
        if save { defaults.set([petPanel.frame.minX, petPanel.frame.minY], forKey: Self.positionKey) }
    }

    private func facingDirection() -> String {
        let delta = NSEvent.mouseLocation.x - petPanel.frame.midX
        if abs(delta) > 24 { direction = delta > 0 ? "right" : "left" }
        return direction
    }

    @objc private func motionChanged() {
        guard isPresented else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            updateQuickButtonAppearance(animated: false)
        }
        play(activity.current == nil ? "greeting" : "working", loop: activity.current != nil)
    }

    @objc private func reposition() {
        if !positioned {
            let saved = defaults.array(forKey: Self.positionKey) as? [Double]
            if let saved, saved.count == 2, saved.allSatisfy(\.isFinite) {
                move(to: NSPoint(x: saved[0], y: saved[1]), save: false)
            } else if let screen = NSScreen.main?.visibleFrame {
                move(to: NSPoint(x: screen.maxX - petPanel.frame.width - 28, y: screen.minY + 24), save: false)
            }
        } else {
            move(to: petPanel.frame.origin, save: false)
        }
    }

    private func repositionBubble(in screen: NSRect) {
        let anchor = quickActionsExpanded ? petPanel.frame.union(quickActionsPanel.frame) : petPanel.frame
        bubblePanel.setFrame(Self.bubbleFrame(near: anchor, in: screen), display: true)
        let theme = NoteTheme.resolved(from: defaults.string(forKey: "appearance.noteTheme") ?? NoteTheme.system.rawValue)
        bubblePanel.appearance = theme.colorScheme == .dark ? NSAppearance(named: .darkAqua)
            : (theme.colorScheme == .light ? NSAppearance(named: .aqua) : nil)
        label.textColor = theme.textColor
        bubblePanel.contentView?.effectiveAppearance.performAsCurrentDrawingAppearance {
            bubblePanel.contentView?.layer?.backgroundColor = theme.toolbarBackground.cgColor
            bubblePanel.contentView?.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    private func configureQuickActions() {
        quickActionsPanel.title = "小胖鸟快捷入口"
        quickActionsPanel.acceptsMouseMovedEvents = true
        let content = NSView(frame: NSRect(origin: .zero, size: Self.quickActionSize))
        content.wantsLayer = true
        content.layer?.opacity = 0
        quickActionsPanel.contentView = content
        for (action, symbol, label) in [(Action.voice, "mic", "语音便签"), (.openNote, "note.text", "打开便签"), (.settings, "gearshape", "AI 设置")] {
            let button = DesktopPetQuickButton(frame: NSRect(x: 0, y: 10, width: 36, height: 36))
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.wantsLayer = true
            button.contentTintColor = .labelColor
            button.tag = action.rawValue
            button.target = self
            button.action = #selector(performQuickAction(_:))
            button.toolTip = label
            button.setAccessibilityLabel(label)
            content.addSubview(button)
            quickButtons.append(button)
        }
    }

    private func startHoverMonitors() {
        removeHoverMonitors()
        globalHoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateQuickActions(at: NSEvent.mouseLocation, pointerIsDown: NSEvent.pressedMouseButtons != 0)
            }
        }
        localHoverMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.updateQuickActions(at: NSEvent.mouseLocation, pointerIsDown: NSEvent.pressedMouseButtons != 0)
            return event
        }
    }

    private func removeHoverMonitors() {
        if let globalHoverMonitor { NSEvent.removeMonitor(globalHoverMonitor) }
        if let localHoverMonitor { NSEvent.removeMonitor(localHoverMonitor) }
        globalHoverMonitor = nil
        localHoverMonitor = nil
    }

    /// Hit testing uses stationary screen-space frames, never a moving sprite or animated button.
    func updateQuickActions(at pointer: NSPoint, pointerIsDown: Bool = false) {
        guard isPresented, !interacting, !pointerIsDown, !quickActionsSuppressed else {
            setQuickActionsVisible(false, animated: false)
            return
        }
        let nearBird = petPanel.frame.insetBy(dx: -10, dy: -10).contains(pointer)
        let corridor = petPanel.frame.union(quickActionsPanel.frame).insetBy(dx: -12, dy: -12)
        if suppressQuickActionsUntilExit {
            if !corridor.contains(pointer) { suppressQuickActionsUntilExit = false }
            return
        }
        if nearBird || (quickActionsPanel.isVisible && corridor.contains(pointer)) {
            quickActionsDismissTask?.cancel()
            quickActionsDismissTask = nil
            setQuickActionsVisible(true)
            let local = NSPoint(x: pointer.x - quickActionsPanel.frame.minX, y: pointer.y - quickActionsPanel.frame.minY)
            let closest = quickButtons.indices.min {
                hypot(local.x - quickButtons[$0].frame.midX, local.y - quickButtons[$0].frame.midY)
                    < hypot(local.x - quickButtons[$1].frame.midX, local.y - quickButtons[$1].frame.midY)
            }
            let focused = closest.flatMap { index in
                hypot(local.x - quickButtons[index].frame.midX, local.y - quickButtons[index].frame.midY) <= 23 ? index : nil
            }
            // The tighter arc overlaps transparent sprite padding. Only buttons intercept the pointer.
            quickActionsPanel.ignoresMouseEvents = focused == nil
            if focused != focusedQuickAction {
                focusedQuickAction = focused
                updateQuickButtonAppearance()
            }
        } else if quickActionsExpanded && quickActionsDismissTask == nil {
            focusedQuickAction = nil
            updateQuickButtonAppearance()
            quickActionsDismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.quickActionsCloseDelay))
                guard !Task.isCancelled, let self else { return }
                quickActionsDismissTask = nil
                setQuickActionsVisible(false)
            }
        }
    }

    private func setQuickActionsVisible(_ visible: Bool, animated: Bool = true) {
        if !visible {
            quickActionsDismissTask?.cancel()
            quickActionsDismissTask = nil
        }
        guard visible != quickActionsExpanded || !animated else { return }
        quickActionsFadeTask?.cancel()
        quickActionsFadeTask = nil
        quickActionsExpanded = visible
        if isPresented && !interacting && !dropPreviewPresented && !message.isEmpty {
            reposition()
            bubblePanel.orderFrontRegardless()
        }
        focusedQuickAction = nil
        quickActionsPanel.ignoresMouseEvents = !visible
        quickButtons.forEach { $0.isEnabled = visible }
        if visible && !quickActionsPanel.isVisible {
            quickButtons.forEach { $0.present(expanded: false, focused: false, dimmed: false, animated: false) }
            quickActionsPanel.contentView?.layer?.opacity = 1
            quickActionsPanel.orderFrontRegardless()
        }
        updateQuickButtonAppearance(animated: animated)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if !visible { quickActionsPanel.orderOut(nil) }
            return
        }
        if !visible {
            quickActionsFadeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(0.16))
                guard !Task.isCancelled, let self, !quickActionsExpanded else { return }
                quickActionsPanel.orderOut(nil)
                quickActionsFadeTask = nil
            }
        }
    }

    private func updateQuickButtonAppearance(animated: Bool = true) {
        for (index, button) in quickButtons.enumerated() {
            button.present(expanded: quickActionsExpanded, focused: focusedQuickAction == index,
                           dimmed: focusedQuickAction != nil && focusedQuickAction != index, animated: animated)
        }
    }

    @objc private func performQuickAction(_ sender: NSButton) {
        guard quickActionsExpanded, let action = Action(rawValue: sender.tag) else { return }
        let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        suppressQuickActionsUntilExit = true
        setQuickActionsVisible(false)
        onAction?(action, sourcePID)
    }

    private func positionQuickActions(in screen: NSRect) {
        let frames = Self.quickActionFrames(near: petPanel.frame, in: screen)
        let frame = frames.reduce(NSRect.null) { $0.union($1) }.insetBy(dx: -8, dy: -8)
        if quickActionsPanel.frame != frame { quickActionsPanel.setFrame(frame, display: true) }
        for (index, button) in quickButtons.enumerated() {
            let origin = NSPoint(x: frames[index].minX - frame.minX, y: frames[index].minY - frame.minY)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
            let dx = petPanel.frame.midX - frames[index].midX
            let dy = petPanel.frame.midY - frames[index].midY
            let distance = max(hypot(dx, dy), 1)
            button.revealOffset = NSPoint(x: dx / distance * 14, y: dy / distance * 14)
        }
    }

    static func quickActionsFrame(near pet: NSRect, in screen: NSRect) -> NSRect {
        quickActionFrames(near: pet, in: screen).reduce(NSRect.null) { $0.union($1) }.insetBy(dx: -8, dy: -8)
    }

    static func quickActionFrames(near pet: NSRect, in screen: NSRect) -> [NSRect] {
        // Assets include transparent margins; anchor to the body, not the full canvas edge.
        let radius = max(58, pet.width * 0.36 + 22)
        let angle = asin(40 / radius)
        let side: CGFloat = pet.midX + radius + 26 <= screen.maxX ? 1 : -1
        let frames = [angle, 0, -angle].map { theta in
            NSRect(x: pet.midX + side * radius * cos(theta) - 18,
                   y: pet.midY + radius * sin(theta) - 18, width: 36, height: 36)
        }
        let bounds = frames.reduce(NSRect.null) { $0.union($1) }.insetBy(dx: -8, dy: -8)
        let fitted = clamped(bounds, in: screen)
        return frames.map { $0.offsetBy(dx: fitted.minX - bounds.minX, dy: fitted.minY - bounds.minY) }
    }

    static func closestScreen(to rect: NSRect, screens: [NSRect]) -> NSRect? {
        screens.min { a, b in
            func distance(_ screen: NSRect) -> CGFloat {
                let dx = max(screen.minX - rect.midX, rect.midX - screen.maxX, 0)
                let dy = max(screen.minY - rect.midY, rect.midY - screen.maxY, 0)
                return dx * dx + dy * dy
            }
            return distance(a) < distance(b)
        }
    }

    static func bubbleFrame(near pet: NSRect, in screen: NSRect) -> NSRect {
        let y = pet.maxY + 3 + 54 <= screen.maxY ? pet.maxY + 3 : pet.minY - 57
        return clamped(NSRect(x: pet.midX - 105, y: y, width: 210, height: 54), in: screen)
    }

    static func clamped(_ rect: NSRect, in screen: NSRect) -> NSRect {
        NSRect(x: min(max(rect.minX, screen.minX), screen.maxX - rect.width),
               y: min(max(rect.minY, screen.minY), screen.maxY - rect.height),
               width: rect.width, height: rect.height)
    }

    private static func makePanel(size: NSSize) -> NSPanel {
        let panel = DesktopPetPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.canHide = false
        panel.level = .statusBar
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

@MainActor
private final class DesktopPetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class DesktopPetQuickButton: NSButton {
    private var hovered = false
    var revealOffset = NSPoint.zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func present(expanded: Bool, focused: Bool, dimmed: Bool, animated: Bool) {
        hovered = focused
        needsDisplay = true
        guard let layer else { return }
        let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
        let fromTransform = layer.presentation()?.transform ?? layer.transform
        let scale: CGFloat = expanded ? (focused ? 1.14 : 1) : 0.86
        // Scale around the visual centre; the NSButton's frame/hit target stays stationary.
        let anchor = NSPoint(x: bounds.width * layer.anchorPoint.x, y: bounds.height * layer.anchorPoint.y)
        let offset = expanded ? NSPoint.zero : revealOffset
        let transform = CATransform3DScale(CATransform3DMakeTranslation(
            offset.x + (bounds.midX - anchor.x) * (1 - scale),
            offset.y + (bounds.midY - anchor.y) * (1 - scale), 0), scale, scale, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = expanded ? (dimmed ? 0.45 : 1) : 0
        layer.transform = transform
        CATransaction.commit()
        layer.removeAnimation(forKey: "appearance")
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = fromOpacity
        opacity.toValue = layer.opacity
        let movement = CABasicAnimation(keyPath: "transform")
        movement.fromValue = NSValue(caTransform3D: fromTransform)
        movement.toValue = NSValue(caTransform3D: transform)
        let animation = CAAnimationGroup()
        animation.animations = [opacity, movement]
        animation.duration = expanded ? 0.22 : 0.16
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        layer.add(animation, forKey: "appearance")
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.shadowColor.withAlphaComponent(0.14)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        if hovered || isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(isHighlighted ? 0.20 : 0.10).setFill()
            circle.fill()
        }
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
        super.draw(dirtyRect)
    }
}

@MainActor
private final class DesktopPetImageView: NSImageView {
    var makeMenu: (() -> NSMenu?)?
    var petted: (() -> Void)?
    var acceptsDrop: (() -> Bool)?
    var dropHover: ((Bool) -> Void)?
    var dropped: ((NSPasteboard) -> Bool)?
    private var hoveringDrop = false
    var dragStarted: (() -> Void)?
    var dragged: ((NSPoint) -> Void)?
    var dragEnded: (() -> Void)?
    private var startPointer = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        startPointer = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let pointer = NSEvent.mouseLocation
        let delta = NSPoint(x: pointer.x - startPointer.x, y: pointer.y - startPointer.y)
        guard isDragging || hypot(delta.x, delta.y) >= 3 else { return }
        if !isDragging { isDragging = true; dragStarted?() }
        dragged?(NSPoint(x: startOrigin.x + delta.x, y: startOrigin.y + delta.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard !event.modifierFlags.contains(.control) else { return }
        if isDragging { dragEnded?() } else { petted?() }
        isDragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let petted else { return false }
        petted()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = makeMenu?() else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
        return true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop?() == true, sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.availableType(from: DesktopPetDrop.types) != nil else { return [] }
        hoveringDrop = true
        dropHover?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        hoveringDrop && acceptsDrop?() == true ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if hoveringDrop { dropHover?(false) }
        hoveringDrop = false
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { hoveringDrop && acceptsDrop?() == true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard hoveringDrop else { return false }
        hoveringDrop = false
        return dropped?(sender.draggingPasteboard) ?? false
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { hoveringDrop = false }
}
