import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?
    private let commandMonitor = CommandEventMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        statusMenu = StatusMenuController(
            showAction: { [weak self] in self?.showPanelFromFallback() },
            quitAction: { NSApp.terminate(nil) }
        )
        _ = commandMonitor.start { [weak self] in self?.showPanelFromFallback() }
    }

    func showPanelFromFallback() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
