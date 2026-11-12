import AppKit
import QuartzCore

struct SelectionDropdownPlacement {
    let frame: NSRect
    let opensDown: Bool

    static func make(toolbar: NSRect, anchor: NSRect, viewport: NSRect,
                     desiredSize: NSSize = NSSize(width: 128, height: 152)) -> Self? {
        let bounds = viewport.insetBy(dx: 4, dy: 4)
        let below = max(0, toolbar.minY - 6 - bounds.minY)
        let above = max(0, bounds.maxY - toolbar.maxY - 6)
        let down = below >= desiredSize.height || below >= above
        let height = min(desiredSize.height, down ? below : above)
        guard height >= 40, bounds.width >= desiredSize.width else { return nil }
        let x = min(max(anchor.minX, bounds.minX), bounds.maxX - desiredSize.width)
        return Self(frame: NSRect(x: x, y: down ? toolbar.minY - 6 - height : toolbar.maxY + 6,
                                 width: desiredSize.width, height: height), opensDown: down)
    }
}

enum SelectionDropdownMotion {
    static func duration(opening: Bool, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : (opening ? 0.18 : 0.12)
    }
}

/// A positioned list, not an NSMenu that aligns its selected row over the source button.
@MainActor
final class SelectionStyleDropdown {
    let window: NSPanel
    private let scroll = NSScrollView()
    private let list = SelectionStyleList()
    private var rows: [SelectionStyleRow] = []
    private let onChoose: (EditorTextStyle) -> Void
    private let onExpansionChange: (Bool) -> Void
    private let reduceMotion: @MainActor () -> Bool
    private var generation = 0
    private var navigationIndex = 0
    private(set) var isExpanded = false

    init(reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         onExpansionChange: @escaping (Bool) -> Void = { _ in },
         onChoose: @escaping (EditorTextStyle) -> Void) {
        self.reduceMotion = reduceMotion
        self.onChoose = onChoose
        self.onExpansionChange = onExpansionChange
        window = SelectionFormatPanel(contentRect: NSRect(x: 0, y: 0, width: 128, height: 152),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("quicknote.selection-styles")
        window.setAccessibilityLabel("文字样式选项")
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.animationBehavior = .none
        let content = SelectionFormatBackground(frame: NSRect(x: 0, y: 0, width: 128, height: 152))
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        window.contentView = content
        scroll.frame = content.bounds.insetBy(dx: 6, dy: 6)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        list.frame = NSRect(x: 0, y: 0, width: 116, height: 140)
        scroll.documentView = list
        content.addSubview(scroll)
        for (index, style) in EditorTextStyle.allCases.enumerated() {
            let row = SelectionStyleRow(style: style, reduceMotion: reduceMotion)
            row.frame = NSRect(x: 0, y: CGFloat(index * 28), width: 116, height: 28)
            row.onPress = { [weak self] in self?.choose(index) }
            row.onHover = { [weak self] in
                self?.navigationIndex = index
                self?.rows.forEach { $0.keyboardHighlighted = false }
            }
            list.addSubview(row)
            rows.append(row)
        }
    }

    func updateSelection(_ style: EditorTextStyle?) {
        for (row, candidate) in zip(rows, EditorTextStyle.allCases) { row.setCurrent(candidate == style) }
    }

    func show(parent: NSWindow, anchor: NSRect, viewport: NSRect, selected: EditorTextStyle?) {
        guard let placement = SelectionDropdownPlacement.make(toolbar: parent.frame, anchor: anchor, viewport: viewport) else {
            hide(); return
        }
        generation += 1
        isExpanded = true
        onExpansionChange(true)
        updateSelection(selected)
        navigationIndex = selected.flatMap { EditorTextStyle.allCases.firstIndex(of: $0) } ?? 0
        rows.forEach { $0.keyboardHighlighted = false }
        window.ignoresMouseEvents = false
        window.appearance = parent.effectiveAppearance
        window.setFrame(placement.frame, display: true)
        list.frame.size.width = scroll.contentSize.width
        rows.forEach { $0.frame.size.width = list.frame.width }
        scroll.contentView.scroll(to: .zero)
        if window.parent !== parent {
            window.parent?.removeChildWindow(window)
            parent.addChildWindow(window, ordered: .above)
        }
        let duration = SelectionDropdownMotion.duration(opening: true, reduceMotion: reduceMotion())
        revealContent(placement: placement, duration: duration)
        window.alphaValue = duration == 0 ? 1 : 0
        window.orderFront(nil)
        if duration > 0 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
                window.animator().alphaValue = 1
            }
        }
    }

    func hide(animated: Bool = false) {
        generation += 1
        let closingGeneration = generation
        isExpanded = false
        onExpansionChange(false)
        window.ignoresMouseEvents = true
        let duration = SelectionDropdownMotion.duration(opening: false, reduceMotion: reduceMotion())
        guard animated, window.isVisible, duration > 0 else { finishHiding(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == closingGeneration, !self.isExpanded else { return }
                self.finishHiding()
            }
        }
    }

    func handleKey(_ code: UInt16) -> Bool {
        guard isExpanded else { return false }
        switch code {
        case 53: hide(animated: true)
        case 36, 76: choose(navigationIndex)
        case 125, 126:
            navigationIndex = min(max(navigationIndex + (code == 125 ? 1 : -1), 0), rows.count - 1)
            for (index, row) in rows.enumerated() { row.keyboardHighlighted = index == navigationIndex }
            rows[navigationIndex].scrollToVisible(rows[navigationIndex].bounds)
        default: return false
        }
        return true
    }

    private func choose(_ index: Int) {
        guard isExpanded, EditorTextStyle.allCases.indices.contains(index) else { return }
        hide(animated: true)
        onChoose(EditorTextStyle.allCases[index])
    }

    private func finishHiding() {
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        window.alphaValue = 1
        window.contentView?.layer?.mask = nil
    }

    private func revealContent(placement: SelectionDropdownPlacement, duration: TimeInterval) {
        guard let layer = window.contentView?.layer else { return }
        layer.mask = nil
        guard duration > 0 else { return }
        let mask = CAShapeLayer()
        mask.frame = layer.bounds
        mask.isGeometryFlipped = layer.isGeometryFlipped
        let y = placement.opensDown == layer.isGeometryFlipped ? 0 : layer.bounds.height - 2
        let start = CGPath(rect: CGRect(x: 0, y: y, width: layer.bounds.width, height: 2), transform: nil)
        let finish = CGPath(rect: layer.bounds, transform: nil)
        mask.path = finish
        layer.mask = mask
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = start
        animation.toValue = finish
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        mask.add(animation, forKey: "selection.dropdown.reveal")
    }
}

private final class SelectionStyleList: NSView {
    override var isFlipped: Bool { true }
}

private final class SelectionStyleRow: NSButton {
    var onPress: (() -> Void)?
    var onHover: (() -> Void)?
    var keyboardHighlighted = false { didSet { updateBackground(animated: true) } }
    private var hovering = false
    private var hoverTracking: NSTrackingArea?
    private let style: EditorTextStyle
    private let reduceMotion: @MainActor () -> Bool

    init(style: EditorTextStyle, reduceMotion: @escaping @MainActor () -> Bool) {
        self.style = style
        self.reduceMotion = reduceMotion
        super.init(frame: .zero)
        title = style.title
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityLabel(style.title)
        target = self
        action = #selector(press)
        wantsLayer = true
        layer?.cornerRadius = 5
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }
    override var mouseDownCanMoveWindow: Bool { false }

    func setCurrent(_ current: Bool) {
        state = current ? .on : .off
        setAccessibilityValue(current ? "当前样式" : "")
        updateBackground(animated: false)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        onHover?()
        updateBackground(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateBackground(animated: true)
    }

    private func updateBackground(animated: Bool) {
        guard let layer else { return }
        let highlighted = hovering || keyboardHighlighted
        let color = state == .on
            ? NSColor.controlAccentColor.withAlphaComponent(highlighted ? 0.16 : 0.10)
            : NSColor.labelColor.withAlphaComponent(highlighted ? 0.055 : 0)
        let before = layer.presentation()?.backgroundColor ?? layer.backgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color.cgColor
        CATransaction.commit()
        if animated, !reduceMotion() {
            let animation = CABasicAnimation(keyPath: "backgroundColor")
            animation.fromValue = before
            animation.toValue = color.cgColor
            animation.duration = 0.11
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            layer.add(animation, forKey: "selection.row.hover")
        } else { layer.removeAnimation(forKey: "selection.row.hover") }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let font: NSFont = style == .monospaced ? .monospacedSystemFont(ofSize: 12.5, weight: .regular)
            : .systemFont(ofSize: 13, weight: state == .on ? .medium : .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: 28, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if state == .on {
            NSColor.controlAccentColor.setStroke()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: 9, y: 14))
            check.line(to: NSPoint(x: 12, y: isFlipped ? 17 : 11))
            check.line(to: NSPoint(x: 17, y: isFlipped ? 11 : 17))
            check.lineWidth = 1.5
            check.lineCapStyle = .round
            check.stroke()
        }
    }

    @objc private func press() { onPress?() }
}
