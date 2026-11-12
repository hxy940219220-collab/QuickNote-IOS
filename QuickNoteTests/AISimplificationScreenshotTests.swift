import AppKit
import Security
import SwiftUI
import XCTest
@testable import QuickNote

@MainActor
final class AISimplificationScreenshotTests: XCTestCase {
    func testRenderSimplifiedAIPanels() async throws {
        guard let path = ProcessInfo.processInfo.environment["QUICKNOTE_AI_UI_SCREENSHOTS"] else {
            throw XCTSkip("Set QUICKNOTE_AI_UI_SCREENSHOTS to capture the AI settings and panels")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await selectionScreenshots(output)
        try await imageScreenshot(output, portrait: true)
        try await imageScreenshot(output, portrait: false)
        try await settingsScreenshots(output)
    }

    private func selectionScreenshots(_ output: URL) async throws {
        let state = SelectionActionState()
        state.source = "The community garden opens on Saturday. Bring a reusable water bottle. Volunteers will meet at the entrance on opening day."
        state.result = "社区菜园将在周六开放。请自带可重复使用的水瓶。\n\n开放当天，志愿者会在入口处集合。"
        state.resultProvider = CodexLocalPreferences.destinationName
        state.deliveryNotice = "只发送选中的文字和你的问题，由 Codex（ChatGPT 账号）处理。"
        state.targetTitle = "社区菜园"
        state.phase = .result
        state.resultIsComplete = true
        let panel = makePanel(size: CGSize(width: 360, height: 334), titled: false)
        let view = SelectionActionView(state: state, importSource: {}, perform: { _ in }, importResult: {},
            settings: {}, stop: {}, close: { [weak panel] in panel?.orderOut(nil) }, performQuestion: { _ in })
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        defer { dismiss(panel) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        try writeSnapshot(host, to: output.appending(path: "selection-result.png"))

        let previouslyVisible = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
        state.showsResultHelp = true
        let popover = try await waitForPopover(excluding: previouslyVisible, owner: panel)
        try writeComposite(panel, popover, to: output.appending(path: "selection-help.png"))
        let responderWindow = NSApp.keyWindow ?? popover
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: responderWindow.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        NSApp.sendEvent(escape)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertFalse(state.showsResultHelp, "Esc 应关闭帮助气泡")
        XCTAssertTrue(panel.isVisible, "Esc 关闭帮助时应保留划词面板")
    }

    private func imageScreenshot(_ output: URL, portrait: Bool) async throws {
        let state = ScreenshotActionState()
        state.image = syntheticImage(portrait: portrait)
        state.prompt = "整理出集合时间、地点和需要携带的物品"
        state.provider = CodexLocalPreferences.destinationName
        state.deliveryNotice = "只发送面板中的图片和你的问题，由 Codex（ChatGPT 账号）处理。"
        state.targetTitle = "社区菜园"
        state.result = "**集合时间** · 周六 09:30\n\n**集合地点** · 社区菜园入口\n\n**需要携带** · 水瓶和园艺手套"
        state.phase = .result
        state.resultIsComplete = true
        let view = ScreenshotActionView(state: state, analyze: {}, quickAnalyze: { _ in },
                                        importResult: {}, settings: {}, stop: {}, close: {})
        let panel = makePanel(size: CGSize(width: 720, height: 640))
        panel.title = "图片识别"
        panel.contentView = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        ScreenshotActionView.addImportButton(to: panel, state: state, action: {})
        defer { dismiss(panel) }
        panel.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(160))
        let viewToCapture = try XCTUnwrap(panel.contentView?.superview ?? panel.contentView)
        try writeSnapshot(viewToCapture, to: output.appending(path: portrait ? "image-portrait.png" : "image-landscape.png"))
    }

    private func settingsScreenshots(_ output: URL) async throws {
        let suite = "QuickNote-UI-Report-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = APIKeyKeychain(copyMatching: { _, _ in errSecItemNotFound })
        let store = AIConfigurationStore(defaults: defaults, keychain: keychain)
        store.defaultSourceSelection = .codex
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/codex")
        let target = CodexLocalTarget(executable: executable, sha256: "synthetic",
                                      version: "0.162.1", model: nil, effort: "low")
        var inspection = CodexLocalInspection()
        inspection.executable = executable
        inspection.version = target.version
        inspection.loggedIn = true
        inspection.accountTarget = target
        inspection.target = target
        inspection.verified = true
        let fixture = CodexSettingsPresentation.Fixture(
            inspection: inspection,
            account: .init(email: "demo@example.test", planType: "plus"),
            models: [.init(id: "demo", title: "演示模型", efforts: ["low", "medium", "high"],
                           isDefault: true, defaultEffort: "low")],
            rateLimits: .init(fiveHour: nil,
                              weekly: .init(usedPercent: 64, resetsAt: Date(timeIntervalSince1970: 1_795_027_200)))
        )
        for expanded in [false, true] {
            let view = AISettingsView(store: store, codexSettings: .init(store: store, fixture: fixture),
                                      expandAdvanced: expanded, expandAPI: expanded)
            let panel = makePanel(size: CGSize(width: 720, height: expanded ? 935 : 550))
            panel.title = "AI 模型"
            panel.contentView = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            defer { dismiss(panel) }
            panel.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(160))
            panel.makeFirstResponder(nil)
            let viewToCapture = try XCTUnwrap(panel.contentView?.superview ?? panel.contentView)
            let name = expanded ? "settings-expanded.png" : "settings-collapsed.png"
            try writeSnapshot(viewToCapture, to: output.appending(path: name))
        }
    }

    private func syntheticImage(portrait: Bool) -> NSImage {
        let size = portrait ? CGSize(width: 440, height: 1050) : CGSize(width: 1120, height: 520)
        return NSImage(size: size, flipped: true) { rect in
            NSColor(srgbRed: 0.94, green: 0.97, blue: 0.94, alpha: 1).setFill()
            rect.fill()
            let accent = NSColor(srgbRed: 0.13, green: 0.34, blue: 0.26, alpha: 1)
            let titleSize: CGFloat = portrait ? 42 : 56
            let textSize: CGFloat = portrait ? 26 : 33
            let margin: CGFloat = portrait ? 32 : 45
            let cardWidth = portrait ? size.width - margin * 2 : (size.width - margin * 4) / 3
            let cardHeight: CGFloat = portrait ? 240 : 260
            let top: CGFloat = portrait ? 205 : 190
            func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
                (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                    .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color
                ])
            }
            draw("志愿活动 · 周六", x: margin, y: 34, size: textSize, weight: .medium, color: accent)
            draw("社区菜园开放日", x: margin, y: 86, size: titleSize, weight: .bold, color: accent)
            for (index, item) in [("集合时间", "周六 09:30"), ("集合地点", "社区菜园入口"), ("需要携带", "水瓶和园艺手套")].enumerated() {
                let x = portrait ? margin : margin + CGFloat(index) * (cardWidth + margin)
                let y = portrait ? top + CGFloat(index) * (cardHeight + 22) : top
                NSColor.white.setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: y, width: cardWidth, height: cardHeight),
                             xRadius: 18, yRadius: 18).fill()
                draw("0\(index + 1)", x: x + 24, y: y + 25, size: textSize, weight: .bold, color: accent)
                draw(item.0, x: x + 24, y: y + 85, size: textSize, weight: .semibold, color: accent)
                draw(item.1, x: x + 24, y: y + 144, size: textSize, weight: .regular, color: NSColor.darkGray)
            }
            return true
        }
    }

    private func makePanel(size: CGSize, titled: Bool = true) -> AIReportPanel {
        let panel = AIReportPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: titled ? [.titled, .closable, .resizable] : [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.appearance = NSAppearance(named: .aqua)
        panel.isReleasedWhenClosed = false
        if !titled {
            panel.isOpaque = false
            panel.backgroundColor = .clear
        }
        panel.center()
        return panel
    }

    private func dismiss(_ panel: NSPanel) {
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    private func waitForPopover(excluding seen: Set<Int>, owner: NSPanel) async throws -> NSWindow {
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            let visible = (owner.childWindows ?? []) + NSApp.windows
            if let window = visible.first(where: { $0.isVisible && !seen.contains($0.windowNumber)
                && $0 !== owner && $0.contentView != nil }) { return window }
            try await Task.sleep(for: .milliseconds(40))
        } while ContinuousClock.now < deadline
        return try XCTUnwrap(nil as NSWindow?, "原生帮助气泡未进入窗口层级")
    }

    private func capture(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    private func writeSnapshot(_ view: NSView, to url: URL) throws {
        let data = try XCTUnwrap(capture(view).representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private func writeComposite(_ panel: NSPanel, _ popover: NSWindow, to url: URL) throws {
        let panelView = try XCTUnwrap(panel.contentView)
        let popoverView = try XCTUnwrap(popover.contentView)
        let panelBitmap = try capture(panelView)
        let popoverBitmap = try capture(popoverView)
        let popoverRect = popover.convertToScreen(popoverView.convert(popoverView.bounds, to: nil))
        let scene = panel.frame.union(popoverRect).insetBy(dx: -10, dy: -10).integral
        let combined = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(scene.width) * 2, pixelsHigh: Int(scene.height) * 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: combined))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        NSColor.windowBackgroundColor.setFill()
        CGRect(origin: .zero, size: scene.size).fill()
        panelBitmap.draw(in: panel.frame.offsetBy(dx: -scene.minX, dy: -scene.minY))
        let popoverArea = popoverRect.offsetBy(dx: -scene.minX, dy: -scene.minY)
        let outline = NSBezierPath(roundedRect: popoverArea, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        popoverBitmap.draw(in: popoverArea)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        outline.stroke()
        NSGraphicsContext.restoreGraphicsState()
        combined.size = scene.size
        try XCTUnwrap(combined.representation(using: .png, properties: [:])).write(to: url)
    }
}

private final class AIReportPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
