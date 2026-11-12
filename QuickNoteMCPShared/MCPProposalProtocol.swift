import Foundation

struct AppendProposalArguments: Codable, Equatable, Sendable {
    let id: UUID
    let markdown: String
    let position: String?

    func validatedPosition() throws -> MCPAppendPosition {
        try MCPProposalValidation.markdown(markdown)
        switch position {
        case nil, "end": return .end
        case let value? where value.hasPrefix("after_heading:"):
            let heading = String(value.dropFirst("after_heading:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heading.isEmpty, heading.utf8.count <= 480,
                  heading.rangeOfCharacter(from: .newlines) == nil else { break }
            return .afterHeading(heading)
        default: break
        }
        throw MCPToolFailure(message: "插入位置须为 end 或 after_heading:标题。")
    }
}

enum MCPAppendPosition: Equatable {
    case end
    case afterHeading(String)

    var label: String {
        switch self {
        case .end: "便签末尾"
        case .afterHeading(let heading): "标题「\(heading)」下方"
        }
    }
}

struct CreateProposalArguments: Codable, Equatable, Sendable {
    let title: String
    let markdown: String
    let folderID: UUID?

    func validatedTitle() throws -> String {
        try MCPProposalValidation.markdown(markdown)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, title.utf8.count <= 480,
              title.rangeOfCharacter(from: .newlines) == nil else {
            throw MCPToolFailure(message: "请填写 1–120 字的单行便签标题。")
        }
        return title
    }
}

struct ProposalStatusArguments: Codable, Equatable, Sendable {
    let proposalID: UUID
}

enum MCPProposalRequest: Codable, Equatable, Sendable {
    case append(AppendProposalArguments, client: String)
    case create(CreateProposalArguments, client: String)
    case status(ProposalStatusArguments)
}

enum MCPProposalStatus: String, Codable, Equatable, Sendable {
    case pending, applied, rejected, expired
}

struct MCPProposalResult: Codable, Equatable, Sendable {
    let proposalID: UUID
    let status: MCPProposalStatus
    var savePending: Bool? = nil
}

enum MCPProposalValidation {
    static let maximumMarkdownBytes = 32 * 1024

    static func markdown(_ value: String) throws {
        guard value.utf8.count <= maximumMarkdownBytes,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolFailure(message: "提议正文须有内容，且最多 32 KiB。")
        }
    }

    static func clientName(_ raw: String) -> String {
        let blocked = CharacterSet.controlCharacters.union(.newlines)
        let stripped = raw.components(separatedBy: blocked).joined()
        let name = String(stripped.trimmingCharacters(in: .whitespaces).unicodeScalars.prefix(48))
        return name.isEmpty ? "MCP 客户端" : name
    }
}
