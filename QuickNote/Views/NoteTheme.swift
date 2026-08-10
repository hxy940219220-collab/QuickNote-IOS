import AppKit
import SwiftUI

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
        case .system: .textBackgroundColor
        case .paper: Self.color(0xF7F2E8)
        case .sage: Self.color(0xEEF3ED)
        case .lavender: Self.color(0xF0EEF5)
        case .midnight: Self.color(0x171C24)
        case .blue: Self.color(0xF2F7FC)
        }
    }

    var sidebarBackground: NSColor {
        switch self {
        case .system: .controlBackgroundColor
        case .paper: Self.color(0xEFE8DC)
        case .sage: Self.color(0xE3EBE2)
        case .lavender: Self.color(0xE5E2ED)
        case .midnight: Self.color(0x11161D)
        case .blue: Self.color(0xE6EFF8)
        }
    }

    var toolbarBackground: NSColor {
        switch self {
        case .system: .windowBackgroundColor
        case .paper: Self.color(0xF3EDE3)
        case .sage: Self.color(0xE8EFE7)
        case .lavender: Self.color(0xEAE7F0)
        case .midnight: Self.color(0x151A21)
        case .blue: Self.color(0xEDF4FA)
        }
    }

    var textColor: NSColor {
        switch self {
        case .system: .textColor
        case .paper: Self.color(0x282522)
        case .sage: Self.color(0x243029)
        case .lavender: Self.color(0x292732)
        case .midnight: Self.color(0xE7E8EA)
        case .blue: Self.color(0x203044)
        }
    }

    var accentColor: NSColor {
        switch self {
        case .system: .controlAccentColor
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
