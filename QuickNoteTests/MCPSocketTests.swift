import Darwin
import Foundation
import XCTest
@testable import QuickNote

final class MCPSocketTests: XCTestCase {
    func testRoundTripUsesPrivateDirectoryAndSocket() throws {
        let url = try temporarySocketURL()
        let listener = try UnixSocket.Listener(url: url) { data, reply in
            reply.send(data)
        }
        defer { listener.stop() }

        XCTAssertEqual(try permissions(at: url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(at: url), 0o600)
        let request = Data("测试\n\0".utf8)
        XCTAssertEqual(try UnixSocket.request(request, at: url), request)
    }

    func testClientRejectsMismatchedServerUID() throws {
        let url = try temporarySocketURL()
        let listener = try UnixSocket.Listener(url: url) { _, reply in
            reply.send(Data("unexpected".utf8))
        }
        defer { listener.stop() }

        XCTAssertThrowsError(try UnixSocket.request(Data([0]), at: url, expectedPeerUID: geteuid() &+ 1)) {
            XCTAssertEqual($0 as? UnixSocket.Failure, .permissionDenied)
        }
    }

    func testLargeResponseFitsNonblockingReply() throws {
        let url = try temporarySocketURL()
        let response = Data(repeating: 0x61, count: UnixSocket.maximumPayloadBytes)
        let listener = try UnixSocket.Listener(url: url) { _, reply in
            reply.send(response)
        }
        defer { listener.stop() }

        XCTAssertEqual(try UnixSocket.request(Data([0]), at: url), response)
    }

    func testListenerRejectsMismatchedClientUIDBeforeHandler() throws {
        let url = try temporarySocketURL()
        let listener = try UnixSocket.Listener(url: url, expectedPeerUID: geteuid() &+ 1) { _, reply in
            reply.send(Data("unexpected".utf8))
        }
        defer { listener.stop() }

        XCTAssertThrowsError(try UnixSocket.request(Data([0]), at: url))
    }

    func testAbsentAndStoppedSocketReportAppNotRunning() throws {
        let url = try temporarySocketURL()
        assertAppNotRunning(at: url)

        let listener = try UnixSocket.Listener(url: url) { _, reply in
            reply.send(Data([0]))
        }
        listener.stop()
        listener.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        assertAppNotRunning(at: url)
    }

    func testListenerLeavesExistingActiveSocketIntact() throws {
        let url = try temporarySocketURL()
        let listener = try UnixSocket.Listener(url: url) { data, reply in
            reply.send(data)
        }
        defer { listener.stop() }

        XCTAssertThrowsError(try UnixSocket.Listener(url: url) { _, _ in })
        XCTAssertEqual(try UnixSocket.request(Data([0]), at: url), Data([0]))
    }

    func testListenerLeavesRegularFileIntact() throws {
        let url = try temporarySocketURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let existingFile = Data("fixture".utf8)
        try existingFile.write(to: url)

        XCTAssertThrowsError(try UnixSocket.Listener(url: url) { _, _ in })
        XCTAssertEqual(try Data(contentsOf: url), existingFile)
    }

    func testListenerReclaimsAnOwnedSocketLeftBeforeChmod() throws {
        let url = try temporarySocketURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try leaveStaleSocket(at: url)

        let listener = try UnixSocket.Listener(url: url) { data, reply in
            reply.send(data)
        }
        defer { listener.stop() }

        XCTAssertEqual(try permissions(at: url), 0o600)
        XCTAssertEqual(try UnixSocket.request(Data([0]), at: url), Data([0]))
    }

    func testRejectsOversizedRequestAndOverlongSocketPath() throws {
        let url = try temporarySocketURL()
        XCTAssertThrowsError(try UnixSocket.request(Data(count: UnixSocket.maximumPayloadBytes + 1), at: url)) {
            XCTAssertEqual($0 as? UnixSocket.Failure, .invalidMessage)
        }
        XCTAssertThrowsError(try UnixSocket.request(Data([0]), at: url.appendingPathComponent(String(repeating: "字", count: 60)))) {
            XCTAssertEqual($0 as? UnixSocket.Failure, .invalidPath)
        }
    }

    private func temporarySocketURL() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/QuickNoteMCP-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("m", isDirectory: true).appendingPathComponent("bridge.sock")
    }

    private func permissions(at url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return info.st_mode & 0o777
    }

    private func leaveStaleSocket(at url: URL) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }

        var address = sockaddr_un()
        let path = url.path.utf8CString
        address.sun_len = UInt8(2 + path.count)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withUnsafeBytes { buffer.copyBytes(from: $0) }
        }
        let length = socklen_t(address.sun_len)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length)
            }
        }
        guard bound == 0, chmod(url.path, 0o755) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func assertAppNotRunning(at url: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try UnixSocket.request(Data([0]), at: url), file: file, line: line) {
            XCTAssertEqual($0.localizedDescription, "QuickNote 未运行，请先打开 QuickNote", file: file, line: line)
        }
    }
}
