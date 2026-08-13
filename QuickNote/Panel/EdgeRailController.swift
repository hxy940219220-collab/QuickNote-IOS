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
    private let previewWindow = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private weak var currentScreen: NSScreen?
    private var contentSize = EdgeRailView.collapsedSize
    private var noteCount = 0
    private var isExpanded = false

    var onSelect: ((NoteRecord) -> Void)?

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
        previewWindow.level = .floating
        previewWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        previewWindow.isOpaque = false
        previewWindow.backgroundColor = .clear
        previewWindow.hasShadow = true
        previewWindow.ignoresMouseEvents = true
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
        let notes = Array(notes.prefix(EdgeRailView.maximumNotes))
        noteCount = notes.count
        isExpanded = false
        contentSize = EdgeRailView.collapsedSize
        let hostingView = NSHostingView(rootView: EdgeRailView(
            notes: notes,
            preview: { [weak self] in self?.setPreview($0) },
            select: { [weak self] note in
                self?.setPreview(nil)
                self?.onSelect?(note)
            },
            expandedChanged: { [weak self] in self?.setExpanded($0) }
        ))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView
        reposition(force: true)
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        contentSize = expanded
            ? EdgeRailView.expandedSize(noteCount: noteCount)
            : EdgeRailView.collapsedSize
        reposition(force: true, animated: true)
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

    static func previewFrame(
        beside railFrame: NSRect,
        pointerY: CGFloat,
        contentSize: NSSize,
        in visibleFrame: NSRect
    ) -> NSRect {
        NSRect(
            x: min(railFrame.maxX + 8, visibleFrame.maxX - contentSize.width),
            y: min(
                max(pointerY - contentSize.height / 2, visibleFrame.minY),
                visibleFrame.maxY - contentSize.height
            ),
            width: contentSize.width,
            height: contentSize.height
        )
    }

    private func setPreview(_ note: NoteRecord?) {
        guard let note else {
            previewWindow.orderOut(nil)
            return
        }
        let hostingView = NSHostingView(rootView: EdgeRailTitlePreview(title: note.title))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        previewWindow.contentView = hostingView
        guard let screen = currentScreen ?? NSScreen.main else { return }
        previewWindow.setFrame(
            Self.previewFrame(
                beside: window.frame,
                pointerY: NSEvent.mouseLocation.y,
                contentSize: hostingView.fittingSize,
                in: screen.visibleFrame
            ),
            display: true
        )
        previewWindow.orderFrontRegardless()
    }

    private func reposition(force: Bool = false, animated: Bool = false) {
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        }) ?? NSScreen.main else { return }
        guard force || screen !== currentScreen else { return }
        currentScreen = screen
        window.setFrame(
            Self.railFrame(in: screen.visibleFrame, contentSize: contentSize),
            display: true,
            animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
}

private struct EdgeRailTitlePreview: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 180, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }
}
