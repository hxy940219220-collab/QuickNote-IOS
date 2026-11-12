import AppKit
import Security
import SwiftData
import SwiftUI
import XCTest
@testable import QuickNote

@MainActor
final class CodexScreenshotRoutingTests: XCTestCase {
    func testQuickAndCustomRequestsKeepTheDestinationShownForConsent() throws {
        try withFixture { store, session, repository, image, pasteboard in
            store.defaultFeatureSource = .system
            store.setFeatureSource(.codex, for: .screenshot)
            var confirmedDestinations = [String]()
            var sentPrompts = [String]()
            let controller = ScreenshotActionController(
                session: session, allNotes: repository.allNotes, aiStore: store, showSettings: {},
                streamRespond: { _, prompt in
                    sentPrompts.append(prompt)
                    return AsyncThrowingStream { $0.finish() }
                },
                confirmSending: { route in
                    confirmedDestinations.append(store.dataDestinationDescription(for: .screenshot, route: route))
                    store.setFeatureSource(.system, for: .screenshot)
                    return true
                }
            )
            controller.present(image, pasteboard: pasteboard)
            let panel = try screenshotPanel()
            defer { panel.close() }
            let view = try XCTUnwrap(panel.contentView as? NSHostingView<ScreenshotActionView>).rootView

            view.quickAnalyze("提取图片中的文字")
            XCTAssertTrue(view.state.usesCodex)
            XCTAssertTrue(view.state.deliveryNotice.contains(CodexLocalPreferences.destinationName))

            store.setFeatureSource(.codex, for: .screenshot)
            view.state.prompt = "图片中有几个圆？"
            view.analyze()
            XCTAssertTrue(view.state.usesCodex)
            XCTAssertEqual(confirmedDestinations, [
                "发送至 Codex（ChatGPT 账号）", "发送至 Codex（ChatGPT 账号）"
            ])
            XCTAssertEqual(sentPrompts, ["提取图片中的文字", "图片中有几个圆？"])
        }
    }

    func testDeclinedConsentAndReplacementDuringConsentCannotSend() throws {
        try withFixture { store, session, repository, image, pasteboard in
            store.setFeatureSource(.codex, for: .screenshot)
            var sendCount = 0
            var confirm: () -> Bool = { false }
            let controller = ScreenshotActionController(
                session: session, allNotes: repository.allNotes, aiStore: store, showSettings: {},
                streamRespond: { _, _ in
                    sendCount += 1
                    return AsyncThrowingStream { $0.finish() }
                },
                confirmSending: { _ in confirm() }
            )
            controller.present(image, pasteboard: pasteboard)
            let panel = try screenshotPanel()
            defer { panel.close(); confirm = { false } }
            let view = try XCTUnwrap(panel.contentView as? NSHostingView<ScreenshotActionView>).rootView

            view.quickAnalyze("总结")
            XCTAssertEqual(sendCount, 0)

            confirm = {
                controller.present(image, pasteboard: pasteboard)
                return true
            }
            view.quickAnalyze("翻译")
            XCTAssertEqual(sendCount, 0)
            XCTAssertEqual(view.state.phase, .idle)
        }
    }

    private func screenshotPanel() throws -> NSPanel {
        try XCTUnwrap(NSApp.windows.first { $0.title == "图片识别" && $0.isVisible } as? NSPanel)
    }

    private func withFixture(
        _ check: (AIConfigurationStore, NoteSession, NoteRepository, NSImage, NSPasteboard) throws -> Void
    ) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "CodexScreenshotRouting-\(UUID())")
        let defaultsName = "QuickNoteTests.CodexScreenshotRouting.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let pasteboard = NSPasteboard(name: .init(defaultsName))
        defer {
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: folder)
        }
        let store = AIConfigurationStore(defaults: defaults,
            keychain: APIKeyKeychain(copyMatching: { _, _ in errSecItemNotFound }))
        let container = try ModelContainer(for: NoteRecord.self, NoteFolder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let repository = NoteRepository(context: container.mainContext)
        let session = NoteSession(repository: repository, documents: NoteDocumentStore(root: folder))
        let image = NSImage(size: NSSize(width: 32, height: 24))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        try check(store, session, repository, image, pasteboard)
    }
}
