import AppKit
import SwiftUI

@MainActor
final class EdgeRailController {
    private let window = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var notes: [NoteRecord] = []
    private weak var currentScreen: NSScreen?
    private var hoverTask: Task<Void, Never>?
    private var contentSize = NSSize(width: 18, height: 31)

    var onHover: ((NoteRecord) -> Void)?
    var onExit: (() -> Void)?

    isolated deinit {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
    }

    func start(notes: [NoteRecord]) {
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        update(notes: notes)
        reposition()
        window.orderFrontRegardless()
        removeMouseMonitors()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.reposition()
            return event
        }
    }

    func update(notes: [NoteRecord]) {
        self.notes = Array(notes.prefix(8))
        let hostingView = NSHostingView(rootView: EdgeRailView(
            notes: self.notes,
            hover: { [weak self] in self?.scheduleHover($0) },
            exit: { [weak self] in
                self?.hoverTask?.cancel()
                self?.onExit?()
            }
        ))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView
        contentSize = hostingView.fittingSize
        reposition(force: true)
    }

    private func scheduleHover(_ note: NoteRecord) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.onHover?(note)
        }
    }

    private func removeMouseMonitors() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    static func railFrame(in visibleFrame: NSRect, contentSize: NSSize) -> NSRect {
        NSRect(
            x: visibleFrame.minX + 4,
            y: visibleFrame.midY - contentSize.height / 2,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    private func reposition(force: Bool = false) {
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }
        guard force || screen !== currentScreen else { return }
        currentScreen = screen
        window.setFrame(Self.railFrame(in: screen.visibleFrame, contentSize: contentSize), display: true)
    }
}
