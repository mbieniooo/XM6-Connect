import CoreFoundation
import Darwin
import Foundation
import SonyHeadphonesKit

/// Line-oriented AF_UNIX server.  It owns no main-actor state: a status reply reads a
/// locked snapshot, and a command is posted to the main queue, whose own reply a client
/// worker waits for, at most `commandReplyTimeout`.
public final class UnixIPCServer {
    public typealias MainDispatch = (@escaping () -> Void) -> Void
    public enum AcceptFailureAction: Equatable { case ignore, retry, suspend }
    public static func acceptFailureAction(for error: Int32) -> AcceptFailureAction {
        switch error { case ECONNABORTED: return .retry; case EMFILE, ENFILE: return .suspend; default: return .ignore }
    }

    private let path: String
    private let snapshot: AgentStateSnapshot
    private let commandHandler: (IPCRequest) -> AgentReply
    private let refreshHandler: ((@escaping (AgentReply) -> Void) -> Void)?
    private let mainDispatch: MainDispatch
    // Test-only synchronization hook at the exact boundary before a client performs
    // its blocking line read. It is nil in production and has no behavioral effect.
    private let beforeClientReadForTesting: (() -> Void)?
    // Test-only non-blocking accept failure injection. It is nil in production.
    private let acceptErrorForTesting: (() -> Int32?)?
    private let clientReadDeadline: TimeInterval
    private let commandReplyTimeout: TimeInterval
    private let queue = DispatchQueue(label: "io.github.mbieniooo.xm6connect.ipc", qos: .utility)
    private var listener: DispatchSourceRead?
    private var fd: Int32 = -1
    private var lockFD: Int32 = -1
    private var ownsSocketPath = false
    private var acceptSuspended = false

    public init(
        path: String,
        snapshot: AgentStateSnapshot,
        commandHandler: @escaping (IPCRequest) -> AgentReply,
        refreshHandler: ((@escaping (AgentReply) -> Void) -> Void)? = nil,
        mainDispatch: @escaping MainDispatch = { work in DispatchQueue.main.async(execute: work) },
        beforeClientReadForTesting: (() -> Void)? = nil,
        acceptErrorForTesting: (() -> Int32?)? = nil,
        clientReadDeadline: TimeInterval = 2,
        commandReplyTimeout: TimeInterval = 1
    ) {
        self.path = path; self.snapshot = snapshot
        self.commandHandler = commandHandler; self.mainDispatch = mainDispatch
        self.refreshHandler = refreshHandler
        self.beforeClientReadForTesting = beforeClientReadForTesting
        self.acceptErrorForTesting = acceptErrorForTesting
        self.clientReadDeadline = clientReadDeadline
        self.commandReplyTimeout = commandReplyTimeout
    }
    deinit { stopLocked() }

    public func start() throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockPath = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("agent.lock").path
        lockFD = open(lockPath, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; _ = close(lockFD); lockFD = -1
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EWOULDBLOCK)
        }
        var started = false
        defer { if !started { closeUnstarted() } }
        _ = unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        // A restrictive umask closes the bind-to-chmod window; chmod below is before
        // listen so a client can never connect using default socket permissions.
        let previousMask = umask(S_IRWXG | S_IRWXO)
        let result = withUnixSocketAddress(path) { bind(fd, $0, $1) }
        umask(previousMask)
        guard let result else { throw POSIXError(.ENAMETOOLONG) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard chmod(path, S_IRUSR | S_IWUSR) == 0, listen(fd, 16) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        ownsSocketPath = true
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        let listenFD = fd
        source.setCancelHandler { _ = close(listenFD) }
        queue.sync { listener = source }
        source.resume()
        started = true
    }
    public func stop() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync { stopLocked() }
    }

    private func stopLocked() {
        if acceptSuspended { listener?.resume(); acceptSuspended = false }
        listener?.cancel(); listener = nil
        fd = -1
        if ownsSocketPath { _ = unlink(path); ownsSocketPath = false }
        if lockFD >= 0 { _ = close(lockFD); lockFD = -1 }
    }

    private func closeUnstarted() {
        if fd >= 0 { _ = close(fd); fd = -1 }
        _ = unlink(path)
        if lockFD >= 0 { _ = close(lockFD); lockFD = -1 }
    }

    private func acceptPending() {
        while true {
            let client: Int32
            if let error = acceptErrorForTesting?() {
                errno = error
                client = -1
            } else {
                client = accept(fd, nil, nil)
            }
            guard client >= 0 else {
                switch Self.acceptFailureAction(for: errno) {
                case .retry: continue
                case .suspend: suspendAcceptBriefly(); return
                case .ignore: return
                }
            }
            // An idle peer gets a bounded read and its own transient worker, so it
            // cannot starve accepts or status replies from other clients.
            let flags = fcntl(client, F_GETFL)
            if flags >= 0 { _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let readDeadline = Date().addingTimeInterval(clientReadDeadline)
            let hook = beforeClientReadForTesting
            DispatchQueue(label: "io.github.mbieniooo.xm6connect.ipc.client", qos: .utility).async { [weak self] in
                hook?()
                guard let self else { _ = close(client); return }
                self.readOneLine(client, deadline: readDeadline)
            }
        }
    }

    private func suspendAcceptBriefly() {
        guard !acceptSuspended, let listener else { return }
        acceptSuspended = true
        listener.suspend()
        queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard let self, self.acceptSuspended else { return }
            self.acceptSuspended = false
            self.listener?.resume()
        }
    }
    private func readOneLine(_ client: Int32, deadline: Date) {
        defer { _ = close(client) }
        var buffer = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count <= IPCRequest.maximumLineBytes {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            var timeout = timeval(tv_sec: Int(remaining), tv_usec: Int32((remaining - Double(Int(remaining))) * 1_000_000))
            if timeout.tv_sec == 0 && timeout.tv_usec == 0 { timeout.tv_usec = 1 }
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let count = Darwin.read(client, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(chunk, count: count)
            if let newline = buffer.firstIndex(of: 0x0a) {
                let request = Data(buffer.prefix(upTo: newline))
                if case .success(.refresh) = IPCRequest.parse(request), let refreshHandler {
                    let lock = NSLock(), done = DispatchSemaphore(value: 0)
                    var reply: AgentReply?
                    refreshHandler { value in lock.lock(); reply = value; lock.unlock(); done.signal() }
                    _ = done.wait(timeout: .now() + .milliseconds(4_200))
                    lock.lock(); let result = reply ?? snapshotReply(stale: true); lock.unlock()
                    _ = Self.writeReply(result, to: client)
                } else {
                    _ = Self.writeReply(reply(for: request), to: client)
                }
                return
            }
        }
    }

    /// Test seam and the production reply decision.  A status/malformed request never
    /// invokes `mainDispatch`.  A command runs once through `mainDispatch`, and the client
    /// gets that run's own reply (its error, its `stale`): at once when `mainDispatch` ran
    /// it synchronously, else after a wait of at most `commandReplyTimeout`.  The main
    /// thread never waits for the main queue; it, and a worker whose wait timed out, get the
    /// snapshot marked stale.  A run that finishes after the timeout stores a reply nobody
    /// reads and never touches the client.
    public func reply(for data: Data) -> AgentReply {
        switch IPCRequest.parse(data) {
        case .success(.status): return snapshotReply()
        case .success(let command):
            let lock = NSLock(), done = DispatchSemaphore(value: 0)
            var reply: AgentReply?
            mainDispatch { [commandHandler] in
                let value = commandHandler(command)
                lock.lock(); reply = value; lock.unlock()
                done.signal()
            }
            lock.lock(); let immediate = reply; lock.unlock()
            if let immediate { return immediate }
            if Thread.isMainThread { return snapshotReply(stale: true) }
            _ = done.wait(timeout: .now() + commandReplyTimeout)
            lock.lock(); let waited = reply; lock.unlock()
            return waited ?? snapshotReply(stale: true)
        case .failure(let error): return snapshotReply(error: error.description)
        }
    }

    private func snapshotReply(error: String? = nil, stale: Bool = false) -> AgentReply {
        // A connecting state is a lease acquisition in progress, not a fault. One shared
        // mapping keeps snapshot replies and the agent's own replies in agreement.
        let state = snapshot.load()
        return AgentReply(state: state, error: error, ownership: AgentLeaseOwnership.forConnectionStatus(state.connectionStatus).rawValue, stale: stale)
    }

    /// Returns false on a closed/failed peer.  `SO_NOSIGPIPE` is set here as a second
    /// line of defence for callers of this seam as well as accepted clients.
    @discardableResult public static func writeReply(_ reply: AgentReply, to fd: Int32) -> Bool {
        disableSIGPIPE(on: fd)
        guard var data = try? JSONEncoder.xm6Connect.encode(reply) else { return false }
        data.append(0x0a)
        return write(data, to: fd)
    }

    private static func disableSIGPIPE(on fd: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
    private static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            // MSG_NOSIGNAL makes the writer safe even in an isolated test process
            // before XM6ConnectAgent main installs its process-wide SIGPIPE ignore.
            return Darwin.send(fd, base, bytes.count, Int32(MSG_NOSIGNAL)) == bytes.count
        }
    }
}
