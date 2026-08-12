import AppKit
import Carbon

@MainActor
final class CommandEventMonitor {
    enum ScreenshotMode: UInt32, CaseIterable, Sendable {
        case region = 1
        case window = 2
        case screen = 3

        var keyCode: UInt32 {
            switch self {
            case .region: UInt32(kVK_ANSI_1)
            case .window: UInt32(kVK_ANSI_2)
            case .screen: UInt32(kVK_ANSI_3)
            }
        }
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = DoubleCommandDetector(maxInterval: AppConfiguration.doubleCommandInterval)
    private var action: (() -> Void)?
    private var selectionAction: (() -> Void)?
    private var selectionHotKey: EventHotKeyRef?
    private var selectionHotKeyHandler: EventHandlerRef?
    private var screenshotAction: ((ScreenshotMode) -> Void)?
    private var screenshotHotKeys: [EventHotKeyRef] = []
    private var screenshotHotKeyHandler: EventHandlerRef?

    nonisolated static let selectionHotKeyCode = UInt32(kVK_Space)
    nonisolated static let selectionHotKeyModifiers = UInt32(optionKey)
    nonisolated static let screenshotHotKeyModifiers = UInt32(cmdKey | shiftKey)

    nonisolated static func requiresTapRecovery(for type: CGEventType) -> Bool {
        type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
    }

    func start(
        onDoubleCommand: @escaping () -> Void,
        onSelectionShortcut: @escaping () -> Void = {},
        onScreenshotShortcut: @escaping (ScreenshotMode) -> Void = { _ in },
        ensureListenAccess: () -> Bool = {
            CGPreflightListenEventAccess() || CGRequestListenEventAccess()
        }
    ) -> Bool {
        action = onDoubleCommand
        selectionAction = onSelectionShortcut
        screenshotAction = onScreenshotShortcut
        registerSelectionHotKey()
        registerScreenshotHotKeys()
        guard ensureListenAccess() else { return false }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<CommandEventMonitor>.fromOpaque(context).takeUnretainedValue()
                if CommandEventMonitor.requiresTapRecovery(for: type) {
                    Task { @MainActor in monitor.reenableTap() }
                    return Unmanaged.passUnretained(event)
                }
                Task { @MainActor in monitor.consume(type: type, event: event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func reenableTap() {
        guard let tap else { return }
        detector = DoubleCommandDetector(maxInterval: AppConfiguration.doubleCommandInterval)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func consume(type: CGEventType, event: CGEvent) {
        let triggered: Bool
        if type == .keyDown {
            triggered = detector.observe(.otherKey)
        } else {
            let commandIsDown = event.flags.contains(.maskCommand)
            triggered = detector.observe(.commandChanged(isDown: commandIsDown, time: event.timestamp.seconds))
        }
        if triggered { action?() }
    }

    private func registerSelectionHotKey() {
        guard selectionHotKey == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<CommandEventMonitor>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in monitor.selectionAction?() }
                return noErr
            },
            1,
            &eventType,
            context,
            &selectionHotKeyHandler
        )
        let identifier = EventHotKeyID(signature: 0x514E6F74, id: 1)
        RegisterEventHotKey(
            Self.selectionHotKeyCode,
            Self.selectionHotKeyModifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &selectionHotKey
        )
    }

    private func registerScreenshotHotKeys() {
        guard screenshotHotKeys.isEmpty else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr,
                      identifier.signature == 0x514E696D,
                      let mode = ScreenshotMode(rawValue: identifier.id) else {
                    return OSStatus(eventNotHandledErr)
                }
                let monitor = Unmanaged<CommandEventMonitor>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in monitor.screenshotAction?(mode) }
                return noErr
            },
            1,
            &eventType,
            context,
            &screenshotHotKeyHandler
        )
        for mode in ScreenshotMode.allCases {
            var hotKey: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: 0x514E696D, id: mode.rawValue)
            if RegisterEventHotKey(
                mode.keyCode,
                Self.screenshotHotKeyModifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &hotKey
            ) == noErr, let hotKey {
                screenshotHotKeys.append(hotKey)
            }
        }
    }
}

private extension UInt64 {
    var seconds: TimeInterval { TimeInterval(self) / 1_000_000_000 }
}
