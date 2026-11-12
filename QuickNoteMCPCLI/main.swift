import Darwin
import Foundation

private func bridge(_ arguments: some Encodable) throws -> MCPBridgeResponse {
    let request = try JSONEncoder().encode(arguments)
    let response: Data
    do {
        response = try UnixSocket.request(request, at: UnixSocket.defaultURL())
    } catch {
        throw MCPToolFailure(message: error.localizedDescription)
    }
    guard let reply = try? JSONDecoder().decode(MCPBridgeResponse.self, from: response) else {
        throw MCPToolFailure(message: "无法读取 QuickNote 的响应，请确认已打开匹配版本的 QuickNote。")
    }
    if case .failure(let message) = reply {
        if message == "搜索参数无效。" {
            throw MCPToolFailure(message: "请退出旧版 QuickNote，并打开与辅助程序匹配的版本。")
        }
        throw MCPToolFailure(message: message)
    }
    return reply
}

private func searchNotes(_ arguments: SearchNotesArguments) throws -> SearchNotesResult {
    guard case .success(let result) = try bridge(MCPReadRequest.search(arguments)) else {
        throw MCPToolFailure(message: "QuickNote 返回了无效的搜索结果。")
    }
    return result
}

private func readNote(_ arguments: ReadNoteArguments) throws -> ReadNoteResult {
    guard case .read(let result) = try bridge(MCPReadRequest.read(arguments)) else {
        throw MCPToolFailure(message: "QuickNote 返回了无效的正文结果。")
    }
    return result
}

private func proposal(_ request: MCPProposalRequest) throws -> MCPProposalResult {
    guard case .proposal(let result) = try bridge(request) else {
        throw MCPToolFailure(message: "QuickNote 返回了无效的提议状态。")
    }
    return result
}

var server = MCPProtocol()
var framer = MCPLineFramer()
var buffer = [UInt8](repeating: 0, count: 4_096)

while true {
    let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(STDIN_FILENO, bytes.baseAddress, bytes.count)
    }
    if count == 0 { break }
    if count < 0 {
        if errno == EINTR { continue }
        exit(EXIT_FAILURE)
    }

    for frame in framer.append(Data(buffer.prefix(count))) {
        let response: Data?
        switch frame {
        case .message(let request): response = server.process(request, proposal: proposal, read: readNote, search: searchNotes)
        case .tooLong: response = MCPProtocol.frameTooLong()
        }
        guard var response else { continue }
        response.append(0x0A)
        do {
            try FileHandle.standardOutput.write(contentsOf: response)
        } catch {
            exit(EXIT_FAILURE)
        }
    }
}
