import Combine
import Foundation

struct MCPReadScope: Equatable {
    private static let inbox = "inbox"
    private var folders: Set<UUID>
    private var includesInbox: Bool

    init(preference: [String]) {
        self.init(folders: Set(preference.compactMap { UUID(uuidString: $0) }),
                  includesInbox: preference.contains(Self.inbox))
    }

    init(folders: Set<UUID>, includesInbox: Bool) {
        self.folders = folders
        self.includesInbox = includesInbox
    }

    var preference: [String] {
        let ids = folders.map(\.uuidString).sorted()
        return includesInbox ? [Self.inbox] + ids : ids
    }

    var isEmpty: Bool { folders.isEmpty && !includesInbox }

    func includes(_ folderID: UUID?) -> Bool {
        folderID.map { folders.contains($0) } ?? includesInbox
    }

    mutating func set(_ folderID: UUID?, allowed: Bool) {
        if let folderID {
            if allowed { folders.insert(folderID) } else { folders.remove(folderID) }
        } else {
            includesInbox = allowed
        }
    }
}

@MainActor
final class NoteMCPService: ObservableObject {
    private static let enabledKey = "quickNote.mcpSearchEnabled"
    private static let writeKey = "quickNote.mcpWriteProposalsEnabled"
    private static let scopeKey = "quickNote.mcpReadScope"
    private static let unavailableNoteMessage = "找不到可读取的便签。"
    private static let disabledMessage = "QuickNote 的 Codex 连接已关闭。"
    private static let searchFailedMessage = "QuickNote 暂时无法读取搜索结果，请重试。"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isWriteEnabled: Bool
    @Published private(set) var readScope: MCPReadScope
    let proposals: MCPProposalStore
    private let session: NoteSession?
    private let repository: NoteRepository
    private let defaults: UserDefaults
    private let loadDocument: @MainActor (UUID) throws -> NSAttributedString
    private let search: @MainActor (String, Int, Set<UUID>) async -> NoteIndexSearchResult
    private var accessGeneration: UInt64 = 0
    private var listener: UnixSocket.Listener?

    convenience init(
        index: SemanticIndex, repository: NoteRepository, documents: NoteDocumentStore? = nil,
        session: NoteSession? = nil, defaults: UserDefaults = .standard
    ) {
        self.init(repository: repository, defaults: defaults, session: session, loadDocument: { id in
            guard let documents else { throw MCPToolFailure(message: Self.unavailableNoteMessage) }
            return try documents.load(id: id)
        }) { query, limit, allowedIDs in
            await index.searchAvailable(query, limit: limit, allowedNoteIDs: allowedIDs)
        }
    }

    init(
        repository: NoteRepository,
        defaults: UserDefaults,
        session: NoteSession? = nil,
        proposals: MCPProposalStore = MCPProposalStore(),
        loadDocument: @escaping @MainActor (UUID) throws -> NSAttributedString = { _ in
            throw MCPToolFailure(message: "无法读取便签正文。")
        },
        search: @escaping @MainActor (String, Int, Set<UUID>) async -> NoteIndexSearchResult
    ) {
        self.repository = repository
        self.defaults = defaults
        self.session = session
        self.proposals = proposals
        self.loadDocument = loadDocument
        readScope = MCPReadScope(preference: defaults.stringArray(forKey: Self.scopeKey) ?? [])
        self.search = search
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        isWriteEnabled = defaults.object(forKey: Self.writeKey) as? Bool ?? false
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        accessGeneration &+= 1
        defaults.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        if !enabled { proposals.reject { _ in true } }
    }

    func setWriteEnabled(_ enabled: Bool) {
        guard enabled != isWriteEnabled else { return }
        defaults.set(enabled, forKey: Self.writeKey)
        isWriteEnabled = enabled
        if !enabled { proposals.reject { _ in true } }
    }

    func setFolder(_ id: UUID?, allowed: Bool) {
        var scope = readScope
        scope.set(id, allowed: allowed)
        updateReadScope(scope)
    }

    func setAllFolders(_ ids: [UUID], allowed: Bool) {
        updateReadScope(MCPReadScope(folders: allowed ? Set(ids) : [], includesInbox: allowed))
    }

    private func updateReadScope(_ scope: MCPReadScope) {
        guard scope != readScope else { return }
        accessGeneration &+= 1
        defaults.set(scope.preference, forKey: Self.scopeKey)
        readScope = scope
        proposals.reject { !scope.includes($0.target.folderID) }
    }

    func invalidateProposals(for id: UUID) {
        proposals.reject { $0.target.noteID == id }
    }

    func refreshProposalPermissions() {
        guard !proposals.pending.isEmpty, let folders = try? repository.allFolders() else { return }
        let ids = Set(folders.map(\.id))
        proposals.reject { card in
            if let id = card.target.noteID {
                guard let note = try? repository.note(withID: id) else { return true }
                return note.folderID != card.target.folderID || !isReadable(note, folders: ids)
            }
            return !allowsFolder(card.target.folderID, folders: ids)
        }
    }

    func start(at url: URL) throws {
        guard listener == nil else { return }
        listener = try UnixSocket.Listener(url: url) { [weak self] data, reply in
            Task { @MainActor in
                guard let self else { return }
                await self.handle(data) { response in
                    let encoder = JSONEncoder()
                    let encoded = (try? encoder.encode(response))
                        ?? (try? encoder.encode(MCPBridgeResponse.failure(Self.searchFailedMessage)))
                    if let encoded { reply.send(encoded) }
                }
            }
        }
    }

    func stop() {
        accessGeneration &+= 1
        listener?.stop()
        listener = nil
    }

    func handle(_ data: Data, reply: (MCPBridgeResponse) -> Void) async {
        guard isEnabled else { return reply(.failure(Self.disabledMessage)) }
        let decoder = JSONDecoder()
        if let proposal = try? decoder.decode(MCPProposalRequest.self, from: data) {
            return reply(handleProposal(proposal))
        }
        let request: SearchNotesArguments
        switch try? decoder.decode(MCPReadRequest.self, from: data) {
        case .read(let arguments):
            return reply(read(arguments.id))
        case .search(let arguments):
            request = arguments
        case nil:
            // Older helpers send the search parameters directly; apply the same access checks.
            guard let legacy = try? decoder.decode(SearchNotesArguments.self, from: data) else {
                return reply(.failure("搜索参数无效。"))
            }
            request = legacy
        }
        guard !readScope.isEmpty else { return reply(.success(.init(notes: []))) }
        let generation = accessGeneration
        let allowedIDs: Set<UUID>
        do {
            let folders = Set(try repository.allFolders().map(\.id))
            allowedIDs = Set(try repository.allNotes().lazy
                .filter { self.isReadable($0, folders: folders) }.map(\.id))
        } catch {
            return reply(.failure(Self.searchFailedMessage))
        }
        // The index ranks chunks. Allow several hits per note before taking distinct notes.
        let ranked = await search(request.query, request.limit * 8, allowedIDs)
        guard isEnabled else { return reply(.failure(Self.disabledMessage)) }
        guard generation == accessGeneration else {
            return reply(.failure("QuickNote 的连接设置已变更，请重新搜索。"))
        }
        do {
            // Final eligibility, encoding, and the nonblocking socket write run in one actor turn.
            reply(.success(try eligibleResults(ranked.hits, limit: request.limit)))
        } catch {
            reply(.failure(Self.searchFailedMessage))
        }
    }

    private func handleProposal(_ request: MCPProposalRequest) -> MCPBridgeResponse {
        if case .status(let arguments) = request {
            refreshProposalPermissions()
            if session?.hasPendingExternalSave == false { proposals.clearCompletedSaveWarnings() }
            guard let result = proposals.status(arguments.proposalID) else {
                return .failure("找不到这条写入提议，请重新提交。")
            }
            return .proposal(result)
        }
        guard isWriteEnabled, let session else { return .failure("QuickNote 的写入提议已关闭。") }

        do {
            let folders = Dictionary(uniqueKeysWithValues: try repository.allFolders().map { ($0.id, $0.name) })
            let ids = Set(folders.keys)
            switch request {
            case .append(let arguments, let client):
                let position = try arguments.validatedPosition()
                guard let note = try repository.note(withID: arguments.id), isReadable(note, folders: ids) else {
                    return .failure("找不到可提议写入的便签。")
                }
                let offset: Int?
                switch position {
                case .end: offset = nil
                case .afterHeading(let heading):
                    offset = try MCPHeadingAnchor.offset(after: heading, in: session.proposalDocumentSnapshot(for: note.id))
                }
                let target = MCPProposalCard.Target.append(id: note.id, folderID: note.folderID,
                                                           revision: session.contentRevision(for: note.id), offset: offset)
                return .proposal(try proposals.enqueue(
                    target: target, title: Self.boundedText(note.title, maximumBytes: 512),
                    location: position.label, client: client, markdown: arguments.markdown
                ))
            case .create(let arguments, let client):
                let title = try arguments.validatedTitle()
                guard allowsFolder(arguments.folderID, folders: ids) else {
                    return .failure("找不到可提议写入的位置。")
                }
                let folderName = arguments.folderID.flatMap { folders[$0] } ?? "便签集"
                return .proposal(try proposals.enqueue(
                    target: .create(folderID: arguments.folderID), title: title,
                    location: "在「\(Self.boundedText(folderName, maximumBytes: 256))」新建",
                    client: client, markdown: arguments.markdown
                ))
            case .status:
                return .failure("找不到这条写入提议，请重新提交。")
            }
        } catch let failure as MCPToolFailure {
            return .failure(failure.message)
        } catch {
            return .failure("QuickNote 无法准备写入提议，请重试。")
        }
    }

    func rejectProposal(_ id: UUID) {
        if proposals.card(id) != nil { proposals.finish(id, as: .rejected) }
    }

    func confirmProposal(_ id: UUID) throws {
        guard let card = proposals.card(id) else {
            throw MCPToolFailure(message: "这条提议已处理或过期。")
        }
        let folders = try repository.allFolders()
        guard isEnabled, isWriteEnabled, let session,
              allowsFolder(card.target.folderID, folders: Set(folders.map(\.id))) else {
            proposals.finish(id, as: .rejected)
            throw MCPToolFailure(message: "写入授权已变更，请重新提交提议。")
        }
        let content = NoteMarkdownImporter.richText(from: card.markdown, asDocumentStart: false)
        do {
            switch card.target {
            case .append(let noteID, let folderID, let revision, let offset):
                guard let note = try repository.note(withID: noteID), note.isEligibleForAI,
                      note.folderID == folderID, session.contentRevision(for: noteID) == revision else {
                    proposals.finish(id, as: .rejected)
                    throw MCPToolFailure(message: "目标便签或正文已变化，请重新提交提议。")
                }
                let captured = try session.captureImportCursor(for: noteID, at: offset)
                guard captured == revision else {
                    proposals.finish(id, as: .rejected)
                    throw MCPToolFailure(message: "正文已变化，请重新提交提议。")
                }
                try session.importContent(content, into: noteID, at: offset == nil ? .end : .cursor,
                                          expectedRevision: captured)
            case .create(let folderID):
                let folder = folders.first { $0.id == folderID }
                try session.importNewNoteProposal(content, title: card.title, folder: folder)
            }
            proposals.finish(id, as: .applied)
        } catch let failure as NoteContentAppliedError {
            proposals.finish(id, as: .applied, savePending: true)
            throw failure
        }
    }

    private func read(_ id: UUID) -> MCPBridgeResponse {
        do {
            let folders = Set(try repository.allFolders().map(\.id))
            guard let note = try repository.note(withID: id),
                  isReadable(note, folders: folders) else { return .failure(Self.unavailableNoteMessage) }
            let body = NoteMarkdownExporter.export(try loadDocument(id))
            return .read(.init(id: id, title: Self.boundedText(note.title, maximumBytes: 512),
                               markdown: body.markdown, truncated: body.truncated))
        } catch {
            return .failure("QuickNote 无法读取已保存的便签正文。")
        }
    }

    private func isReadable(_ note: NoteRecord, folders: Set<UUID>) -> Bool {
        note.isEligibleForAI && allowsFolder(note.folderID, folders: folders)
    }

    private func allowsFolder(_ id: UUID?, folders: Set<UUID>) -> Bool {
        readScope.includes(id) && (id.map { folders.contains($0) } ?? true)
    }

    private func eligibleResults(_ ranked: [NoteIndexHit], limit: Int) throws -> SearchNotesResult {
        guard !ranked.isEmpty else { return .init(notes: []) }
        let folderNames = Dictionary(uniqueKeysWithValues: try repository.allFolders().map { ($0.id, $0.name) })
        let folders = Set(folderNames.keys)
        var seen = Set<UUID>()
        var results: [SearchNotesResult.Hit] = []
        for hit in ranked where seen.insert(hit.chunk.noteID).inserted {
            guard let note = try repository.note(withID: hit.chunk.noteID), isReadable(note, folders: folders) else { continue }
            let location = note.folderID.flatMap { folderNames[$0] } ?? "便签集"
            // Even with JSON escaping, twenty hits fit in the socket's frame budget.
            results.append(.init(
                id: note.id,
                title: Self.boundedText(note.title, maximumBytes: 512),
                location: Self.boundedText(location, maximumBytes: 256),
                snippet: Self.boundedText(hit.chunk.text, maximumBytes: 1280),
                updatedAt: note.updatedAt
            ))
            if results.count == limit { break }
        }
        return .init(notes: results)
    }

    private static func boundedText(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        let ellipsis = "…"
        var remaining = maximumBytes - ellipsis.utf8.count
        let prefix = text.prefix { character in
            let bytes = String(character).utf8.count
            guard bytes <= remaining else { return false }
            remaining -= bytes
            return true
        }
        return String(prefix) + ellipsis
    }
}
