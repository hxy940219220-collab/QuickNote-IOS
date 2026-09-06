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
    private var screenshotActions: ScreenshotActionController?
    private var aiSettings: AISettingsController?
    private var presentationLifecycle: AppPresentationLifecycle?
    private var desktopPet: DesktopPetController?
    private var petDrops: DesktopPetDropController?
    private var petVoice: DesktopPetVoiceController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tests create their own in-memory libraries; never open the user's library in the test host.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
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
            try session.openMostRecentReadableNote()

            let aiSettings = AISettingsController()
            let desktopPet = DesktopPetController()
            var coordinator: PanelCoordinator!
            var panel: NotePanelController!
            let root = RootNoteView(
                session: session,
                allNotes: repository.allNotes,
                searchNotes: repository.search,
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
                showAISettings: aiSettings.show,
                desktopPet: desktopPet
            )
            panel = NotePanelController(rootView: root)
            coordinator = PanelCoordinator(panel: panel, session: session)

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
                allNotes: repository.allNotes,
                showSettings: aiSettings.show,
                desktopPet: desktopPet
            )
            let screenshotActions = ScreenshotActionController(
                session: session,
                allNotes: repository.allNotes,
                showSettings: aiSettings.show,
                desktopPet: desktopPet
            )
            let petDrops = DesktopPetDropController(session: session, allNotes: repository.allNotes,
                pet: desktopPet, showImage: { [weak screenshotActions] in screenshotActions?.present($0) })
            let petVoice = DesktopPetVoiceController(session: session, allNotes: repository.allNotes,
                pet: desktopPet, showSettings: aiSettings.show, openNote: { [weak coordinator] id in
                    guard let note = try? repository.allNotes().first(where: { $0.id == id }) else { return }
                    try? coordinator?.select(note: note)
                }, showAnalysis: { [weak selectionActions] text, targetID, revision in
                    selectionActions?.presentVoice(text, targetID: targetID, revision: revision)
                })
            desktopPet.onDrop = { [weak petDrops] in petDrops?.present($0) }
            desktopPet.canReceiveDrop = { [weak petDrops, weak petVoice] in petDrops?.pending == nil && petVoice?.isPresented != true }
            desktopPet.onHidden = { [weak petDrops, weak petVoice] in petDrops?.cancel(); petVoice?.hide() }
            desktopPet.onAction = { [weak coordinator, weak session, weak selectionActions, weak screenshotActions, weak aiSettings, weak petDrops, weak petVoice] action, sourcePID in
                do {
                    switch action {
                    case .openNote: try coordinator?.presentCurrentNote()
                    case .newNote:
                        _ = session?.createAndOpenRecovering()
                        try coordinator?.presentCurrentNote()
                    case .screenshot: screenshotActions?.capture()
                    case .selection: selectionActions?.captureSelection(from: sourcePID)
                    case .settings: aiSettings?.show()
                    case .voice:
                        guard petDrops?.pending == nil else { return }
                        petVoice?.show()
                    }
                } catch { NSAlert(error: error).runModal() }
            }
            statusMenu = StatusMenuController(
                showAction: { _ = presentationLifecycle.applicationShouldHandleReopen() },
                settingsAction: aiSettings.show,
                quitAction: { NSApp.terminate(nil) },
                showPetAction: { [weak desktopPet] in desktopPet?.setEnabled(true) }
            )
            let monitorStarted = commandMonitor.start(
                onDoubleCommand: togglePanel,
                onSelectionShortcut: selectionActions.captureSelection,
                onScreenshotShortcut: screenshotActions.capture
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
            self.screenshotActions = screenshotActions
            NSApp.servicesProvider = self
            self.aiSettings = aiSettings
            self.desktopPet = desktopPet
            self.petDrops = petDrops
            self.petVoice = petVoice
            self.presentationLifecycle = presentationLifecycle
            presentationLifecycle.applicationDidLaunch()
            desktopPet.start()
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
        guard petVoice?.confirmDiscard() != false else { return .terminateCancel }
        petVoice?.hide()
        do {
            try session?.flush()
            desktopPet?.stop()
            return .terminateNow
        } catch {
            try? panelCoordinator?.presentCurrentNote()
            return .terminateCancel
        }
    }

    @objc func analyzeImage(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let image = ScreenshotImageProcessor.image(from: pasteboard) else {
            error.pointee = "QuickNote 无法读取所选图片。" as NSString
            return
        }
        screenshotActions?.present(image)
    }
}
