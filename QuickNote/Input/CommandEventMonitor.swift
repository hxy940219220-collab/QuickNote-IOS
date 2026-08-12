import AppKit
import Carbon

@MainActor
final class CommandEventMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = DoubleCommandDetector(maxInterval: AppConfiguration.doubleCommandInterval)
    private var screenshotDetector = CommandShiftDetector()
    private var action: (() -> Void)?
    private var selectionAction: (() -> Void)?
    private var selectionHotKey: EventHotKeyRef?
    private var selectionHotKeyHandler: EventHandlerRef?
    private var screenshotAction: (() -> Void)?

    nonisolated static let selectionHotKeyCode = UInt32(kVK_Space)
    nonisolated static let selectionHotKeyModifiers = UInt32(optionKey)

    nonisolated static func requiresTapRecovery(for type: CGEventType) -> Bool {
        type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
    }

    func start(
        onDoubleCommand: @escaping () -> Void,
        onSelectionShortcut: @escaping () -> Void = {},
        onScreenshotShortcut: @escaping () -> Void = {},
        ensureListenAccess: () -> Bool = {
            CGPreflightListenEventAccess() || CGRequestListenEventAccess()
        }
    ) -> Bool {
        action = onDoubleCommand
        selectionAction = onSelectionShortcut
        screenshotAction = onScreenshotShortcut
        registerSelectionHotKey()
        guard ensureListenAccess() else { return false }
        let mask = [
            CGEventType.flagsChanged,
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ].reduce(CGEventMask()) { $0 | (1 << $1.rawValue) }
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
        screenshotDetector = CommandShiftDetector()
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func consume(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged else {
            _ = detector.observe(.otherKey)
            _ = screenshotDetector.observe(.otherInput)
            return
        }
        let flags = event.flags
        let commandIsDown = flags.contains(.maskCommand)
        let shiftIsDown = flags.contains(.maskShift)
        let hasOtherModifiers = flags.contains(.maskAlternate)
            || flags.contains(.maskControl)
            || flags.contains(.maskSecondaryFn)
        let wasTrackingScreenshot = screenshotDetector.isTracking
        let screenshotTriggered = screenshotDetector.observe(.modifiersChanged(
            commandDown: commandIsDown,
            shiftDown: shiftIsDown,
            hasOtherModifiers: hasOtherModifiers
        ))
        if wasTrackingScreenshot || screenshotDetector.isTracking || shiftIsDown || hasOtherModifiers {
            _ = detector.observe(.otherKey)
        } else if detector.observe(.commandChanged(isDown: commandIsDown, time: event.timestamp.seconds)) {
            action?()
        }
        if screenshotTriggered { screenshotAction?() }
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

}

private extension UInt64 {
    var seconds: TimeInterval { TimeInterval(self) / 1_000_000_000 }
}
