import AppKit

@MainActor
final class StatusMenuController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let showAction: () -> Void
    private let quitAction: () -> Void

    init(showAction: @escaping () -> Void, quitAction: @escaping () -> Void) {
        self.showAction = showAction
        self.quitAction = quitAction
        super.init()
        item.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "QuickNote")
        menu.addItem(withTitle: "打开便签", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 QuickNote", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
    }

    @objc private func showPanel() { showAction() }
    @objc private func quit() { quitAction() }
}
