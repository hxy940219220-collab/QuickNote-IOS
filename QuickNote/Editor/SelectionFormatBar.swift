import AppKit

/// Editor-owned presentation only. All document mutations stay in RichTextEditorController.
@MainActor
final class SelectionFormatBar: NSObject {
    private let panel: SelectionFormatPanel
    private let styles = SelectionFormatButton(frame: NSRect(x: 6, y: 3, width: 38, height: 26))
    private var styleDropdown: SelectionStyleDropdown?
    private var buttons: [SelectionFormatButton] = []
    private var fillPanel: SelectionFormatPanel?
    private var swatches: [SelectionFillSwatch] = []
    private let fillColors: [(String, NSColor?)] = [
        ("无填充", nil), ("黄色", .systemYellow.withAlphaComponent(0.28)),
        ("绿色", .systemGreen.withAlphaComponent(0.28)), ("蓝色", .systemBlue.withAlphaComponent(0.28)),
        ("粉色", .systemPink.withAlphaComponent(0.28)), ("紫色", .systemPurple.withAlphaComponent(0.28)),
    ]
    private weak var textView: QuickNoteTextView?
    private weak var controller: RichTextEditorController?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = SelectionFormatPanel(contentRect: NSRect(x: 0, y: 0, width: 192, height: 32),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.identifier = NSUserInterfaceItemIdentifier("quicknote.selection-format")
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Observe the owner's actual deactivation below. NSPanel's automatic hiding
        // can suppress a newly shown nonactivating child while its owner is activating.
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.setAccessibilityLabel("选中文字快捷工具栏")
        let content = SelectionFormatBackground(frame: NSRect(x: 0, y: 0, width: 192, height: 32))
        panel.contentView = content
        styles.font = .systemFont(ofSize: 12)
        styles.isBordered = false
        styles.alignment = .center
        styles.setAccessibilityLabel("文字样式")
        styles.title = "正文"
        styles.setButtonType(.pushOnPushOff)
        styles.target = styles
        styles.action = #selector(SelectionFormatButton.press)
        styles.onPress = { [weak self] in self?.toggleStyleDropdown() }
        content.addSubview(styles)
        let tools = [("粗体", "bold"), ("斜体", "italic"), ("下划线", "underline"),
                     ("背景填充", "highlighter"), ("待办", "checkmark.square")]
        for (index, tool) in tools.enumerated() {
            let button = SelectionFormatButton(frame: NSRect(x: CGFloat(48 + index * 28), y: 3, width: 26, height: 26))
            button.image = NSImage(systemSymbolName: tool.1, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.setButtonType(.pushOnPushOff)
            button.allowsMixedState = true
            button.setAccessibilityLabel(tool.0)
            button.toolTip = tool.0
            button.target = button
            button.action = #selector(SelectionFormatButton.press)
            button.onPress = { [weak self] in self?.performTool(index) }
            content.addSubview(button)
            buttons.append(button)
        }
    }

    func show(for text: QuickNoteTextView, controller: RichTextEditorController) {
        // QuickNote also edits in an NSPanel: first responder, not key-window status,
        // identifies the editor that owns this completed user selection.
        guard let owner = text.window, owner.isVisible, owner.firstResponder === text,
              !text.hasMarkedText(), text.selectedRange().length > 0,
              NSMaxRange(text.selectedRange()) <= text.string.utf16.count else { dismiss(); return }
        if panel.parent !== owner { dismiss() }
        textView = text
        self.controller = controller
        refreshControls(controller.selectionState)
        let selection = text.selectedRange()
        let anchor = text.firstRect(forCharacterRange: selection, actualRange: nil)
        let viewport = owner.convertToScreen(text.convert(text.visibleRect, to: nil))
            .intersection(owner.screen?.visibleFrame ?? owner.frame)
        guard anchor.intersects(viewport), viewport.width >= panel.frame.width,
              viewport.height >= panel.frame.height + 12 else { dismiss(); return }
        let size = panel.frame.size
        let x = min(max(anchor.midX - size.width / 2, viewport.minX + 4), viewport.maxX - size.width - 4)
        let preferredY = anchor.maxY + 6
        let y = preferredY + size.height <= viewport.maxY - 4 ? preferredY : anchor.minY - size.height - 6
        let frame = NSRect(x: x, y: min(max(y, viewport.minY + 4), viewport.maxY - size.height - 4),
            width: size.width, height: size.height)
        panel.appearance = text.effectiveAppearance
        panel.setFrame(frame, display: true)
        if panel.parent == nil {
            owner.addChildWindow(panel, ordered: .above)
            installDismissalObservers(owner: owner, text: text)
        }
        panel.orderFront(nil)
    }

    func refreshControls(_ state: EditorSelectionState) {
        styles.title = state.textStyle?.title ?? "混合样式"
        styles.state = styleDropdown?.isExpanded == true ? .on : .off
        styleDropdown?.updateSelection(state.textStyle)
        for (button, value) in zip(buttons, [state.bold, state.italic, state.underline]) {
            button.state = value == .on ? .on : (value == .mixed ? .mixed : .off)
            button.contentTintColor = value == .off ? .labelColor : .controlAccentColor
        }
        buttons[3].state = highlightState()
        if fillPanel?.isVisible == true { buttons[3].state = .on }
        buttons[3].fillIndicatorColor = currentFillColor()
        buttons[3].contentTintColor = buttons[3].state == .off ? .labelColor : .controlAccentColor
        buttons[4].state = state.checklist == .on ? .on : (state.checklist == .mixed ? .mixed : .off)
        buttons[4].contentTintColor = state.checklist == .off ? .labelColor : .controlAccentColor
        let titleWidth = ceil((styles.title as NSString).size(withAttributes: [.font: styles.font ?? .systemFont(ofSize: 12)]).width)
        styles.frame.size.width = min(66, max(38, titleWidth + 12))
        var x = styles.frame.maxX + 4
        for button in buttons {
            button.frame = NSRect(x: x, y: 3, width: 26, height: 26)
            x += 28
        }
        panel.setContentSize(NSSize(width: x + 4, height: 32))
    }

    private func highlightState() -> NSControl.StateValue {
        guard let textView, let storage = textView.textStorage,
              textView.selectedRange().length > 0 else { return .off }
        var highlighted = false, unhighlighted = false
        storage.enumerateAttribute(.backgroundColor, in: textView.selectedRange()) { value, _, _ in
            if let color = value as? NSColor, color.alphaComponent > 0 { highlighted = true }
            else { unhighlighted = true }
        }
        return highlighted ? (unhighlighted ? .mixed : .on) : .off
    }

    func dismiss() {
        styleDropdown?.hide()
        dismissFillPalette()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        textView = nil
        controller = nil
    }

    private func toggleStyleDropdown() {
        guard let controller, let textView, let owner = textView.window, panel.isVisible else { return }
        if styleDropdown?.isExpanded == true { styleDropdown?.hide(animated: true); return }
        dismissFillPalette()
        if styleDropdown == nil {
            styleDropdown = SelectionStyleDropdown(onExpansionChange: { [weak self] expanded in
                guard let self else { return }
                self.styles.state = expanded ? .on : .off
                self.styles.setAccessibilityValue("\(self.styles.title)，\(expanded ? "已展开" : "已收起")")
            }, onChoose: { [weak self] in self?.applyStyle($0) })
        }
        let viewport = owner.convertToScreen(textView.convert(textView.visibleRect, to: nil))
            .intersection(owner.screen?.visibleFrame ?? owner.frame)
        styleDropdown?.show(parent: panel, anchor: panel.convertToScreen(styles.frame), viewport: viewport,
                            selected: controller.selectionState.textStyle)
    }

    private func applyStyle(_ style: EditorTextStyle) {
        guard let controller, let textView, textView.selectedRange().length > 0 else { dismiss(); return }
        controller.applyTextStyle(style)
        show(for: textView, controller: controller)
    }

    private func currentFillColor() -> NSColor? {
        guard let textView, let storage = textView.textStorage, textView.selectedRange().length > 0 else { return nil }
        let range = textView.selectedRange()
        let color = storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor
        var uniform = true
        storage.enumerateAttribute(.backgroundColor, in: range) { value, _, _ in
            if !Self.sameColor(color, value as? NSColor) { uniform = false }
        }
        return uniform ? color : nil
    }

    private static func sameColor(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard let a = lhs.usingColorSpace(.sRGB), let b = rhs.usingColorSpace(.sRGB) else { return lhs.isEqual(rhs) }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01 && abs(a.alphaComponent - b.alphaComponent) < 0.01
    }

    private func dismissFillPalette() {
        if let fillPanel {
            fillPanel.parent?.removeChildWindow(fillPanel)
            fillPanel.orderOut(nil)
        }
    }

    private func toggleFillPalette() {
        styleDropdown?.hide()
        if fillPanel?.isVisible == true {
            dismissFillPalette()
            if let controller { refreshControls(controller.selectionState) }
            return
        }
        guard let textView, let owner = textView.window else { return }
        if fillPanel == nil {
            let palette = SelectionFormatPanel(contentRect: NSRect(x: 0, y: 0, width: 168, height: 54),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            palette.identifier = NSUserInterfaceItemIdentifier("quicknote.selection-fill")
            palette.setAccessibilityLabel("背景填充颜色")
            palette.isReleasedWhenClosed = false
            palette.hidesOnDeactivate = false
            palette.isMovable = false
            palette.isOpaque = false
            palette.backgroundColor = .clear
            palette.hasShadow = true
            let content = SelectionFormatBackground(frame: NSRect(x: 0, y: 0, width: 168, height: 54))
            palette.contentView = content
            let title = NSTextField(labelWithString: "背景填充")
            title.font = .systemFont(ofSize: 11)
            title.textColor = .secondaryLabelColor
            title.frame = NSRect(x: 8, y: 34, width: 150, height: 14)
            content.addSubview(title)
            for (index, item) in fillColors.enumerated() {
                let swatch = SelectionFillSwatch(frame: NSRect(x: CGFloat(8 + index * 26), y: 6, width: 22, height: 22))
                swatch.fillColor = item.1
                swatch.isBordered = false
                swatch.setButtonType(.pushOnPushOff)
                swatch.setAccessibilityLabel(item.1 == nil ? item.0 : "背景填充：\(item.0)")
                swatch.toolTip = item.0
                swatch.target = swatch
                swatch.action = #selector(SelectionFillSwatch.press)
                swatch.onPress = { [weak self] in self?.applyFill(index) }
                content.addSubview(swatch)
                swatches.append(swatch)
            }
            fillPanel = palette
        }
        guard let palette = fillPanel else { return }
        let current = currentFillColor()
        for (swatch, item) in zip(swatches, fillColors) {
            let matches = Self.sameColor(item.1, current) && (item.1 != nil || highlightState() == .off)
            swatch.state = matches ? .on : .off
        }
        let viewport = owner.convertToScreen(textView.convert(textView.visibleRect, to: nil))
            .intersection(owner.screen?.visibleFrame ?? owner.frame)
        let anchor = panel.convertToScreen(buttons[3].frame)
        let size = palette.frame.size
        let x = min(max(anchor.midX - size.width / 2, viewport.minX + 4), viewport.maxX - size.width - 4)
        let below = panel.frame.minY - size.height - 4
        let y = below >= viewport.minY + 4 ? below : panel.frame.maxY + 4
        palette.appearance = panel.effectiveAppearance
        palette.setFrameOrigin(NSPoint(x: x, y: min(max(y, viewport.minY + 4), viewport.maxY - size.height - 4)))
        panel.addChildWindow(palette, ordered: .above)
        palette.orderFront(nil)
        buttons[3].state = .on
    }

    private func applyFill(_ index: Int) {
        guard let controller, let textView, textView.selectedRange().length > 0,
              fillColors.indices.contains(index) else { dismiss(); return }
        dismissFillPalette()
        controller.applyBackgroundColor(fillColors[index].1)
        show(for: textView, controller: controller)
    }

    private func performTool(_ index: Int) {
        guard let controller, let textView, textView.selectedRange().length > 0 else { dismiss(); return }
        if index == 3 { toggleFillPalette(); return }
        styleDropdown?.hide()
        dismissFillPalette()
        switch index {
        case 0: controller.toggleBold()
        case 1: controller.toggleItalic()
        case 2: controller.toggleUnderline()
        default: controller.toggleChecklistItemAtSelection()
        }
        show(for: textView, controller: controller)
    }

    private func installDismissalObservers(owner: NSWindow, text: QuickNoteTextView) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self, weak owner] event in
            guard let self, self.panel.isVisible else { return event }
            if event.type == .keyDown, event.window === owner,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               self.styleDropdown?.handleKey(event.keyCode) == true { return nil }
            if let dropdown = self.styleDropdown, event.window === dropdown.window { return event }
            if event.window === self.panel || event.window === self.fillPanel { return event }
            let escape = event.type == .keyDown && event.keyCode == 53 && event.window === owner
            self.dismiss()
            return escape ? nil : event
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMoveNotification,
                     NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            observe(name, object: owner)
        }
        observe(NSApplication.didResignActiveNotification, object: nil)
        if let clip = text.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observe(NSView.boundsDidChangeNotification, object: clip)
        }
    }

    private func observe(_ name: Notification.Name, object: Any?) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dismiss()
            }
        })
    }
}

final class SelectionFormatPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class SelectionFormatButton: NSButton {
    var onPress: (() -> Void)?
    var fillIndicatorColor: NSColor? { didSet { needsDisplay = true } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        if state != .off {
            (fillIndicatorColor ?? NSColor.controlAccentColor.withAlphaComponent(0.12)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
        if let fillIndicatorColor {
            fillIndicatorColor.withAlphaComponent(1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 1, width: bounds.width - 12, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }
    @objc func press() { onPress?() }
}

private final class SelectionFillSwatch: NSButton {
    var onPress: (() -> Void)?
    var fillColor: NSColor?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }
    override var mouseDownCanMoveWindow: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4)
        NSColor.textBackgroundColor.setFill()
        tile.fill()
        fillColor?.setFill()
        if fillColor != nil { tile.fill() }
        (state == .on ? NSColor.controlAccentColor : .separatorColor).setStroke()
        tile.lineWidth = state == .on ? 1.5 : 0.5
        tile.stroke()
        if fillColor == nil {
            NSColor.secondaryLabelColor.setStroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 7, y: 6))
            slash.line(to: NSPoint(x: 15, y: 16))
            slash.lineWidth = 1
            slash.stroke()
        }
    }
    @objc func press() { onPress?() }
}

final class SelectionFormatBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        NSColor.windowBackgroundColor.setFill()
        shape.fill()
        NSColor.separatorColor.setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }
}
