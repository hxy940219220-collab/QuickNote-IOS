import os

@MainActor
enum CaptureLatencyProbe {
    private static let signposter = OSSignposter(
        subsystem: "com.xixi.quicknote",
        category: "CaptureLatency"
    )
    private static var interval: OSSignpostIntervalState?

    static func begin() {
        interval = signposter.beginInterval("DoubleCommandToEditor")
    }

    static func end() {
        guard let interval else { return }
        signposter.endInterval("DoubleCommandToEditor", interval)
        self.interval = nil
    }

    static func cancel() {
        guard let interval else { return }
        signposter.endInterval("DoubleCommandToEditor", interval, "cancelled")
        self.interval = nil
    }
}
