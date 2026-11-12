import AppKit
import Combine

struct MCPProposalCard: Identifiable {
    enum Target {
        case append(id: UUID, folderID: UUID?, revision: Int, offset: Int?)
        case create(folderID: UUID?)

        var folderID: UUID? {
            switch self {
            case .append(_, let folderID, _, _), .create(let folderID): folderID
            }
        }

        var noteID: UUID? {
            guard case .append(let id, _, _, _) = self else { return nil }
            return id
        }
    }

    let id = UUID()
    let target: Target
    let title: String
    let location: String
    let client: String
    let markdown: String
    let expiresAt: Date
}

@MainActor
final class MCPProposalStore: ObservableObject {
    static let lifetime: TimeInterval = 24 * 60 * 60
    static let maximumPending = 32

    @Published private(set) var pending: [MCPProposalCard] = []
    var pendingCountChanged: ((Int) -> Void)?
    private var finished: [UUID: (result: MCPProposalResult, expiresAt: Date)] = [:]
    private var expirationTask: Task<Void, Never>?
    private let now: () -> Date

    init(now: @escaping () -> Date = { .now }) {
        self.now = now
    }

    isolated deinit { expirationTask?.cancel() }

    func enqueue(
        target: MCPProposalCard.Target, title: String, location: String, client: String, markdown: String
    ) throws -> MCPProposalResult {
        expire()
        guard pending.count < Self.maximumPending, finished.count + pending.count < 256 else {
            throw MCPToolFailure(message: "写入提议已达上限，请先处理待确认提议或稍后重试。")
        }
        let card = MCPProposalCard(target: target, title: title, location: location,
                                   client: MCPProposalValidation.clientName(client), markdown: markdown,
                                   expiresAt: now().addingTimeInterval(Self.lifetime))
        pending.append(card)
        pendingCountChanged?(pending.count)
        scheduleExpiration()
        return .init(proposalID: card.id, status: .pending)
    }

    func status(_ id: UUID) -> MCPProposalResult? {
        expire()
        if let result = finished[id]?.result { return result }
        return pending.contains { $0.id == id } ? .init(proposalID: id, status: .pending) : nil
    }

    func clearCompletedSaveWarnings() {
        for id in Array(finished.keys) where finished[id]?.result.savePending == true {
            finished[id]?.result.savePending = nil
        }
    }

    func card(_ id: UUID) -> MCPProposalCard? {
        expire()
        return pending.first { $0.id == id }
    }

    func finish(_ id: UUID, as status: MCPProposalStatus, savePending: Bool? = nil) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index)
        remember(id, as: status, savePending: savePending)
        pendingCountChanged?(pending.count)
        scheduleExpiration()
    }

    func reject(where shouldReject: (MCPProposalCard) -> Bool) {
        expire()
        let rejected = pending.filter(shouldReject)
        guard !rejected.isEmpty else { return }
        let ids = Set(rejected.map(\.id))
        pending.removeAll { ids.contains($0.id) }
        for id in ids { remember(id, as: .rejected) }
        pendingCountChanged?(pending.count)
        scheduleExpiration()
    }

    private func remember(_ id: UUID, as status: MCPProposalStatus, savePending: Bool? = nil) {
        finished[id] = (.init(proposalID: id, status: status, savePending: savePending),
                        now().addingTimeInterval(Self.lifetime))
    }

    private func expire() {
        let time = now()
        finished = finished.filter { $0.value.expiresAt > time }
        let expired = pending.filter { $0.expiresAt <= time }
        guard !expired.isEmpty else { return }
        pending.removeAll { $0.expiresAt <= time }
        for card in expired { remember(card.id, as: .expired) }
        pendingCountChanged?(pending.count)
        scheduleExpiration()
    }

    private func scheduleExpiration() {
        expirationTask?.cancel()
        guard let next = pending.map(\.expiresAt).min() else {
            expirationTask = nil
            return
        }
        let delay = max(0.01, next.timeIntervalSince(now()))
        expirationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            self?.expire()
            self?.scheduleExpiration()
        }
    }
}

@MainActor
enum MCPHeadingAnchor {
    static func offset(after heading: String, in document: NSAttributedString) throws -> Int {
        let source = document.string as NSString
        let sizes = [EditorTextStyle.title, .heading, .subheading].map { $0.font.pointSize }
        var offset = 0
        var matches: [Int] = []
        while offset < source.length {
            let paragraph = source.paragraphRange(for: NSRange(location: offset, length: 0))
            let title = source.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
            if title == heading, let font = document.attribute(.font, at: offset, effectiveRange: nil) as? NSFont,
               sizes.contains(where: { abs($0 - font.pointSize) < 0.1 }) {
                matches.append(NSMaxRange(paragraph))
            }
            offset = NSMaxRange(paragraph)
        }
        guard matches.count == 1, let match = matches.first else {
            let message = matches.isEmpty ? "找不到指定标题，请核对标题文字。" : "有多个同名标题，请改用便签末尾。"
            throw MCPToolFailure(message: message)
        }
        return match
    }
}
