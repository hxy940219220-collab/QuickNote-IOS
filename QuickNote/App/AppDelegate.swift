import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        statusMenu = StatusMenuController(
            showAction: { [weak self] in self?.showPanelFromFallback() },
            quitAction: { NSApp.terminate(nil) }
        )
    }

    func showPanelFromFallback() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
