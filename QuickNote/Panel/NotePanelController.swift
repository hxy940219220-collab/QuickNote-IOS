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
        let generation = animationGeneration

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
        panel.alphaValue = shouldAnimate ? 0 : 1

        if activate {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            focusEditor()
        } else {
            panel.orderFrontRegardless()
        }

        guard shouldAnimate else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.animationGeneration == generation else { return }
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
        let app = previousApp
        previousApp = nil

        guard panel.isVisible else {
            app?.activate(options: [])
            return
        }
        guard !panel.isMiniaturized,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if panel.isMiniaturized { panel.deminiaturize(nil) }
            panel.orderOut(nil)
            panel.alphaValue = 1
            app?.activate(options: [])
            return
        }

        let generation = animationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.animationGeneration == generation else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                app?.activate(options: [])
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

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }
}
