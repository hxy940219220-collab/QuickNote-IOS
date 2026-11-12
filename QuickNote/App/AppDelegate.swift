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
    private var semanticIndex: SemanticIndex?
    private var noteMCPService: NoteMCPService?
    private var indexLoad: Task<Void, Never>?
    private var indexChangesDuringLoad: [UUID: NoteIndexChange]?
    private var committedIndexRevisions: [UUID: Int] = [:]
    private var waitingForCodexShutdown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tests create their own in-memory libraries; never open the user's library in the test host.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        NSApp.setActivationPolicy(.regular)
        do {
            let container = try NoteSchemaMigration.makeContainer()
            let repository = NoteRepository(context: container.mainContext)
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appending(path: "QuickNote/Documents")
            let documents = NoteDocumentStore(root: appSupport)
            let session = NoteSession(repository: repository, documents: documents)
            try session.openMostRecentReadableNote()

            let aiSettings = AISettingsController()
            let desktopPet = DesktopPetController()
            let semanticIndex = SemanticIndex(directory: appSupport.deletingLastPathComponent().appending(path: "Index"))
            let noteMCPService = NoteMCPService(index: semanticIndex, repository: repository, documents: documents, session: session)
            let resolveAskNote: (UUID) -> NoteRecord? = { id in
                guard let note = try? repository.note(withID: id), note.isEligibleForAI else { return nil }
                return note
            }
            let askController = NoteAskController(index: semanticIndex, sourceLocation: { id in
                guard let note = resolveAskNote(id) else { return nil }
                let folder = (try? repository.allFolders())?.first { $0.id == note.folderID }
                return folder?.name ?? "便签集"
            })
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
                    defer { noteMCPService.refreshProposalPermissions() }
                    try repository.delete(folder)
                    try repository.save()
                },
                moveNoteAction: { note, folder in
                    defer { noteMCPService.refreshProposalPermissions() }
                    repository.move(note, to: folder)
                    try repository.save()
                },
                activateEditor: { coordinator.activateEditor() },
                drawerVisibilityChanged: { panel.setDrawerOpen($0) },
                setWindowLocked: { panel.setLocked($0) },
                showAISettings: aiSettings.show,
                desktopPet: desktopPet,
                reorderNoteAction: { id, target, after, pinned in
                    guard try repository.reorderNote(id: id, relativeTo: target, after: after, pinned: pinned) else { return false }
                    try repository.save()
                    return true
                },
                reorderFolderAction: { id, target, after in
                    guard try repository.reorderFolder(id: id, relativeTo: target, after: after) else { return false }
                    try repository.save()
                    return true
                },
                askController: askController,
                resolveAskNote: resolveAskNote,
                noteMCPService: noteMCPService
            )
            panel = NotePanelController(rootView: root)
            coordinator = PanelCoordinator(panel: panel, session: session)

            let rail = EdgeRailController()
            rail.onSelect = { note in try? coordinator.select(note: note) }
            rail.onOpenProposals = { try? coordinator.presentCurrentNote() }
            noteMCPService.proposals.pendingCountChanged = { [weak rail] count in rail?.setPendingCount(count) }
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
            self.semanticIndex = semanticIndex
            self.noteMCPService = noteMCPService
            session.onIndexChange = { [weak self] change, immediately in
                do { try self?.applyIndexChange(change, immediately: immediately) }
                catch { NSLog("QuickNote 无法清理本地检索索引。") }
            }
            session.prepareSensitiveIndexRemoval = { [weak self] id in
                do { try self?.applyIndexChange(.removed(id), immediately: true) }
                catch { throw NoteRecoveryError(message: "暂时无法清理检索索引，请重试标记敏感。") }
            }
            session.onIndexReload = { [weak self, weak askController] in
                self?.reloadNoteIndex()
                askController?.invalidateLibrary()
            }
            session.onNoteBecameIneligibleForAI = { [weak selectionActions, weak petVoice, weak askController, weak noteMCPService] id in
                noteMCPService?.invalidateProposals(for: id)
                selectionActions?.invalidateAIInput(for: id)
                petVoice?.invalidateAIInput(for: id)
                askController?.invalidateNote(id)
            }
            reloadNoteIndex()
            presentationLifecycle.applicationDidLaunch()
            desktopPet.start()
            do {
                try noteMCPService.start(at: UnixSocket.defaultURL())
            } catch {
                NSLog("QuickNote 无法启动 Codex 连接。%@", error.localizedDescription)
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func applyIndexChange(_ change: NoteIndexChange, immediately: Bool) throws {
        let id: UUID
        switch change {
        case .saved(let snapshot):
            id = snapshot.noteID
            committedIndexRevisions[id] = snapshot.revision
        case .removed(let removedID):
            id = removedID
            committedIndexRevisions[id] = nil
        }
        indexChangesDuringLoad?[id] = change
        try semanticIndex?.apply(change, immediately: immediately)
    }

    private func reloadNoteIndex() {
        guard let modelContainer, let semanticIndex else { return }
        indexLoad?.cancel()
        semanticIndex.beginLibraryLoad()
        indexChangesDuringLoad = [:]
        let fetch = Task.detached(priority: .utility) {
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            let notes = try context.fetch(FetchDescriptor<NoteRecord>())
            return notes.compactMap { note -> NoteIndexSnapshot? in
                guard note.isEligibleForAI else { return nil }
                return NoteIndexSnapshot(noteID: note.id, title: note.title, text: note.plainText, revision: 0)
            }
        }
        indexLoad = Task { [weak self] in
            let result = await fetch.result
            guard let self, !Task.isCancelled else { return }
            let changes = indexChangesDuringLoad ?? [:]
            indexChangesDuringLoad = nil
            indexLoad = nil
            guard case .success(let snapshots) = result else {
                semanticIndex.finishLibraryLoadFailure()
                NSLog("QuickNote 无法读取本地检索索引所需的便签元数据。")
                return
            }
            var merged = Dictionary(uniqueKeysWithValues: snapshots.map { snapshot in
                (snapshot.noteID, NoteIndexSnapshot(noteID: snapshot.noteID, title: snapshot.title, text: snapshot.text,
                                                   revision: committedIndexRevisions[snapshot.noteID, default: 0]))
            })
            for (id, change) in changes {
                switch change {
                case .saved(let snapshot): merged[id] = snapshot
                case .removed: merged[id] = nil
                }
            }
            semanticIndex.replaceLibrary(with: Array(merged.values))
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        presentationLifecycle?.applicationShouldHandleReopen() ?? false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if waitingForCodexShutdown { return .terminateLater }
        guard petVoice?.confirmDiscard() != false else { return .terminateCancel }
        petVoice?.hide()
        do {
            try session?.flush()
            desktopPet?.stop()
            waitingForCodexShutdown = true
            Task {
                await CodexLocalClient.shared.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        } catch {
            try? panelCoordinator?.presentCurrentNote()
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        noteMCPService?.stop()
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
