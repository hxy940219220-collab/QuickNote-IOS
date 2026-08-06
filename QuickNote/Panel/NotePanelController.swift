import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class NotePanelController: NSObject, NSWindowDelegate {
    static let editorWidth: CGFloat = 520
    static let drawerWidth: CGFloat = 210
    static let windowStyleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
        .fullSizeContentView,
    ]

    private let panel: NSPanel
    private var previousApp: NSRunningApplication?
    private var transitionPanel: NSPanel?
    private var animationGeneration = 0
    private var hasBeenPositioned = false
    private var drawerOpen = false

    var onDismiss: (() -> Void)?
    var onMiniaturize: (() -> Void)?

    init<Content: View>(rootView: Content) {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: Self.windowStyleMask,
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.delegate = self
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentViewController = NSHostingController(rootView: rootView)
        panel.minSize = NSSize(width: Self.editorWidth, height: 320)
    }

    func show(activate: Bool, on screen: NSScreen) {
        animationGeneration += 1
        transitionPanel?.orderOut(nil)
        transitionPanel = nil

        let targetFrame = Self.presentationFrame(
            current: panel.frame,
            hasBeenPositioned: hasBeenPositioned,
            in: screen.visibleFrame
        )
        hasBeenPositioned = true
        let wasMiniaturized = panel.isMiniaturized
        let shouldAnimate = !panel.isVisible
            && !wasMiniaturized
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(targetFrame, display: true)
        if wasMiniaturized { panel.deminiaturize(nil) }

        if activate {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            focusEditor()
        } else {
            panel.orderFrontRegardless()
        }

        guard shouldAnimate, let transition = makeTransitionPanel() else {
            panel.alphaValue = 1
            return
        }

        let generation = animationGeneration
        panel.alphaValue = 0
        transition.alphaValue = 0.2
        transition.setFrame(Self.collapsedFrame(in: screen.visibleFrame), display: true)
        transition.orderFrontRegardless()
        transitionPanel = transition
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            transition.animator().alphaValue = 1
            transition.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self, weak transition] in
            Task { @MainActor in
                guard let self, let transition else { return }
                transition.orderOut(nil)
                guard self.animationGeneration == generation else { return }
                self.transitionPanel = nil
                self.panel.alphaValue = 1
                if activate { self.panel.makeKey() }
            }
        }
    }

    static func panelFrame(in visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.midX - editorWidth / 2,
            y: visibleFrame.midY - 260,
            width: editorWidth,
            height: 520
        )
    }

    static func presentationFrame(
        current: NSRect,
        hasBeenPositioned: Bool,
        in visibleFrame: NSRect
    ) -> NSRect {
        hasBeenPositioned ? current : panelFrame(in: visibleFrame)
    }

    static func drawerFrame(from current: NSRect, opening: Bool, in visibleFrame: NSRect) -> NSRect {
        let width = max(editorWidth, current.width + (opening ? drawerWidth : -drawerWidth))
        let x = min(max(current.maxX - width, visibleFrame.minX), visibleFrame.maxX - width)
        return NSRect(x: x, y: current.minY, width: width, height: current.height)
    }

    static func windowLevel(isLocked: Bool) -> NSWindow.Level {
        isLocked ? .statusBar : .normal
    }

    static func collapsedFrame(in visibleFrame: NSRect) -> NSRect {
        NSRect(x: visibleFrame.minX + 4, y: visibleFrame.midY - 9, width: 18, height: 18)
    }

    func setDrawerOpen(_ open: Bool) {
        guard drawerOpen != open,
              let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else { return }
        drawerOpen = open
        panel.minSize = NSSize(
            width: Self.editorWidth + (open ? Self.drawerWidth : 0),
            height: panel.minSize.height
        )
        panel.setFrame(
            Self.drawerFrame(from: panel.frame, opening: open, in: visibleFrame),
            display: true,
            animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    func setLocked(_ locked: Bool) {
        panel.level = Self.windowLevel(isLocked: locked)
        if locked { panel.orderFrontRegardless() }
    }

    func hideAndRestoreFocus() {
        CaptureLatencyProbe.cancel()
        animationGeneration += 1
        transitionPanel?.orderOut(nil)
        transitionPanel = nil
        let app = previousApp
        previousApp = nil

        guard panel.isVisible else {
            app?.activate(options: [])
            return
        }
        guard !panel.isMiniaturized,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let screenFrame = panel.screen?.visibleFrame,
              let transition = makeTransitionPanel() else {
            if panel.isMiniaturized { panel.deminiaturize(nil) }
            panel.orderOut(nil)
            panel.alphaValue = 1
            app?.activate(options: [])
            return
        }

        let generation = animationGeneration
        transition.setFrame(panel.frame, display: true)
        transition.orderFrontRegardless()
        transitionPanel = transition
        panel.orderOut(nil)
        app?.activate(options: [])
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            transition.animator().alphaValue = 0
            transition.animator().setFrame(Self.collapsedFrame(in: screenFrame), display: true)
        } completionHandler: { [weak self, weak transition] in
            Task { @MainActor in
                transition?.orderOut(nil)
                guard let self, self.animationGeneration == generation else { return }
                self.transitionPanel = nil
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onDismiss?()
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        onMiniaturize?()
    }

    private func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                CaptureLatencyProbe.cancel()
                return
            }
            guard let content = self.panel.contentView,
                  let editor = self.findTextView(in: content) else {
                CaptureLatencyProbe.cancel()
                return
            }
            if self.panel.makeFirstResponder(editor) {
                CaptureLatencyProbe.end()
            } else {
                CaptureLatencyProbe.cancel()
            }
        }
    }

    private func makeTransitionPanel() -> NSPanel? {
        guard let frameView = panel.contentView?.superview,
              let representation = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            return nil
        }
        frameView.cacheDisplay(in: frameView.bounds, to: representation)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(representation)

        let transition = NSPanel(
            contentRect: panel.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        transition.isOpaque = false
        transition.backgroundColor = .clear
        transition.hasShadow = true
        transition.hidesOnDeactivate = false
        transition.level = panel.level
        transition.collectionBehavior = panel.collectionBehavior
        transition.ignoresMouseEvents = true
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: panel.frame.size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        imageView.autoresizingMask = [.width, .height]
        transition.contentView = imageView
        return transition
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }
}
