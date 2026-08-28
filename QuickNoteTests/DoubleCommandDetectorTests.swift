import XCTest
@testable import QuickNote

final class DoubleCommandDetectorTests: XCTestCase {
    func testTwoCompletePressesWithinWindowTrigger() {
        var detector = DoubleCommandDetector(maxInterval: 0.300)
        XCTAssertFalse(detector.observe(.commandChanged(isDown: true, time: 1.00)))
        XCTAssertFalse(detector.observe(.commandChanged(isDown: false, time: 1.04)))
        XCTAssertFalse(detector.observe(.commandChanged(isDown: true, time: 1.20)))
        XCTAssertTrue(detector.observe(.commandChanged(isDown: false, time: 1.24)))
    }

    func testNaturalFourHundredFiftyMillisecondDoubleTapTriggers() {
        var detector = DoubleCommandDetector(maxInterval: AppConfiguration.doubleCommandInterval)
        XCTAssertFalse(detector.observe(.commandChanged(isDown: true, time: 1.00)))
        XCTAssertFalse(detector.observe(.commandChanged(isDown: false, time: 1.04)))
        XCTAssertFalse(detector.observe(.commandChanged(isDown: true, time: 1.45)))
        XCTAssertTrue(detector.observe(.commandChanged(isDown: false, time: 1.49)))
    }

    func testOtherKeyCancelsPendingPress() {
        var detector = DoubleCommandDetector(maxInterval: 0.300)
        _ = detector.observe(.commandChanged(isDown: true, time: 1.00))
        _ = detector.observe(.commandChanged(isDown: false, time: 1.04))
        _ = detector.observe(.otherKey)
        _ = detector.observe(.commandChanged(isDown: true, time: 1.20))
        XCTAssertFalse(detector.observe(.commandChanged(isDown: false, time: 1.24)))
    }

    func testSlowSecondPressDoesNotTrigger() {
        var detector = DoubleCommandDetector(maxInterval: 0.300)
        _ = detector.observe(.commandChanged(isDown: true, time: 1.00))
        _ = detector.observe(.commandChanged(isDown: false, time: 1.04))
        _ = detector.observe(.commandChanged(isDown: true, time: 1.50))
        XCTAssertFalse(detector.observe(.commandChanged(isDown: false, time: 1.54)))
    }

    func testTriggerSuppressesCommandBounceDuringToggleAnimation() {
        var detector = DoubleCommandDetector(maxInterval: 0.500)
        _ = detector.observe(.commandChanged(isDown: true, time: 1.00))
        _ = detector.observe(.commandChanged(isDown: false, time: 1.04))
        _ = detector.observe(.commandChanged(isDown: true, time: 1.16))
        XCTAssertTrue(detector.observe(.commandChanged(isDown: false, time: 1.20)))

        XCTAssertFalse(detector.observe(.commandChanged(isDown: true, time: 1.24)))
        XCTAssertFalse(detector.observe(.commandChanged(isDown: false, time: 1.28)))
        XCTAssertFalse(detector.observe(.commandChanged(isDown: true, time: 1.40)))
        XCTAssertFalse(detector.observe(.commandChanged(isDown: false, time: 1.44)))

        _ = detector.observe(.commandChanged(isDown: true, time: 1.72))
        _ = detector.observe(.commandChanged(isDown: false, time: 1.76))
        _ = detector.observe(.commandChanged(isDown: true, time: 1.88))
        XCTAssertTrue(detector.observe(.commandChanged(isDown: false, time: 1.92)))
    }

    func testCommandShiftTriggersOnlyWhenNoThirdInputOccurs() {
        var detector = CommandShiftDetector()
        XCTAssertFalse(detector.observe(.modifiersChanged(
            commandDown: true,
            shiftDown: false,
            hasOtherModifiers: false
        )))
        XCTAssertFalse(detector.observe(.modifiersChanged(
            commandDown: true,
            shiftDown: true,
            hasOtherModifiers: false
        )))
        XCTAssertFalse(detector.observe(.modifiersChanged(
            commandDown: true,
            shiftDown: false,
            hasOtherModifiers: false
        )))
        XCTAssertTrue(detector.observe(.modifiersChanged(
            commandDown: false,
            shiftDown: false,
            hasOtherModifiers: false
        )))

        _ = detector.observe(.modifiersChanged(commandDown: true, shiftDown: true, hasOtherModifiers: false))
        _ = detector.observe(.otherInput)
        XCTAssertFalse(detector.observe(.modifiersChanged(
            commandDown: false,
            shiftDown: false,
            hasOtherModifiers: false
        )))
    }
}
