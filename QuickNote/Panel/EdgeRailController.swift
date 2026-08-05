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
    private var mouseMonitor: Any?
    private var notes: [NoteRecord] = []
    private weak var currentScreen: NSScreen?
    private var hoverTask: Task<Void, Never>?

    var onHover: ((NoteRecord) -> Void)?
    var onExit: (() -> Void)?

    func start(notes: [NoteRecord]) {
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = true
        update(notes: notes)
        reposition()
        window.orderFrontRegardless()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    func update(notes: [NoteRecord]) {
        self.notes = Array(notes.prefix(8))
        window.contentView = NSHostingView(rootView: EdgeRailView(
            notes: self.notes,
            hover: { [weak self] in self?.scheduleHover($0) },
            exit: { [weak self] in
                self?.hoverTask?.cancel()
                self?.onExit?()
            }
        ))
    }

    private func scheduleHover(_ note: NoteRecord) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.onHover?(note)
        }
    }

    private func reposition() {
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }
        guard screen !== currentScreen else { return }
        currentScreen = screen
        let frame = screen.visibleFrame
        window.setFrame(
            NSRect(x: frame.minX, y: frame.midY - 150, width: 18, height: 300),
            display: true
        )
    }
}
