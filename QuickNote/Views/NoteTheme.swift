import AppKit
import SwiftUI

enum NoteChrome {
    static let sidebarWidth: CGFloat = 210
    static let toolbarHeight: CGFloat = 32
    static let toolbarControlHeight: CGFloat = 24
    static let toolbarIconSize: CGFloat = 11
    static let editorDisplayScale: CGFloat = 1
    // RootNoteView already provides the horizontal gutter; do not double it here.
    static let editorInsets = NSSize(width: 0, height: 16)
    static let maximumEditorWidth: CGFloat = 820
    static let sidebar = adaptive(0xF3F2EF, 0x252422)
    static let inset = adaptive(0xE6E4E0, 0x363430)
    static let editor = adaptive(0xFFFFFF, 0x1E1E1E)
    static let text = adaptive(0x1C1C1E, 0xECEBE8)
    static let accent = adaptive(0xC97A12, 0xE8A74C)
    static let selection = adaptive(0xF6E8D7, 0x4B3927)
    static let separator = adaptive(0xE3E1DC, 0x3C3935)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

enum NoteTheme: String, CaseIterable, Identifiable {
    case system
    case paper
    case sage
    case lavender
    case midnight
    case blue

    var id: String { rawValue }

    static func resolved(from rawValue: String) -> NoteTheme {
        NoteTheme(rawValue: rawValue) ?? .system
    }

    var name: String {
        switch self {
        case .system: "系统默认"
        case .paper: "暖纸"
        case .sage: "鼠尾草"
        case .lavender: "暮光紫"
        case .midnight: "午夜墨"
        case .blue: "雾蓝"
        }
    }

    var editorBackground: NSColor {
        switch self {
        case .system: NoteChrome.editor
        case .paper: Self.color(0xF7F2E8)
        case .sage: Self.color(0xEEF3ED)
        case .lavender: Self.color(0xF0EEF5)
        case .midnight: Self.color(0x171C24)
        case .blue: Self.color(0xF2F7FC)
        }
    }

    var sidebarBackground: NSColor {
        switch self {
        case .system: NoteChrome.sidebar
        case .paper: Self.color(0xEFE8DC)
        case .sage: Self.color(0xE3EBE2)
        case .lavender: Self.color(0xE5E2ED)
        case .midnight: Self.color(0x11161D)
        case .blue: Self.color(0xE6EFF8)
        }
    }

    var toolbarBackground: NSColor {
        switch self {
        case .system: NoteChrome.editor
        case .paper: Self.color(0xF3EDE3)
        case .sage: Self.color(0xE8EFE7)
        case .lavender: Self.color(0xEAE7F0)
        case .midnight: Self.color(0x151A21)
        case .blue: Self.color(0xEDF4FA)
        }
    }

    var textColor: NSColor {
        switch self {
        case .system: NoteChrome.text
        case .paper: Self.color(0x282522)
        case .sage: Self.color(0x243029)
        case .lavender: Self.color(0x292732)
        case .midnight: Self.color(0xE7E8EA)
        case .blue: Self.color(0x203044)
        }
    }

    var accentColor: NSColor {
        switch self {
        case .system: NoteChrome.accent
        case .paper: Self.color(0xB8664A)
        case .sage: Self.color(0x5F7967)
        case .lavender: Self.color(0x756A91)
        case .midnight: Self.color(0x7187A3)
        case .blue: Self.color(0x4E7FAE)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .midnight: .dark
        default: .light
        }
    }

    var overridesDocumentTextColor: Bool {
        self == .midnight
    }

    private static func color(_ hex: UInt32) -> NSColor {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        return NSColor(
            srgbRed: red,
            green: green,
            blue: blue,
            alpha: 1
        )
    }
}
