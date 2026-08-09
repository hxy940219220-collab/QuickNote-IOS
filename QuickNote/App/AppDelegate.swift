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
    private var selectionActions: SelectionActionController?
    private var aiSettings: AISettingsController?
    private var presentationLifecycle: AppPresentationLifecycle?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        do {
            let container = try ModelContainer(for: NoteRecord.self, NoteFolder.self)
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

            let aiSettings = AISettingsController()
            var coordinator: PanelCoordinator!
            var panel: NotePanelController!
            let root = RootNoteView(
                session: session,
                allNotes: repository.allNotes,
                allFolders: repository.allFolders,
                createFolderAction: { name in
                    _ = try repository.createFolder(named: name)
                    try repository.save()
                },
                renameFolderAction: { folder, name in
                    try repository.rename(folder, to: name)
                    try repository.save()
                },
                deleteFolderAction: { folder in
                    try repository.delete(folder)
                    try repository.save()
                },
                moveNoteAction: { note, folder in
                    repository.move(note, to: folder)
                    try repository.save()
                },
                activateEditor: { coordinator.activateEditor() },
                drawerVisibilityChanged: { panel.setDrawerOpen($0) },
                setWindowLocked: { panel.setLocked($0) },
                showAISettings: aiSettings.show
            )
            panel = NotePanelController(rootView: root)
            coordinator = PanelCoordinator(panel: panel, session: session, repository: repository)

            let rail = EdgeRailController()
            rail.onSelect = { note in try? coordinator.select(note: note) }
            rail.start(notes: try repository.recentNotes())
            session.onSaved = { [weak rail] in
                guard let rail else { return }
                try? rail.update(notes: repository.recentNotes())
            }

            let togglePanel: () -> Void = { _ = try? coordinator.toggleFromCommand() }
            let presentationLifecycle = AppPresentationLifecycle {
                try? coordinator.presentCurrentNote()
            }
            let selectionActions = SelectionActionController(
                session: session,
                showSettings: aiSettings.show
            )
            statusMenu = StatusMenuController(
                showAction: { _ = presentationLifecycle.applicationShouldHandleReopen() },
                settingsAction: aiSettings.show,
                quitAction: { NSApp.terminate(nil) }
            )
            let monitorStarted = commandMonitor.start(
                onDoubleCommand: togglePanel,
                onSelectionShortcut: selectionActions.captureSelection
            )
            if !monitorStarted {
                statusMenu?.setShortcutUnavailable()
            }

            modelContainer = container
            self.repository = repository
            self.session = session
            panelCoordinator = coordinator
            edgeRail = rail
            self.selectionActions = selectionActions
            self.aiSettings = aiSettings
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
