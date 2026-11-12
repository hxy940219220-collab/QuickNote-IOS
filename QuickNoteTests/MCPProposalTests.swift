import AppKit
import SwiftData
import XCTest
@testable import QuickNote

@MainActor
final class MCPProposalTests: XCTestCase {
    func testAppendIsPendingUntilConfirmedThenAppliesExactlyOnce() async throws {
        let fixture = try Fixture()
        let note = try fixture.makeNote("原正文")
        let result = try await fixture.append(note.id, markdown: "**补充**")
        XCTAssertEqual(result.status, .pending)
        XCTAssertEqual(try fixture.documents.load(id: note.id).string, "原正文")
        try fixture.service.confirmProposal(result.proposalID)
        XCTAssertEqual(try fixture.documents.load(id: note.id).string, "原正文\n补充")
        let status = try await fixture.status(result.proposalID)
        XCTAssertEqual(status.status, .applied)
        XCTAssertThrowsError(try fixture.service.confirmProposal(result.proposalID))
        XCTAssertEqual(try fixture.documents.load(id: note.id).string, "原正文\n补充")
    }

    func testAppendAfterHeadingUsesUTF16PositionAndRejectsAmbiguousTitle() async throws {
        let fixture = try Fixture()
        let document = NoteMarkdownImporter.richText(from: "# 🗂教务\n## 进展\n原记录")
        let note = try fixture.makeNote(document)
        let proposal = try await fixture.append(note.id, markdown: "新增", position: "after_heading:进展")
        try fixture.service.confirmProposal(proposal.proposalID)
        XCTAssertEqual(try fixture.documents.load(id: note.id).string, "🗂教务\n进展\n新增\n原记录")

        let duplicate = try fixture.makeNote(NoteMarkdownImporter.richText(from: "# 教务\n## 进展\n## 进展"))
        let invalid = try await fixture.request(.append(
            .init(id: duplicate.id, markdown: "不应写入", position: "after_heading:进展"), client: "Codex"
        ))
        guard case .failure = invalid else { return XCTFail("重复标题应拒绝提议") }
        XCTAssertTrue(fixture.service.proposals.pending.isEmpty)
    }

    func testEditingNoteInvalidatesExistingProposal() async throws {
        let fixture = try Fixture()
        let note = try fixture.makeNote("原正文")
        try fixture.session.open(note)
        let proposal = try await fixture.append(note.id, markdown: "旧提议")
        fixture.session.update(document: NSAttributedString(string: "用户编辑"), cursorLocation: 0)
        try fixture.session.flush()
        XCTAssertThrowsError(try fixture.service.confirmProposal(proposal.proposalID))
        let status = try await fixture.status(proposal.proposalID)
        XCTAssertEqual(status.status, .rejected)
        XCTAssertEqual(try fixture.documents.load(id: note.id).string, "用户编辑")
    }

    func testRejectedAndExpiredProposalsCannotWrite() async throws {
        let fixture = try Fixture()
        let note = try fixture.makeNote("原正文")
        let rejected = try await fixture.append(note.id, markdown: "拒绝")
        let expired = try await fixture.append(note.id, markdown: "过期")
        fixture.service.rejectProposal(rejected.proposalID)
        let rejectedStatus = try await fixture.status(rejected.proposalID)
        fixture.clock.date.addTimeInterval(MCPProposalStore.lifetime)
        let expiredStatus = try await fixture.status(expired.proposalID)
        XCTAssertEqual(rejectedStatus.status, .rejected)
        XCTAssertEqual(expiredStatus.status, .expired)
        XCTAssertThrowsError(try fixture.service.confirmProposal(rejected.proposalID))
        XCTAssertThrowsError(try fixture.service.confirmProposal(expired.proposalID))
        XCTAssertEqual(try fixture.documents.load(id: note.id).string, "原正文")
    }

    func testScopeRevocationAndSensitiveTargetsPreventWriting() async throws {
        let fixture = try Fixture()
        let note = try fixture.makeNote("原正文")
        let pending = try await fixture.append(note.id, markdown: "授权随后撤销")
        fixture.service.setFolder(nil, allowed: false)
        fixture.service.setFolder(nil, allowed: true)
        XCTAssertThrowsError(try fixture.service.confirmProposal(pending.proposalID))

        let pendingSensitive = try await fixture.append(note.id, markdown: "将标记敏感")
        try fixture.session.setSensitive(true, for: note)
        XCTAssertThrowsError(try fixture.service.confirmProposal(pendingSensitive.proposalID))
        let blocked = try await fixture.request(.append(.init(id: note.id, markdown: "不可写", position: nil), client: "Codex"))
        guard case .failure = blocked else { return XCTFail("敏感便签不得提交提议") }
        XCTAssertEqual(try fixture.documents.load(id: note.id).string, "原正文")
    }

    func testWriteSwitchDefaultsOffAndBlocksAppendAndCreate() async throws {
        let fixture = try Fixture(enableWriting: false)
        let note = try fixture.makeNote("原正文")
        XCTAssertFalse(fixture.service.isWriteEnabled)
        let requests: [MCPProposalRequest] = [
            .append(.init(id: note.id, markdown: "正文", position: nil), client: "Codex"),
            .create(.init(title: "测试", markdown: "正文", folderID: nil), client: "Codex")
        ]
        for request in requests {
            let result = try await fixture.request(request)
            XCTAssertEqual(result, .failure("QuickNote 的写入提议已关闭。"))
        }
        XCTAssertTrue(fixture.service.proposals.pending.isEmpty)
    }

    func testCreateWritesInGrantedFolderOnlyAfterConfirmation() async throws {
        let fixture = try Fixture()
        let folder = try fixture.repository.createFolder(named: "授权项目")
        try fixture.repository.save()
        let request = MCPProposalRequest.create(.init(title: "交付", markdown: "正文", folderID: folder.id), client: "Codex")
        let blocked = try await fixture.request(request)
        guard case .failure = blocked else { return XCTFail("未授权文件夹应拒绝") }

        fixture.service.setFolder(folder.id, allowed: true)
        let proposal = try await fixture.proposal(request)
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertTrue(try fixture.repository.allNotes().isEmpty)
        try fixture.service.confirmProposal(proposal.proposalID)
        let note = try XCTUnwrap(fixture.repository.allNotes().first)
        XCTAssertEqual(note.folderID, folder.id)
        XCTAssertEqual(note.title, "交付")
        XCTAssertEqual(try fixture.documents.load(id: note.id).string, "交付\n正文")
        XCTAssertThrowsError(try fixture.service.confirmProposal(proposal.proposalID))
        XCTAssertEqual(try fixture.repository.allNotes().count, 1)
    }

    func testSaveFailureAfterCreateIsConsumedAndRetryDoesNotCreateDuplicate() async throws {
        let fixture = try Fixture()
        let proposal = try await fixture.proposal(.create(
            .init(title: "交付", markdown: "正文", folderID: nil), client: "Codex"
        ))
        fixture.clock.failNextSave = true
        XCTAssertThrowsError(try fixture.service.confirmProposal(proposal.proposalID)) {
            XCTAssertTrue($0 is NoteContentAppliedError)
        }
        let pendingSave = try await fixture.status(proposal.proposalID)
        XCTAssertEqual(pendingSave.status, .applied)
        XCTAssertEqual(pendingSave.savePending, true)
        XCTAssertThrowsError(try fixture.service.confirmProposal(proposal.proposalID))
        fixture.session.retrySave()
        let saved = try await fixture.status(proposal.proposalID)
        XCTAssertNil(saved.savePending)
        let notes = try fixture.repository.allNotes()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(try fixture.documents.load(id: try XCTUnwrap(notes.first).id).string, "交付\n正文")
    }

    func testSocketReturnsPendingThenAppliedForAConfirmedAppend() async throws {
        let fixture = try Fixture()
        let note = try fixture.makeNote("初始")
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("qn-proposal-ipc-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("bridge.sock")
        try fixture.service.start(at: socket)
        defer { fixture.service.stop() }
        let request = MCPProposalRequest.append(.init(id: note.id, markdown: "通过连接追加", position: nil),
                                                client: "测试客户端")
        let pending = try await socketResult(request, socket: socket)
        XCTAssertEqual(pending.status, .pending)
        XCTAssertEqual(fixture.service.proposals.pending.first?.client, "测试客户端")
        XCTAssertEqual(try fixture.documents.load(id: note.id).string, "初始")

        try fixture.service.confirmProposal(pending.proposalID)
        let applied = try await socketResult(.status(.init(proposalID: pending.proposalID)), socket: socket)
        XCTAssertEqual(applied.status, .applied)
        XCTAssertEqual(try fixture.documents.load(id: note.id).string, "初始\n通过连接追加")
    }

    private func socketResult(_ request: MCPProposalRequest, socket: URL) async throws -> MCPProposalResult {
        try await Task.detached {
            let data = try UnixSocket.request(JSONEncoder().encode(request), at: socket)
            let reply = try JSONDecoder().decode(MCPBridgeResponse.self, from: data)
            guard case .proposal(let result) = reply else { throw CocoaError(.coderInvalidValue) }
            return result
        }.value
    }

    private final class Clock {
        var date = Date(timeIntervalSince1970: 100)
        var failNextSave = false
    }

    @MainActor private final class Fixture {
        private let container: ModelContainer
        private let directory: URL
        let clock = Clock()
        let repository: NoteRepository
        let documents: NoteDocumentStore
        let session: NoteSession
        let service: NoteMCPService

        init(enableWriting: Bool = true) throws {
            directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("qn-proposals-\(UUID())", isDirectory: true)
            container = try ModelContainer(for: NoteRecord.self, NoteFolder.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            repository = NoteRepository(context: container.mainContext)
            documents = NoteDocumentStore(root: directory)
            let defaults = MemoryDefaults()
            session = NoteSession(repository: repository, documents: documents, saveRepository: { [repository, clock] in
                if clock.failNextSave {
                    clock.failNextSave = false
                    throw CocoaError(.fileWriteUnknown)
                }
                try repository.save()
            }, defaults: defaults)
            service = NoteMCPService(repository: repository, defaults: defaults, session: session,
                proposals: MCPProposalStore(now: { [clock] in clock.date })) { _, _, _ in .init(mode: .keyword, hits: []) }
            service.setFolder(nil, allowed: true)
            if enableWriting { service.setWriteEnabled(true) }
        }

        isolated deinit { try? FileManager.default.removeItem(at: directory) }

        func makeNote(_ text: String) throws -> NoteRecord { try makeNote(NSAttributedString(string: text)) }

        func makeNote(_ content: NSAttributedString) throws -> NoteRecord {
            let note = repository.createNote()
            note.title = content.string.components(separatedBy: .newlines).first ?? "测试"
            try documents.save(content, id: note.id)
            try repository.save()
            return note
        }

        func append(_ id: UUID, markdown: String, position: String? = nil) async throws -> MCPProposalResult {
            try await proposal(.append(.init(id: id, markdown: markdown, position: position), client: "Codex"))
        }

        func status(_ id: UUID) async throws -> MCPProposalResult {
            try await proposal(.status(.init(proposalID: id)))
        }

        func proposal(_ request: MCPProposalRequest) async throws -> MCPProposalResult {
            let reply = try await self.request(request)
            guard case .proposal(let result) = reply else {
                XCTFail("期望提议状态，实际为 \(reply)")
                throw CocoaError(.coderInvalidValue)
            }
            return result
        }

        func request(_ request: MCPProposalRequest) async throws -> MCPBridgeResponse {
            var response: MCPBridgeResponse?
            let data = try JSONEncoder().encode(request)
            await service.handle(data) { response = $0 }
            return try XCTUnwrap(response)
        }
    }

    private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Any] = [:]
        override func object(forKey key: String) -> Any? { lock.withLock { values[key] } }
        override func stringArray(forKey key: String) -> [String]? { lock.withLock { values[key] as? [String] } }
        override func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
        override func set(_ value: Bool, forKey key: String) { lock.withLock { values[key] = value } }
    }
}
