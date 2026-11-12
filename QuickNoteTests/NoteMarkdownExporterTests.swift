import AppKit
import XCTest
@testable import QuickNote

@MainActor
final class NoteMarkdownExporterTests: XCTestCase {
    func testExportPreservesEditorStylesAndChecklist() {
        let source = """
        # 教务
        ## 对接数据
        1. 已排课
        - 待同步
        - [x] 校对
        - [ ] 通知
        **重点**、*备注*和 `code`
        [链接](https://example.invalid/)

        ```
        let x = 1

        let y = 2
        ```
        """
        let document = NoteMarkdownImporter.richText(from: source)
        let result = NoteMarkdownExporter.export(document)
        for expected in ["# 教务", "## 对接数据", "1. 已排课", "- 待同步", "- [x] 校对",
                         "- [ ] 通知", "**重点**", "*备注*", "`code`",
                         "[链接](<https://example.invalid/>)", "```\nlet x = 1\n\nlet y = 2\n```"] {
            XCTAssertTrue(result.markdown.contains(expected), "Missing: \(expected) from \(result.markdown)")
        }
        XCTAssertFalse(result.truncated)
    }

    func testExportUsesAttachmentPlaceholders() {
        let doc = NSMutableAttributedString(string: "说明")
        for name in ["schedule.png", "roster.pdf"] {
            let wrapper = FileWrapper(regularFileWithContents: Data("not exported".utf8))
            wrapper.preferredFilename = name
            doc.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        }
        XCTAssertEqual(NoteMarkdownExporter.export(doc).markdown, "说明[图片][附件：roster.pdf]")
    }

    func testExportTruncatesAndEncodedResultFitsSocket() throws {
        let text = String(repeating: "\u{001B}", count: 50_001)
        let export = NoteMarkdownExporter.export(NSAttributedString(string: text))
        XCTAssertEqual(export.markdown.unicodeScalars.count, 50_000)
        XCTAssertTrue(export.truncated)
        let response = MCPBridgeResponse.read(.init(id: UUID(), title: "长文", markdown: export.markdown, truncated: true))
        XCTAssertLessThan(try JSONEncoder().encode(response).count, UnixSocket.maximumPayloadBytes)
    }
}
