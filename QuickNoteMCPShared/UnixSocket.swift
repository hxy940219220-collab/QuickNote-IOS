import Darwin
import Dispatch
import Foundation

enum UnixSocket {
    static let maximumPayloadBytes = 384 * 1024
    private static let maximumRequestBytes = 256 * 1024
    private static let timeout: DispatchTimeInterval = .seconds(5)

    enum Failure: LocalizedError, Equatable {
        case appNotRunning
        case permissionDenied
        case endpointInUse
        case invalidPath
        case invalidMessage
        case timedOut
        case connectionLost
        case unavailable

        var errorDescription: String? {
            switch self {
            case .appNotRunning: "QuickNote 未运行，请先打开 QuickNote"
            case .permissionDenied: "没有权限连接 QuickNote。"
            case .endpointInUse: "QuickNote 连接已被占用。"
            case .invalidPath: "QuickNote 本机连接路径无效或过长。"
            case .invalidMessage: "QuickNote 本机连接消息无效或过长。"
            case .timedOut: "连接 QuickNote 超时，请重试。"
            case .connectionLost: "QuickNote 连接已断开，请重试。"
            case .unavailable: "暂时无法连接 QuickNote。"
            }
        }

        static func forErrno(_ code: Int32) -> Self {
            switch code {
            case EACCES, EPERM: .permissionDenied
            case ETIMEDOUT: .timedOut
            case ECONNRESET, EPIPE, ENOTCONN: .connectionLost
            default: .unavailable
            }
        }
    }

    static func defaultURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ).appending(path: "QuickNote/MCP/bridge.sock")
    }

    static func request(_ request: Data, at url: URL, expectedPeerUID: uid_t = geteuid()) throws -> Data {
        guard !request.isEmpty, request.count <= maximumRequestBytes else { throw Failure.invalidMessage }
        let address = try socketAddress(for: url)
        let fd = try makeSocket()
        defer { Darwin.close(fd) }
        let deadline = DispatchTime.now() + timeout
        try connect(fd, to: address, deadline: deadline)
        try checkPeer(fd, expectedUID: expectedPeerUID)
        try writeFrame(request, to: fd, deadline: deadline)
        return try readFrame(from: fd, deadline: deadline)
    }

    // One-shot ownership of the sending descriptor. The reader owns a duplicate so closing
    // a reply can interrupt its read without making the reader use a recycled descriptor.
    final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32
        private let deadline: DispatchTime
        private let finished: @Sendable () -> Void

        fileprivate init(descriptor: Int32, deadline: DispatchTime, finished: @escaping @Sendable () -> Void) {
            self.descriptor = descriptor
            self.deadline = deadline
            self.finished = finished
        }

        @discardableResult
        func send(_ payload: Data) -> Bool {
            finish { fd in
                guard DispatchTime.now() < deadline else { return false }
                do {
                    // A bounded nonblocking write lets the app perform its last authorization
                    // check and submit the bytes on the same actor turn.
                    try UnixSocket.writeFrame(payload, to: fd, deadline: nil)
                    return true
                } catch {
                    return false
                }
            }
        }

        fileprivate func close() {
            _ = finish { _ in false }
        }

        private func finish(_ operation: (Int32) -> Bool) -> Bool {
            let result: Bool? = lock.withLock {
                guard descriptor >= 0 else { return nil }
                let success = operation(descriptor)
                if !success { shutdown(descriptor, SHUT_RDWR) }
                Darwin.close(descriptor)
                descriptor = -1
                return success
            }
            guard let result else { return false }
            finished()
            return result
        }

        deinit { close() }
    }

    final class Listener: @unchecked Sendable {
        private let queue = DispatchQueue(label: "QuickNote.MCP.Accept")
        private let binding: Binding
        private let expectedPeerUID: uid_t
        private let handler: @Sendable (Data, Reply) -> Void
        // These values are accessed only on queue.
        private var source: (any DispatchSourceRead)?
        private var clients: [UUID: Reply] = [:]

        init(
            url: URL, expectedPeerUID: uid_t = geteuid(),
            handler: @escaping @Sendable (Data, Reply) -> Void
        ) throws {
            binding = try UnixSocket.bind(to: url)
            self.expectedPeerUID = expectedPeerUID
            self.handler = handler
            queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))


            let fd = binding.descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptConnections() }
            source.setCancelHandler { Darwin.close(fd) }
            self.source = source
            source.resume()
        }

        func stop() {
            queue.sync { stopOnQueue() }
        }

        private func stopOnQueue() {
            guard let source else { return }
            self.source = nil
            source.cancel()
            for reply in clients.values { reply.close() }
            clients.removeAll()
            UnixSocket.unlinkIfSameSocket(binding.path, as: binding.info)
            Darwin.close(binding.lockDescriptor)
        }

        private func acceptConnections() {
            guard source != nil else { return }
            for _ in 0..<16 {
                let fd = accept(binding.descriptor, nil, nil)
                guard fd >= 0 else { return }
                guard clients.count < 8 else {
                    Darwin.close(fd)
                    continue
                }
                do {
                    try UnixSocket.configure(fd)
                    try UnixSocket.checkPeer(fd, expectedUID: expectedPeerUID)
                } catch {
                    Darwin.close(fd)
                    continue
                }
                let reader = fcntl(fd, F_DUPFD_CLOEXEC, 0)
                guard reader >= 0 else {
                    Darwin.close(fd)
                    continue
                }

                let id = UUID()
                let deadline = DispatchTime.now() + UnixSocket.timeout
                let reply = Reply(descriptor: fd, deadline: deadline) { [weak self] in
                    self?.queue.async { [weak self] in self?.clients.removeValue(forKey: id) }
                }
                clients[id] = reply
                queue.asyncAfter(deadline: deadline) { [weak reply] in reply?.close() }
                DispatchQueue.global(qos: .utility).async { [handler] in
                    defer { Darwin.close(reader) }
                    do {
                        let request = try UnixSocket.readFrame(from: reader, deadline: deadline, maximumBytes: UnixSocket.maximumRequestBytes)
                        handler(request, reply)
                    } catch {
                        reply.close()
                    }
                }
            }
        }

        deinit {
            // A final strong reference can be released by the event handler itself.
            if DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self) {
                stopOnQueue()
            } else {
                stop()
            }
        }

        private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    }

    private struct Binding {
        let descriptor: Int32
        let lockDescriptor: Int32
        let path: String
        let info: stat
    }

    private static func bind(to url: URL) throws -> Binding {
        let address = try socketAddress(for: url)
        let path = url.path
        let directory = url.deletingLastPathComponent()
        try ensurePrivateDirectory(directory)

        // Keep the lock inode across restarts. Unlinking a lock file can let a second
        // process lock a new inode while the original lock is still held.
        let lockPath = directory.appending(path: "bridge.lock").path
        let lockFD = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lockFD >= 0 else { throw Failure.forErrno(errno) }
        var lockRetained = false
        defer { if !lockRetained { Darwin.close(lockFD) } }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0,
              lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_uid == geteuid(),
              lockInfo.st_mode & 0o777 == 0o600, lockInfo.st_nlink == 1 else {
            throw Failure.permissionDenied
        }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw Failure.endpointInUse }
        try removeStaleSocket(at: path, address: address)

        let fd = try makeSocket()
        var socketRetained = false
        defer { if !socketRetained { Darwin.close(fd) } }
        guard withSockAddr(address, { Darwin.bind(fd, $0, $1) }) == 0 else {
            throw errno == EADDRINUSE ? Failure.endpointInUse : Failure.forErrno(errno)
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == geteuid() else { throw Failure.permissionDenied }
        defer { if !socketRetained { unlinkIfSameSocket(path, as: info) } }

        // The containing directory already excludes other users, and the socket has
        // mode 0600 before listen makes it available to any client.
        guard chmod(path, 0o600) == 0 else { throw Failure.forErrno(errno) }
        guard listen(fd, 8) == 0 else { throw Failure.forErrno(errno) }
        socketRetained = true
        lockRetained = true
        return Binding(descriptor: fd, lockDescriptor: lockFD, path: path, info: info)
    }

    private static func ensurePrivateDirectory(_ directory: URL) throws {
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            throw Failure.forErrno(errno)
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o700 else { throw Failure.permissionDenied }
    }

    private static func removeStaleSocket(at path: String, address: sockaddr_un) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return }
            throw Failure.forErrno(errno)
        }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() else {
            throw Failure.endpointInUse
        }

        let probe = try makeSocket()
        defer { Darwin.close(probe) }
        do {
            try connect(probe, to: address, deadline: DispatchTime.now() + .milliseconds(150))
        } catch Failure.appNotRunning {
            unlinkIfSameSocket(path, as: info)
            return
        }
        throw Failure.endpointInUse
    }

    private static func unlinkIfSameSocket(_ path: String, as previous: stat) {
        var current = stat()
        if lstat(path, &current) == 0, current.st_mode & S_IFMT == S_IFSOCK,
           current.st_dev == previous.st_dev, current.st_ino == previous.st_ino {
            unlink(path)
        }
    }

    private static func socketAddress(for url: URL) throws -> sockaddr_un {
        guard url.isFileURL else { throw Failure.invalidPath }
        return try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw Failure.invalidPath }
            let count = strlen(path)
            var address = sockaddr_un()
            let size = MemoryLayout.size(ofValue: address.sun_path)
            guard count > 0, count < size else { throw Failure.invalidPath }
            let offset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 2
            address.sun_len = UInt8(offset + count + 1)
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                _ = memcpy(bytes.baseAddress!, path, count + 1)
            }
            return address
        }
    }

    private static func withSockAddr<Result>(
        _ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result
    ) -> Result {
        withUnsafePointer(to: address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(address.sun_len))
            }
        }
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.forErrno(errno) }
        do {
            try configure(fd)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func configure(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            throw Failure.forErrno(errno)
        }
        try setSocketOption(fd, SO_NOSIGPIPE, 1)
        let bufferBytes = Int32(2 * (maximumPayloadBytes + 4))
        try setSocketOption(fd, SO_SNDBUF, bufferBytes)
        try setSocketOption(fd, SO_RCVBUF, bufferBytes)
    }

    private static func setSocketOption(_ fd: Int32, _ option: Int32, _ value: Int32) throws {
        var value = value
        guard setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout.size(ofValue: value))) == 0 else {
            throw Failure.forErrno(errno)
        }
    }

    private static func connect(_ fd: Int32, to address: sockaddr_un, deadline: DispatchTime) throws {
        if withSockAddr(address, { Darwin.connect(fd, $0, $1) }) == 0 { return }
        var result = errno
        if result == EINPROGRESS || result == EINTR {
            try waitFor(fd, events: Int16(POLLOUT), deadline: deadline)
            var length = socklen_t(MemoryLayout.size(ofValue: result))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &result, &length) == 0 else {
                throw Failure.forErrno(errno)
            }
        }
        if result == ENOENT || result == ECONNREFUSED { throw Failure.appNotRunning }
        if result != 0 { throw Failure.forErrno(result) }
    }

    private static func checkPeer(_ fd: Int32, expectedUID: uid_t) throws {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == expectedUID else { throw Failure.permissionDenied }
    }

    private static func checkPayload(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumPayloadBytes else { throw Failure.invalidMessage }
    }

    private static func readFrame(
        from fd: Int32, deadline: DispatchTime, maximumBytes: Int = maximumPayloadBytes
    ) throws -> Data {
        let header = try readBytes(4, from: fd, deadline: deadline)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximumBytes else { throw Failure.invalidMessage }
        return try readBytes(count, from: fd, deadline: deadline)
    }

    private static func readBytes(_ count: Int, from fd: Int32, deadline: DispatchTime) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                try waitFor(fd, events: Int16(POLLIN), deadline: deadline)
                let bytes = recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if bytes > 0 {
                    offset += bytes
                } else if bytes == 0 {
                    throw Failure.connectionLost
                } else if errno != EAGAIN && errno != EINTR {
                    throw Failure.forErrno(errno)
                }
            }
        }
        return data
    }

    private static func writeFrame(_ payload: Data, to fd: Int32, deadline: DispatchTime?) throws {
        try checkPayload(payload)
        var count = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &count) { Data($0) }
        frame.append(payload)
        try frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                if let deadline { try waitFor(fd, events: Int16(POLLOUT), deadline: deadline) }
                let bytes = Darwin.send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if bytes > 0 {
                    offset += bytes
                } else if bytes == 0 {
                    throw Failure.connectionLost
                } else if errno == EAGAIN, deadline == nil {
                    throw Failure.timedOut
                } else if errno != EAGAIN && errno != EINTR {
                    throw Failure.forErrno(errno)
                }
            }
        }
    }

    private static func waitFor(_ fd: Int32, events: Int16, deadline: DispatchTime) throws {
        var status = pollfd(fd: fd, events: events, revents: 0)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { throw Failure.timedOut }
            let milliseconds = (deadline.uptimeNanoseconds - now + 999_999) / 1_000_000
            let result = poll(&status, 1, Int32(milliseconds))
            if result > 0 {
                if status.revents & Int16(POLLNVAL) != 0 { throw Failure.connectionLost }
                return
            }
            if result == 0 { throw Failure.timedOut }
            if errno != EINTR { throw Failure.forErrno(errno) }
        }
    }
}
