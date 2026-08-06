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

    private func reposition() {
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }
        guard screen !== currentScreen else { return }
        currentScreen = screen
        let frame = screen.visibleFrame
        window.setFrame(
            NSRect(x: frame.minX + 4, y: frame.midY - 150, width: 18, height: 300),
            display: true
        )
    }
}
