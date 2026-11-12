import Foundation
import XCTest
@testable import QuickNote

final class NoteChunkerTests: XCTestCase {
    func testParagraphChunksKeepExactUTF16RangesAcrossCRLFListsAndTables() {
        let source = "列表 ✅\r\n1. 保持任务\r\n2. 核对输出\n列 A\t列 B\u{2029}值 A\t值 B"
        let snapshot = NoteIndexSnapshot(noteID: UUID(), title: "结构", text: source, revision: 7)
        let chunks = NoteChunker.chunks(for: snapshot)
        XCTAssertEqual(chunks.map(\.text), ["列表 ✅", "1. 保持任务", "2. 核对输出", "列 A\t列 B", "值 A\t值 B"])
        for chunk in chunks {
            XCTAssertEqual((source as NSString).substring(with: chunk.range), chunk.text)
            XCTAssertEqual(chunk.noteID, snapshot.noteID)
            XCTAssertEqual(chunk.title, snapshot.title)
            XCTAssertEqual(chunk.revision, 7)
            XCTAssertEqual(chunk.sourceFingerprint, NoteChunker.sourceFingerprint(for: source))
        }
    }

    func testLongParagraphIsSplitAtCharacterBoundaryAndRetainsUTF16Offsets() {
        let glyph = "👩🏽‍💻"
        let source = String(repeating: glyph, count: 1_013)
        let chunks = NoteChunker.chunks(for: .init(noteID: UUID(), title: "长段", text: source, revision: 1))
        XCTAssertEqual(chunks.map { $0.text.count }, [500, 500, 13])
        XCTAssertEqual(chunks.map(\.text).joined(), source)
        XCTAssertEqual(chunks.map(\.range.location), [0, glyph.utf16.count * 500, glyph.utf16.count * 1_000])
        XCTAssertEqual(chunks.map(\.range.length).reduce(0, +), source.utf16.count)
    }

    func testAttachmentPlaceholderDoesNotReachTheModelOrChangeCitationRange() {
        let source = "\u{fffc}\n左侧\u{fffc}右侧\n\n\u{fffc}"
        let chunks = NoteChunker.chunks(for: .init(noteID: UUID(), title: "附件", text: source, revision: 0))
        XCTAssertEqual(chunks.map(\.text), ["左侧 右侧"])
        XCTAssertEqual(chunks.map(\.range), [NSRange(location: 2, length: 5)])
        XCTAssertEqual((source as NSString).substring(with: chunks[0].range), "左侧\u{fffc}右侧")
    }

    func testSourceFingerprintUsesOriginalUTF8InsteadOfTheNormalizedExcerpt() {
        let composed = "左侧\u{fffc}é\n"
        let decomposed = "左侧\u{fffc}e\u{0301}\n"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(NoteChunker.sourceFingerprint(for: composed),
                          NoteChunker.sourceFingerprint(for: decomposed))
        XCTAssertEqual(NoteChunker.normalizedExcerpt(composed), "左侧 é")
        XCTAssertNotEqual(NoteChunker.sourceFingerprint(for: composed),
                          NoteChunker.sourceFingerprint(for: NoteChunker.normalizedExcerpt(composed)))
        XCTAssertEqual(NoteChunker.sourceFingerprint(for: "abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
