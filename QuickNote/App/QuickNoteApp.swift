import SwiftUI

enum AppConfiguration {
    static let doubleCommandInterval: TimeInterval = 0.300
}

@main
struct QuickNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
