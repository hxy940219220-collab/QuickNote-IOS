import AppKit
import SwiftData

@MainActor
struct AppPresentationLifecycle {
    let presentCurrentNote: () -> Void

    func applicationDidLaunch() {
        presentCurrentNote()
    }

    func applicationShouldHandleReopen() -> Bool {
        presentCurrentNote()
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?
    private let commandMonitor = CommandEventMonitor()
    private var modelContainer: ModelContainer?
    private var repository: NoteRepository?
    private var session: NoteSession?
    private var panelCoordinator: PanelCoordinator?
    private var edgeRail: EdgeRailController?
    private var presentationLifecycle: AppPresentationLifecycle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        do {
            let container = try ModelContainer(for: NoteRecord.self)
            let repository = NoteRepository(context: container.mainContext)
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appending(path: "QuickNote/Documents")
            let session = NoteSession(
                repository: repository,
                documents: NoteDocumentStore(root: appSupport)
            )
            if let last = try repository.recentNotes(limit: 1).first {
                try session.open(last)
            } else {
                try session.createAndOpen()
            }

            var coordinator: PanelCoordinator!
            let root = RootNoteView(
                session: session,
                allNotes: repository.allNotes,
                activateEditor: { coordinator.activateEditor() }
            )
            let panel = NotePanelController(rootView: root)
            coordinator = PanelCoordinator(panel: panel, session: session, repository: repository)

            let rail = EdgeRailController()
            rail.onHover = { note in try? coordinator.hover(note: note) }
            rail.onExit = { coordinator.pointerExited() }
            rail.start(notes: try repository.recentNotes())
            session.onSaved = { [weak rail] in
                guard let rail else { return }
                try? rail.update(notes: repository.recentNotes())
            }

            let togglePanel: () -> Void = { _ = try? coordinator.toggleFromCommand() }
            let presentationLifecycle = AppPresentationLifecycle {
                try? coordinator.presentCurrentNote()
            }
            statusMenu = StatusMenuController(
                showAction: { _ = presentationLifecycle.applicationShouldHandleReopen() },
                quitAction: { NSApp.terminate(nil) }
            )
            let monitorStarted = commandMonitor.start(onDoubleCommand: togglePanel)
            if !monitorStarted {
                statusMenu?.setShortcutUnavailable()
            }

            modelContainer = container
            self.repository = repository
            self.session = session
            panelCoordinator = coordinator
            edgeRail = rail
            self.presentationLifecycle = presentationLifecycle
            presentationLifecycle.applicationDidLaunch()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        presentationLifecycle?.applicationShouldHandleReopen() ?? false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            try session?.flush()
            return .terminateNow
        } catch {
            try? panelCoordinator?.presentCurrentNote()
            return .terminateCancel
        }
    }
}
