import Foundation

struct SSEEvent: Sendable, Equatable {
    let data: String
}

enum SSEEventParserError: Error {
    case invalidUTF8
}

/// Retains undecoded bytes until a complete line arrives, including split UTF-8 scalars.
struct SSEEventParser {
    private var lineBytes: [UInt8] = []
    private var dataLines: [String] = []
    private var skipsNextLF = false
    private var isFirstLine = true

    mutating func append(_ data: Data) throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in data {
            if skipsNextLF {
                skipsNextLF = false
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0D:
                if let event = try consumeLine() { events.append(event) }
                skipsNextLF = true
            case 0x0A:
                if let event = try consumeLine() { events.append(event) }
            default:
                lineBytes.append(byte)
            }
        }
        return events
    }

    mutating func finish() throws -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !lineBytes.isEmpty, let event = try consumeLine() { events.append(event) }
        if let event = dispatchEvent() { events.append(event) }
        skipsNextLF = false
        return events
    }

    private mutating func consumeLine() throws -> SSEEvent? {
        guard var line = String(bytes: lineBytes, encoding: .utf8) else {
            throw SSEEventParserError.invalidUTF8
        }
        lineBytes.removeAll(keepingCapacity: true)
        if isFirstLine {
            isFirstLine = false
            if line.first == "\u{FEFF}" { line.removeFirst() }
        }
        if line.isEmpty { return dispatchEvent() }
        if line.first == ":" { return nil }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value.removeFirst() }
        } else {
            field = line[...]
            value = ""
        }
        if field == "data" { dataLines.append(String(value)) }
        return nil
    }

    private mutating func dispatchEvent() -> SSEEvent? {
        guard !dataLines.isEmpty else { return nil }
        let event = SSEEvent(data: dataLines.joined(separator: "\n"))
        dataLines.removeAll(keepingCapacity: true)
        return event
    }
}
