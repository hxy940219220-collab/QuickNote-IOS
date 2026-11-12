import Foundation
import XCTest
@testable import QuickNote

final class MCPProtocolTests: XCTestCase {
    func testInitializeDiscoversReadAndProposalTools() throws {
        var server = MCPProtocol()
        let response = try decode(server.process(Data(#"{"jsonrpc":"2.0","id":"client-1","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"Test Client","version":"1"}}}"#.utf8)) { _ in
            XCTFail("Initialization must not contact the app")
            return SearchNotesResult(notes: [])
        })
        XCTAssertEqual(response["id"] as? String, "client-1")
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])

        let early = try send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, to: &server)
        XCTAssertEqual(errorCode(try XCTUnwrap(early)), -32600)
        let notification = try send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, to: &server)
        XCTAssertNil(notification)

        let toolsResponse = try XCTUnwrap(send(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#, to: &server))
        let toolsResult = try XCTUnwrap(toolsResponse["result"] as? [String: Any])
        let tools = try XCTUnwrap(toolsResult["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["search_notes", "read_note", "propose_append", "propose_create", "get_proposal_status"])
    }

    func testSearchReturnsMatchesWithISOStringDateAndPreservesRequestID() throws {
        var server = try initializedServer()
        let id = UUID(uuidString: "BF44A260-B524-4222-BFE0-0F9BC8D62E33")!
        let response = try XCTUnwrap(send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"  迭代 ","limit":2}}}"#, to: &server) { arguments in
            XCTAssertEqual(arguments.query, "迭代")
            XCTAssertEqual(arguments.limit, 2)
            return SearchNotesResult(notes: [
                .init(id: id, title: "功能迭代", location: "测试文件夹", snippet: "第二行\n第三行", updatedAt: Date(timeIntervalSince1970: 0))
            ])
        })
        XCTAssertEqual(response["id"] as? Int, 4)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: String]])
        let text = try XCTUnwrap(content.first?["text"])
        let decoded = try decode(Data(text.utf8))
        let notes = try XCTUnwrap(decoded["notes"] as? [[String: String]])
        XCTAssertEqual(notes, [["id": id.uuidString, "title": "功能迭代", "location": "测试文件夹", "snippet": "第二行\n第三行", "updatedAt": "1970-01-01T00:00:00Z"]])
    }

    func testSearchRejectsMissingBlankAndOverlongQueriesAndInvalidLimits() throws {
        var server = try initializedServer()
        let overlongQuery = String(repeating: "字", count: 513)
        for arguments in ["{}", #"{"query":" "}"#, "{\"query\":\"\(overlongQuery)\"}", #"{"query":"迭代","limit":0}"#, #"{"query":"迭代","limit":21}"#, #"{"query":"迭代","limit":true}"#, #"{"query":"迭代","limit":null}"#, #"{"query":"迭代","limit":1.5}"#] {
            let response = try XCTUnwrap(send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"search_notes","arguments":\#(arguments)}}"#, to: &server) { _ in
                XCTFail("Invalid parameters must not reach the app")
                return SearchNotesResult(notes: [])
            })
            XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true, arguments)
        }
    }

    func testBridgeArgumentsAndResponsesRoundTripAndValidateOnDecode() throws {
        let arguments = try SearchNotesArguments(query: "迭代")
        XCTAssertEqual(arguments.limit, 10)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(SearchNotesArguments.self, from: encoder.encode(arguments)), arguments)
        let versionedSearch = try encoder.encode(MCPReadRequest.search(arguments))
        XCTAssertEqual(try decoder.decode(MCPReadRequest.self, from: versionedSearch), .search(arguments))
        XCTAssertThrowsError(try decoder.decode(SearchNotesArguments.self, from: versionedSearch),
                             "新请求不能被只支持全库搜索的旧 App 执行")
        XCTAssertThrowsError(try decoder.decode(SearchNotesArguments.self, from: Data(#"{"query":"abc","limit":25}"#.utf8)))

        for reply in [MCPBridgeResponse.success(.init(notes: [])), .failure("QuickNote 未运行，请先打开 QuickNote")] {
            XCTAssertEqual(try decoder.decode(MCPBridgeResponse.self, from: encoder.encode(reply)), reply)
        }
    }

    func testBridgeErrorReachesClientAsToolError() throws {
        var server = try initializedServer()
        let response = try XCTUnwrap(send(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"迭代"}}}"#, to: &server) { _ in
            throw MCPToolFailure(message: "QuickNote 未运行，请先打开 QuickNote")
        })
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(result["content"] as? [[String: String]], [["type": "text", "text": "QuickNote 未运行，请先打开 QuickNote"]])
    }

    func testUnknownToolMalformedJSONAndInvalidIDReturnProtocolErrors() throws {
        var server = try initializedServer()
        let invalid = try XCTUnwrap(send("{", to: &server))
        XCTAssertEqual(errorCode(invalid), -32700)
        XCTAssertTrue(invalid["id"] is NSNull)
        for id in ["true", "null", "1.5"] {
            let response = try XCTUnwrap(send(#"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"#, to: &server))
            XCTAssertEqual(errorCode(response), -32600)
            XCTAssertTrue(response["id"] is NSNull)
        }
        let unknown = try XCTUnwrap(send(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"delete_note"}}"#, to: &server))
        XCTAssertEqual(errorCode(unknown), -32602)
        let malformed = try XCTUnwrap(send(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"search_notes","arguments":[]}}"#, to: &server))
        XCTAssertEqual(errorCode(malformed), -32602)
    }

    func testReadValidatesUUIDAndReturnsMarkdown() throws {
        var server = try initializedServer()
        let id = UUID()
        for invalid in ["{}", #"{"id":"../../note"}"#] {
            let request = #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"read_note","arguments":\#(invalid)}}"#
            let response = try decode(server.process(Data(request.utf8), read: { _ in
                XCTFail("Invalid ID reached the app")
                return .init(id: id, title: "", markdown: "", truncated: false)
            }, search: { _ in .init(notes: []) }))
            XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
        let request = #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"read_note","arguments":{"id":"\#(id)"}}}"#
        let response = try decode(server.process(Data(request.utf8), read: { arguments in
            XCTAssertEqual(arguments.id, id)
            return .init(id: id, title: "教务", markdown: "# 教务\n正文", truncated: false)
        }, search: { _ in .init(notes: []) }))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: String]])
        let payload = try XCTUnwrap(content.first?["text"])
        let read = try JSONDecoder().decode(ReadNoteResult.self, from: Data(payload.utf8))
        XCTAssertEqual(read.markdown, "# 教务\n正文")
        XCTAssertFalse(read.truncated)
    }

    func testAppendToolValidatesPositionAndUsesClientFromHandshake() throws {
        var server = try initializedServer()
        let id = UUID()
        let valid = #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"propose_append","arguments":{"id":"\#(id)","markdown":"正文","position":"end","client":"伪造"}}}"#
        var accepted = 0
        _ = server.process(Data(valid.utf8), proposal: { request in
            guard case .append(let arguments, let client) = request else {
                throw MCPToolFailure(message: "错误的提议类型")
            }
            XCTAssertEqual(arguments.id, id)
            XCTAssertEqual(try arguments.validatedPosition(), .end)
            XCTAssertEqual(client, "Test Client")
            accepted += 1
            return .init(proposalID: UUID(), status: .pending)
        }, search: { _ in .init(notes: []) })
        let invalid = valid.replacingOccurrences(of: #""position":"end""#, with: #""position":"replace""#)
        let response = try decode(server.process(Data(invalid.utf8), proposal: { _ in
            XCTFail("无效位置不应转发")
            return .init(proposalID: UUID(), status: .pending)
        }, search: { _ in .init(notes: []) }))
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testFramerReassemblesSplitLinesAndRecoversAfterOverlongLine() {
        var framer = MCPLineFramer(maximumLength: 4)
        XCTAssertEqual(framer.append(Data("ab".utf8)), [])
        XCTAssertEqual(framer.append(Data("cd\nabcde".utf8)), [.message(Data("abcd".utf8)), .tooLong])
        XCTAssertEqual(framer.append(Data("fg\nok\n".utf8)), [.message(Data("ok".utf8))])
    }

    private func initializedServer() throws -> MCPProtocol {
        var server = MCPProtocol()
        _ = try send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"unsupported","capabilities":{},"clientInfo":{"name":"Test Client","version":"1"}}}"#, to: &server)
        _ = try send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, to: &server)
        return server
    }

    private func send(_ message: String, to server: inout MCPProtocol, search: (SearchNotesArguments) throws -> SearchNotesResult = { _ in
        XCTFail("This request must not contact the app")
        return SearchNotesResult(notes: [])
    }) throws -> [String: Any]? {
        try server.process(Data(message.utf8), search: search).map { try decode($0) }
    }

    private func decode(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    private func errorCode(_ response: [String: Any]) -> Int? {
        (response["error"] as? [String: Any])?["code"] as? Int
    }
}
