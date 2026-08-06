import AppKit

@MainActor
final class CommandEventMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = DoubleCommandDetector(maxInterval: AppConfiguration.doubleCommandInterval)
    private var action: (() -> Void)?

    nonisolated static func requiresTapRecovery(for type: CGEventType) -> Bool {
        type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
    }

    func start(
        onDoubleCommand: @escaping () -> Void,
        ensureListenAccess: () -> Bool = {
            CGPreflightListenEventAccess() || CGRequestListenEventAccess()
        }
    ) -> Bool {
        guard ensureListenAccess() else { return false }
        action = onDoubleCommand
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
}

private extension UInt64 {
    var seconds: TimeInterval { TimeInterval(self) / 1_000_000_000 }
}
