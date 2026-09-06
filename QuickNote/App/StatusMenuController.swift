import AppKit

@MainActor
final class StatusMenuController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let showAction: () -> Void
    private let settingsAction: () -> Void
    private let quitAction: () -> Void
    private let showPetAction: (() -> Void)?

    init(
        showAction: @escaping () -> Void,
        settingsAction: @escaping () -> Void,
        quitAction: @escaping () -> Void,
        showPetAction: (() -> Void)? = nil
    ) {
        self.showAction = showAction
        self.settingsAction = settingsAction
        self.quitAction = quitAction
        self.showPetAction = showPetAction
        super.init()
        item.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "QuickNote")
        menu.addItem(withTitle: "打开便签", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(withTitle: "AI 设置…", action: #selector(showSettings), keyEquivalent: ",")
        if showPetAction != nil {
            menu.addItem(withTitle: "显示桌宠", action: #selector(showPet), keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 QuickNote", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
    }

    func setShortcutUnavailable() {
        guard menu.item(withTag: 900) == nil else { return }
        let warning = NSMenuItem(
            title: "双击 Command 未启用，请检查键盘监听权限",
            action: nil,
            keyEquivalent: ""
        )
        warning.tag = 900
        warning.isEnabled = false
        menu.insertItem(warning, at: 0)
    }

    @objc private func showPanel() { showAction() }
    @objc private func showSettings() { settingsAction() }
    @objc private func quit() { quitAction() }
    @objc private func showPet() { showPetAction?() }
}
