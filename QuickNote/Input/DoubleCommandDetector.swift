import Foundation

struct DoubleCommandDetector {
    enum Observation {
        case commandChanged(isDown: Bool, time: TimeInterval)
        case otherKey
    }

    let maxInterval: TimeInterval
    private var pressIsDown = false
    private var firstReleaseTime: TimeInterval?

    init(maxInterval: TimeInterval) {
        self.maxInterval = maxInterval
    }

    mutating func observe(_ observation: Observation) -> Bool {
        switch observation {
        case .otherKey:
            reset()
            return false
        case let .commandChanged(isDown, time):
            if isDown {
                guard !pressIsDown else { return false }
                pressIsDown = true
                return false
            }
            guard pressIsDown else { return false }
            pressIsDown = false
            if let firstReleaseTime, time - firstReleaseTime <= maxInterval {
                reset()
                return true
            }
            firstReleaseTime = time
            return false
        }
    }

    private mutating func reset() {
        pressIsDown = false
        firstReleaseTime = nil
    }
}
