import XCTest
@testable import QuickNote

final class CodexEffortTests: XCTestCase {
    func testSliderUsesOnlyUniqueAdvertisedEffortsInRankOrder() {
        XCTAssertEqual(
            CodexEffortScale.options(["xhigh", "experimental", "low", "medium", "low", ""]),
            ["low", "medium", "xhigh", "experimental"]
        )
        XCTAssertEqual(CodexEffortScale.options([]), [])
    }

    func testModelChangeRetainsSupportedEffortOrChoosesNearestRank() {
        XCTAssertEqual(CodexEffortScale.nearest("medium", advertised: ["low", "medium"], defaultEffort: "low"), "medium")
        XCTAssertEqual(CodexEffortScale.nearest("xhigh", advertised: ["low", "high"], defaultEffort: "low"), "high")
        XCTAssertEqual(CodexEffortScale.nearest("low", advertised: ["minimal", "medium"], defaultEffort: "medium"), "medium")
        XCTAssertEqual(CodexEffortScale.nearest("low", advertised: ["medium", "minimal"], defaultEffort: nil), "minimal")
    }

    func testUnknownOrAbsentEffortsUseOnlySupportedValues() {
        XCTAssertEqual(CodexEffortScale.nearest("future", advertised: ["low", "new"], defaultEffort: "new"), "new")
        XCTAssertEqual(CodexEffortScale.nearest("future", advertised: ["new", "low"], defaultEffort: "absent"), "low")
        XCTAssertEqual(CodexEffortScale.nearest("low", advertised: ["experimental"], defaultEffort: nil), "experimental")
        XCTAssertNil(CodexEffortScale.nearest("low", advertised: [], defaultEffort: "low"))
    }
}
