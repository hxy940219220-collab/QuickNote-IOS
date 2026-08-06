import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class NotePanelController {
    private let panel: NSPanel
    private var previousApp: NSRunningApplication?

    init<Content: View>(rootView: Content) {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.contentViewController = NSHostingController(rootView: rootView)
    }

    func show(activate: Bool, on screen: NSScreen) {
        let targetFrame = Self.panelFrame(in: screen.visibleFrame)
        let shouldAnimate = !panel.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = shouldAnimate ? 0 : 1
        panel.setFrame(shouldAnimate ? Self.revealFrame(from: targetFrame) : targetFrame, display: true)
        if activate {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
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
        } else {
            panel.orderFrontRegardless()
        }
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(targetFrame, display: true)
            }
        }
    }

    static func panelFrame(in visibleFrame: NSRect) -> NSRect {
        NSRect(x: visibleFrame.midX - 210, y: visibleFrame.midY - 260, width: 420, height: 520)
    }

    static func revealFrame(from frame: NSRect) -> NSRect {
        frame.insetBy(dx: 12, dy: 15)
    }

    func hideAndRestoreFocus() {
        CaptureLatencyProbe.cancel()
        panel.orderOut(nil)
        previousApp?.activate(options: [])
        previousApp = nil
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }
}
