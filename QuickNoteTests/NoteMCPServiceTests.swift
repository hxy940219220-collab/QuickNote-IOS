import AppKit
import Foundation
import SwiftData
import XCTest
@testable import QuickNote

@MainActor
final class NoteMCPServiceTests: XCTestCase {
    func testEnabledByDefaultStillRequiresGrantAndRespectsExplicitDisable() async throws {
        let library = try TestLibrary()
        var searches = 0
        let service = NoteMCPService(repository: library.repository, defaults: library.defaults) { _, _, _ in
            searches += 1
            return .init(mode: .keyword, hits: [])
        }

        XCTAssertTrue(service.isEnabled)
        let initiallyUngranted = try await search(service)
        XCTAssertEqual(initiallyUngranted, .success(.init(notes: [])))
        service.setEnabled(false)
        let disabled = try await search(service)
        XCTAssertEqual(disabled, .failure("QuickNote 的 Codex 连接已关闭。"))
        XCTAssertEqual(searches, 0)

        let reopened = NoteMCPService(repository: library.repository, defaults: library.defaults) { _, _, _ in
            searches += 1
            return .init(mode: .keyword, hits: [])
        }
        XCTAssertFalse(reopened.isEnabled)
        reopened.setEnabled(true)
        let ungranted = try await search(reopened)
        XCTAssertEqual(ungranted, .success(.init(notes: [])))
        XCTAssertEqual(searches, 0)
        service.setFolder(nil, allowed: true)
        let granted = NoteMCPService(repository: library.repository, defaults: library.defaults) { _, _, _ in
            searches += 1
            return .init(mode: .keyword, hits: [])
        }
        XCTAssertTrue(granted.readScope.includes(nil))
        let enabled = try await search(granted)
        XCTAssertEqual(enabled, .success(.init(notes: [])))
        XCTAssertEqual(searches, 1)
    }

    func testSearchReturnsDistinctEligibleNotesWithCurrentTitleLocationAndTimestamp() async throws {
        let library = try TestLibrary()
        let grouped = library.repository.createNote()
        let ungrouped = library.repository.createNote()
        let sensitive = library.repository.createNote()
        let deleted = library.repository.createNote()
        let folder = try library.repository.createFolder(named: "项目")
        library.repository.move(grouped, to: folder)
        grouped.title = "当前标题"
        grouped.updatedAt = Date(timeIntervalSince1970: 100)
        sensitive.isSensitive = true
        library.repository.delete(deleted)
        try library.repository.save()
        let indexHits = [
            hit(sensitive.id, text: "敏感正文"),
            hit(deleted.id, text: "已删除正文"),
            hit(UUID(), text: "已消失正文"),
            hit(grouped.id, text: "相关片段"),
            hit(grouped.id, text: "同一便签的另一片段"),
            hit(ungrouped.id, text: "便签集片段"),
        ]
        let authorizedIDs: Set<UUID> = [grouped.id, ungrouped.id]
        let service = NoteMCPService(repository: library.repository, defaults: library.defaults) { _, _, ids in
            XCTAssertEqual(ids, authorizedIDs)
            return .init(mode: .keyword, hits: indexHits)
        }
        service.setEnabled(true)
        service.setFolder(nil, allowed: true)
        service.setFolder(folder.id, allowed: true)

        let response = try await search(service, limit: 2)
        guard case .success(let result) = response else { return XCTFail("搜索应成功") }
        XCTAssertEqual(result.notes.map(\.id), [grouped.id, ungrouped.id])
        XCTAssertEqual(result.notes.first?.title, "当前标题")
        XCTAssertEqual(result.notes.first?.location, "项目")
        XCTAssertEqual(result.notes.first?.updatedAt, grouped.updatedAt)
        XCTAssertEqual(result.notes.first?.snippet, "相关片段")
        XCTAssertEqual(result.notes.last?.location, "便签集")

        let limited = try await search(service, limit: 1)
        XCTAssertEqual(limited, .success(.init(notes: Array(result.notes.prefix(1)))))
    }

    func testSearchRefusesWaitingResultsAfterDisablingAndReenabling() async throws {
        let library = try TestLibrary()
        let note = library.repository.createNote()
        try library.repository.save()
        let indexHit = hit(note.id, text: "结果")
        var changeAccess: (() -> Void)?
        let service = NoteMCPService(repository: library.repository, defaults: library.defaults) { _, _, _ in
            await Task.yield()
            changeAccess?()
            return .init(mode: .keyword, hits: [indexHit])
        }
        service.setEnabled(true)
        service.setFolder(nil, allowed: true)
        changeAccess = { [weak service] in
            service?.setEnabled(false)
            service?.setEnabled(true)
        }

        let response = try await search(service)
        XCTAssertEqual(response, .failure("QuickNote 的连接设置已变更，请重新搜索。"))
        XCTAssertTrue(service.isEnabled)
    }

    func testSearchRechecksSensitiveAndDeletedNotesAfterRetrievalSuspends() async throws {
        let library = try TestLibrary()
        let sensitive = library.repository.createNote()
        let deleted = library.repository.createNote()
        try library.repository.save()
        let indexHits = [hit(sensitive.id, text: "敏感片段"), hit(deleted.id, text: "删除片段")]
        let service = NoteMCPService(repository: library.repository, defaults: library.defaults) { _, _, _ in
            await Task.yield()
            sensitive.isSensitive = true
            library.repository.delete(deleted)
            return .init(mode: .keyword, hits: indexHits)
        }
        service.setEnabled(true)
        service.setFolder(nil, allowed: true)

        let response = try await search(service)
        XCTAssertEqual(response, .success(.init(notes: [])))
    }

    func testSocketSearchReusesLocalKeywordIndexAndRejectsAfterDisabling() async throws {
        let library = try TestLibrary()
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("qn-mcp-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bridge.sock")
        let note = library.repository.createNote()
        note.title = "测试便签"
        note.plainText = "秋日测试便签内容"
        try library.repository.save()
        let index = SemanticIndex(directory: directory.appendingPathComponent("index"), embedding: { nil })
        index.replaceLibrary(with: [
            .init(noteID: note.id, title: note.title, text: note.plainText, revision: 1)
        ])
        await index.flushPending()
        let documents = NoteDocumentStore(root: directory.appendingPathComponent("Documents"))
        try documents.save(NSAttributedString(string: "测试便签\n已保存的教务正文"), id: note.id)
        let service = NoteMCPService(index: index, repository: library.repository, documents: documents,
                                     defaults: library.defaults)
        try service.start(at: url)
        defer { service.stop() }
        service.setEnabled(true)
        service.setFolder(nil, allowed: true)
        let payload = try JSONEncoder().encode(SearchNotesArguments(query: "秋日"))

        let response = try await socketRequest(payload, at: url)
        guard case .success(let result) = response else { return XCTFail("socket 搜索应成功") }
        XCTAssertEqual(result.notes.map(\.id), [note.id])
        XCTAssertEqual(result.notes.first?.snippet, note.plainText)
        let versionedSearch = try JSONEncoder().encode(MCPReadRequest.search(SearchNotesArguments(query: "秋日")))
        let versionedResponse = try await socketRequest(versionedSearch, at: url)
        XCTAssertEqual(versionedResponse, response)
        let readPayload = try JSONEncoder().encode(MCPReadRequest.read(.init(id: note.id)))
        let bodyResponse = try await socketRequest(readPayload, at: url)
        guard case .read(let body) = bodyResponse else { return XCTFail("socket 应返回已保存的 RTFD 正文") }
        XCTAssertTrue(body.markdown.contains("已保存的教务正文"))

        let invalid = try await socketRequest(Data(#"{"limit":99}"#.utf8), at: url)
        guard case .failure = invalid else { return XCTFail("应用端应拒绝非法参数") }

        service.setEnabled(false)
        let disabled = try await socketRequest(payload, at: url)
        XCTAssertEqual(disabled, .failure("QuickNote 的 Codex 连接已关闭。"))
    }

    func testReadChecksFolderAndSensitivityBeforeLoadingSavedDocument() async throws {
        let library = try TestLibrary()
        let allowed = try library.repository.createFolder(named: "教务")
        let other = try library.repository.createFolder(named: "其他")
        let note = library.repository.createNote()
        let sensitive = library.repository.createNote()
        let hidden = library.repository.createNote()
        for item in [note, sensitive] { library.repository.move(item, to: allowed) }
        library.repository.move(hidden, to: other)
        sensitive.isSensitive = true
        try library.repository.save()
        var loadedIDs: [UUID] = []
        let service = NoteMCPService(repository: library.repository, defaults: library.defaults, loadDocument: { id in
            loadedIDs.append(id)
            return NSAttributedString(string: "真实正文")
        }) { _, _, _ in .init(mode: .keyword, hits: []) }
        service.setEnabled(true)
        service.setFolder(allowed.id, allowed: true)
        for id in [sensitive.id, hidden.id, UUID()] {
            let response = try await read(service, id: id)
            XCTAssertEqual(response, .failure("找不到可读取的便签。"))
        }
        XCTAssertTrue(loadedIDs.isEmpty)
        let accepted = try await read(service, id: note.id)
        guard case .read(let result) = accepted else { return XCTFail("应返回授权正文") }
        XCTAssertEqual(result.markdown, "真实正文")
        library.repository.move(note, to: other)
        let moved = try await read(service, id: note.id)
        XCTAssertEqual(moved, .failure("找不到可读取的便签。"))
        XCTAssertEqual(loadedIDs, [note.id])
    }

    func testSearchDiscardsResultsWhenFolderGrantIsRevokedWhileWaiting() async throws {
        let library = try TestLibrary()
        let folder = try library.repository.createFolder(named: "教务")
        let note = library.repository.createNote()
        library.repository.move(note, to: folder)
        try library.repository.save()
        let ranked = [hit(note.id, text: "授权片段")]
        let folderID = folder.id
        var revoke: (() -> Void)?
        let service = NoteMCPService(repository: library.repository, defaults: library.defaults) { _, _, _ in
            await Task.yield()
            revoke?()
            return .init(mode: .keyword, hits: ranked)
        }
        service.setEnabled(true)
        service.setFolder(folderID, allowed: true)
        revoke = { [weak service] in service?.setFolder(folderID, allowed: false) }
        let result = try await search(service)
        XCTAssertEqual(result, .failure("QuickNote 的连接设置已变更，请重新搜索。"))
    }

    func testSelectAllGrantsCurrentFoldersAndInboxButNeverSensitiveNotes() async throws {
        let library = try TestLibrary()
        let folder = try library.repository.createFolder(named: "教务")
        let note = library.repository.createNote()
        let sensitive = library.repository.createNote()
        library.repository.move(sensitive, to: folder)
        sensitive.isSensitive = true
        try library.repository.save()
        let hits = [hit(sensitive.id, text: "敏感"), hit(note.id, text: "便签集")]
        let service = NoteMCPService(repository: library.repository, defaults: library.defaults,
                                     loadDocument: { _ in NSAttributedString(string: "正文") }) { _, _, ids in
            XCTAssertEqual(ids, [note.id])
            return .init(mode: .keyword, hits: hits)
        }
        service.setAllFolders([folder.id], allowed: true)
        let futureFolder = try library.repository.createFolder(named: "以后")
        XCTAssertFalse(service.readScope.includes(futureFolder.id))
        XCTAssertTrue(service.readScope.includes(folder.id))
        XCTAssertTrue(service.readScope.includes(nil))

        let result = try await search(service)
        guard case .success(let searchResult) = result else { return XCTFail("搜索应成功") }
        XCTAssertEqual(searchResult.notes.map(\.id), [note.id])
        let privateRead = try await read(service, id: sensitive.id)
        XCTAssertEqual(privateRead, .failure("找不到可读取的便签。"))
        service.setAllFolders([folder.id, futureFolder.id], allowed: false)
        XCTAssertTrue(service.readScope.isEmpty)
    }

    private func read(_ service: NoteMCPService, id: UUID) async throws -> MCPBridgeResponse {
        let payload = try JSONEncoder().encode(MCPReadRequest.read(.init(id: id)))
        var result: MCPBridgeResponse?
        await service.handle(payload) { result = $0 }
        return try XCTUnwrap(result)
    }

    private func search(_ service: NoteMCPService, limit: Int = 10) async throws -> MCPBridgeResponse {
        let payload = try JSONEncoder().encode(SearchNotesArguments(query: "相关", limit: limit))
        var response: MCPBridgeResponse?
        await service.handle(payload) { response = $0 }
        return try XCTUnwrap(response)
    }

    private func socketRequest(_ payload: Data, at url: URL) async throws -> MCPBridgeResponse {
        try await Task.detached {
            let data = try UnixSocket.request(payload, at: url)
            return try JSONDecoder().decode(MCPBridgeResponse.self, from: data)
        }.value
    }

    private func hit(_ id: UUID, text: String) -> NoteIndexHit {
        .init(
            chunk: .init(noteID: id, title: "旧索引标题", text: text,
                         range: NSRange(location: 0, length: text.utf16.count), revision: 1),
            score: 1, keywordScore: 1, cosineSimilarity: nil
        )
    }

    @MainActor
    private final class TestLibrary {
        private let container: ModelContainer
        let repository: NoteRepository
        let defaults = MemoryDefaults()

        init() throws {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            container = try ModelContainer(for: NoteRecord.self, NoteFolder.self, configurations: configuration)
            repository = NoteRepository(context: container.mainContext)
        }
    }

    private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
        private let lock = NSLock()
        private var flags: [String: Bool] = [:]
        private var lists: [String: [String]] = [:]

        override func object(forKey defaultName: String) -> Any? {
            lock.withLock { flags[defaultName] }
        }

        override func stringArray(forKey defaultName: String) -> [String]? {
            lock.withLock { lists[defaultName] }
        }

        override func set(_ value: Any?, forKey defaultName: String) {
            lock.withLock { lists[defaultName] = value as? [String] }
        }

        override func set(_ value: Bool, forKey defaultName: String) {
            lock.withLock { flags[defaultName] = value }
        }
    }
}
