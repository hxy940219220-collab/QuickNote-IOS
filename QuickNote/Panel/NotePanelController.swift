import AppKit
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
        panel.contentViewController = NSHostingController(rootView: rootView)
    }

    func show(activate: Bool, on screen: NSScreen) {
        let visible = screen.visibleFrame
        panel.setFrame(
            NSRect(x: visible.minX + 8, y: visible.midY - 260, width: 420, height: 520),
            display: true
        )
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
