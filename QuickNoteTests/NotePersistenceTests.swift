import AppKit
import XCTest
@testable import QuickNote

final class NotePersistenceTests: XCTestCase {
    func testRTFDRoundTripPreservesText() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = NoteDocumentStore(root: root)
        let id = UUID()
        try store.save(NSAttributedString(string: "快速记录"), id: id)
        XCTAssertEqual(try store.load(id: id).string, "快速记录")
    }
}
