import Foundation
import Darwin
import SonyHeadphonesKit
import XM6ConnectAgentCore
import XM6ConnectAppLogic

func testIPCClosedSocketpairWriteDoesNotRaiseSIGPIPE() -> Bool {
    var pair: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return false }
    defer { _ = close(pair[0]); _ = close(pair[1]) }
    _ = close(pair[1])
    // This reaches the production reply writer. Without SO_NOSIGPIPE, its write to
    // the closed peer terminates this very test process with SIGPIPE.
    return !UnixIPCServer.writeReply(AgentReply(state: AgentState()), to: pair[0])
}

private func openUnixSocket(_ path: String, timeoutSeconds: Int = 1) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    // A server that hangs up early must fail the calling test, not kill the suite with SIGPIPE.
    var noSigPipe: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    guard let result = withUnixSocketAddress(path, { connect(fd, $0, $1) }) else { _ = close(fd); return nil }
    guard result == 0 else { _ = close(fd); return nil }
    return fd
}

private func makeUnixListener(_ path: String) -> Int32? {
    _ = unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    guard let bound = withUnixSocketAddress(path, { bind(fd, $0, $1) }) else { _ = close(fd); return nil }
    guard bound == 0, listen(fd, 1) == 0 else { _ = close(fd); return nil }
    return fd
}

func testUnixSocketAddressLimit() -> Bool {
    withUnixSocketAddress(String(repeating: "a", count: 103)) { _, _ in true } == true
        && withUnixSocketAddress(String(repeating: "a", count: 104)) { _, _ in true } == nil
}

private final class TestFDObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int32] = []
    func append(_ value: Int32) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [Int32] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class WeakServerProbe {
    weak var value: UnixIPCServer?
}

private func listeningUnixSocketDescriptors(at path: String) -> [Int32] {
    var matches: [Int32] = []
    for fd in Int32(0)..<getdtablesize() {
        var accepting: Int32 = 0
        var acceptingLength = socklen_t(MemoryLayout<Int32>.size)
        let isListener: Bool
        if getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &accepting, &acceptingLength) == 0 {
            isListener = accepting == 1
        } else {
            // Darwin declares SO_ACCEPTCONN but AF_UNIX getsockopt returns EOPNOTSUPP.
            // A bound listener has no peer; an accepted socket reports the same local path
            // but does, so this preserves the intended listener-only classification.
            var peer = sockaddr()
            var peerLength = socklen_t(MemoryLayout<sockaddr>.size)
            isListener = getpeername(fd, &peer, &peerLength) < 0 && errno == ENOTCONN
        }
        guard isListener else { continue }
        var address = sockaddr_un()
        var addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &addressLength) }
        }
        guard named == 0, address.sun_family == sa_family_t(AF_UNIX) else { continue }
        let bytes = withUnsafeBytes(of: &address.sun_path) { Array($0) }
        let endpoint = String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
        if endpoint == path { matches.append(fd) }
    }
    return matches
}

private func listenerDisappears(at path: String, within seconds: TimeInterval = 1) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if listeningUnixSocketDescriptors(at: path).isEmpty { return true }
        usleep(10_000)
    } while Date() < deadline
    return listeningUnixSocketDescriptors(at: path).isEmpty
}

private func openDescriptorSet() -> Set<Int32> {
    Set((Int32(0)..<getdtablesize()).filter { fcntl($0, F_GETFD) >= 0 })
}

private func descriptorType(_ fd: Int32) -> String {
    var info = stat()
    guard fstat(fd, &info) == 0 else { return "unavailable" }
    return String(format: "0%o", info.st_mode & S_IFMT)
}

private func acceptByPolling(_ listener: Int32, timeoutSeconds: TimeInterval = 0.3) -> Int32? {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let client = accept(listener, nil, nil)
        if client >= 0 { return client }
        if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { return nil }
        usleep(5_000)
    }
    return nil
}

private func receivedBytesByPolling(_ client: Int32, timeoutSeconds: TimeInterval = 0.3) -> Data {
    let flags = fcntl(client, F_GETFL)
    if flags >= 0 { _ = fcntl(client, F_SETFL, flags | O_NONBLOCK) }
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    var received = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while Date() < deadline {
        let count = Darwin.read(client, &buffer, buffer.count)
        if count > 0 { received.append(buffer, count: count); continue }
        if count == 0 { return received }
        if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { return received }
        usleep(5_000)
    }
    return received
}

func testIPCServerReleaseClosesListeningSocket() -> Bool {
    let directory = URL(fileURLWithPath: "/tmp/xm6connect-ipc-release-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    func run(stopFirst: Bool) -> Bool {
        let path = directory.appendingPathComponent(stopFirst ? "stopped.sock" : "released.sock").path
        var server: UnixIPCServer? = UnixIPCServer(path: path, snapshot: AgentStateSnapshot(), commandHandler: { _ in AgentReply(state: AgentState(connectionStatus: "disconnected")) })
        guard (try? server?.start()) != nil else {
            print("  T1 start failed for \(path)")
            return false
        }
        guard !listeningUnixSocketDescriptors(at: path).isEmpty else {
            print("  T1 scan did not find the started listener at \(path)")
            return false
        }
        if stopFirst { server?.stop() }
        server = nil
        let closed = listenerDisappears(at: path)
        if !closed { print("  T1 stopFirst=\(stopFirst) listening descriptors=\(listeningUnixSocketDescriptors(at: path))") }
        return closed
    }
    let released = run(stopFirst: false)
    let stopped = run(stopFirst: true)
    return released && stopped
}

func testIPCClientClosedWhenServerReleased() -> Bool {
    let directory = URL(fileURLWithPath: "/tmp/xm6connect-ipc-client-release-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("agent.sock").path
    let atHook = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let firstOnly = NSLock(); var didHold = false
    var server: UnixIPCServer? = UnixIPCServer(
        path: path,
        snapshot: AgentStateSnapshot(),
        commandHandler: { _ in AgentReply(state: AgentState(connectionStatus: "disconnected")) },
        beforeClientReadForTesting: {
            firstOnly.lock(); defer { firstOnly.unlock() }
            guard !didHold else { return }
            didHold = true
            atHook.signal()
            _ = release.wait(timeout: .distantFuture)
        }
    )
    guard (try? server?.start()) != nil, let client = openUnixSocket(path, timeoutSeconds: 1) else {
        print("  T2 server start or client connect failed")
        return false
    }
    defer { release.signal(); _ = close(client) }
    guard atHook.wait(timeout: .now() + .seconds(1)) == .success else {
        print("  T2 worker did not reach hook")
        return false
    }
    let probe = WeakServerProbe(); probe.value = server
    server = nil
    let probeNilBeforeRelease = probe.value == nil
    release.signal()
    var buffer = [UInt8](repeating: 0, count: 1)
    let result = Darwin.read(client, &buffer, buffer.count)
    let readErrno = errno
    let passed = result == 0
    if !passed { print("  T2 read=\(result) errno=\(readErrno) probeNilBeforeRelease=\(probeNilBeforeRelease)") }
    return passed
}

func testIPCStopDuringAcceptSuspensionClosesListener() -> Bool {
    let directory = URL(fileURLWithPath: "/tmp/xm6connect-ipc-suspend-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("agent.sock").path
    let injected = DispatchSemaphore(value: 0), lock = NSLock(); var used = false
    let server = UnixIPCServer(
        path: path,
        snapshot: AgentStateSnapshot(),
        commandHandler: { _ in AgentReply(state: AgentState(connectionStatus: "disconnected")) },
        acceptErrorForTesting: {
            lock.lock(); defer { lock.unlock() }
            guard !used else { return nil }
            used = true
            injected.signal()
            return EMFILE
        }
    )
    guard (try? server.start()) != nil, let client = openUnixSocket(path, timeoutSeconds: 1) else {
        print("  T3 server start or client connect failed")
        return false
    }
    defer { _ = close(client) }
    guard injected.wait(timeout: .now() + .seconds(1)) == .success else {
        print("  T3 accept seam was not called")
        return false
    }
    usleep(50_000)
    server.stop()
    usleep(700_000)
    let closed = listenerDisappears(at: path)
    if !closed { print("  T3 listening descriptors=\(listeningUnixSocketDescriptors(at: path))") }
    return closed
}

func testIPCStartFailureReleasesSocketAndLock() -> Bool {
    let directory = URL(fileURLWithPath: "/tmp/xm6connect-ipc-start-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(String(repeating: "x", count: 120)).path
    let before = openDescriptorSet()
    let server = UnixIPCServer(path: path, snapshot: AgentStateSnapshot(), commandHandler: { _ in AgentReply(state: AgentState(connectionStatus: "disconnected")) })
    var caughtError: Error?
    do { try server.start(); caughtError = nil } catch { caughtError = error }
    let after = openDescriptorSet(), added = after.subtracting(before)
    let lockPath = directory.appendingPathComponent("agent.lock").path
    let lock = open(lockPath, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
    let flockSucceeded = lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0
    if lock >= 0 { _ = close(lock) }
    let expectedError = (caughtError as? POSIXError)?.code == .ENAMETOOLONG
    let passed = expectedError && added.isEmpty && flockSucceeded
    if !passed { print("  T4 error=\(String(describing: caughtError)) added=\(added.sorted().map { "\($0):\(descriptorType($0))" }) flockSucceeded=\(flockSucceeded)") }
    return passed
}

func testFailedServerStartReleasesItsLock() -> Bool {
    let directory = URL(fileURLWithPath: "/tmp/xm6connect-start-lock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let failingPath = directory.appendingPathComponent(String(repeating: "a", count: 110) + ".sock").path
    let first = UnixIPCServer(path: failingPath, snapshot: AgentStateSnapshot(), commandHandler: { _ in AgentReply(state: AgentState()) })
    do { try first.start(); return false } catch { }
    let second = UnixIPCServer(path: directory.appendingPathComponent("agent.sock").path, snapshot: AgentStateSnapshot(), commandHandler: { _ in AgentReply(state: AgentState()) })
    defer { second.stop() }
    return withExtendedLifetime(first) { (try? second.start()) != nil }
}

func testAppSocketCancelledBeforeInstallNeverTouchesAReusedNumber() async -> Bool {
    let path = "/tmp/xm6connect-app-before-install-\(UUID().uuidString).sock"
    guard let listener = makeUnixListener(path) else { print("  T5a listener creation failed"); return false }
    defer { _ = close(listener); _ = unlink(path) }
    let flags = fcntl(listener, F_GETFL); if flags >= 0 { _ = fcntl(listener, F_SETFL, flags | O_NONBLOCK) }
    let observed = TestFDObservation()
    let transport = UnixAppSocketTransport(path: path, afterInstallForTesting: { fd in
        observed.append(fd)
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        observed.append(probe)
    })
    let task = Task { () -> Bool in
        _ = try? await Task.sleep(nanoseconds: 5_000_000_000)
        do { _ = try await transport.request(Data("{\"cmd\":\"status\"}".utf8)); return false } catch { return true }
    }
    task.cancel()
    let hookDeadline = Date().addingTimeInterval(1)
    while observed.snapshot().count < 2 && Date() < hookDeadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    guard observed.snapshot().count >= 2 else { print("  T5a hook was not called"); return false }
    let client = acceptByPolling(listener)
    let bytes = client.map { receivedBytesByPolling($0) } ?? Data()
    if let client { _ = close(client) }
    let threw = await task.value
    let values = observed.snapshot(), hookFD = values.first ?? -1, probeFD = values.dropFirst().first ?? -1
    var peer = sockaddr(); var peerLength = socklen_t(MemoryLayout<sockaddr>.size)
    let unconnected = probeFD >= 0 && getpeername(probeFD, &peer, &peerLength) < 0 && errno == ENOTCONN
    if probeFD >= 0 { _ = close(probeFD) }
    let passed = threw && bytes.isEmpty && unconnected
    if !passed { print("  T5a hookFD=\(hookFD) probeFD=\(probeFD) bytes=\(bytes.count)") }
    return passed
}

func testAppSocketCancelMidRequestKeepsTheNumberReserved() async -> Bool {
    let path = "/tmp/xm6connect-app-mid-request-\(UUID().uuidString).sock"
    guard let listener = makeUnixListener(path) else { print("  T5b listener creation failed"); return false }
    defer { _ = close(listener); _ = unlink(path) }
    let flags = fcntl(listener, F_GETFL); if flags >= 0 { _ = fcntl(listener, F_SETFL, flags | O_NONBLOCK) }
    let observed = TestFDObservation(), release = DispatchSemaphore(value: 0)
    let transport = UnixAppSocketTransport(path: path, afterInstallForTesting: { fd in
        observed.append(fd)
        _ = release.wait(timeout: .distantFuture)
    })
    let task = Task { () -> Bool in
        do { _ = try await transport.request(Data("{\"cmd\":\"status\"}".utf8)); return false } catch { return true }
    }
    let hookDeadline = Date().addingTimeInterval(1)
    while observed.snapshot().isEmpty && Date() < hookDeadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    guard !observed.snapshot().isEmpty else { print("  T5b hook was not called"); return false }
    task.cancel()
    let probeFD = socket(AF_UNIX, SOCK_STREAM, 0); observed.append(probeFD)
    release.signal()
    let client = acceptByPolling(listener)
    let bytes = client.map { receivedBytesByPolling($0) } ?? Data()
    if let client { _ = close(client) }
    let threw = await task.value
    let values = observed.snapshot(), hookFD = values.first ?? -1
    var peer = sockaddr(); var peerLength = socklen_t(MemoryLayout<sockaddr>.size)
    let unconnected = probeFD >= 0 && getpeername(probeFD, &peer, &peerLength) < 0 && errno == ENOTCONN
    if probeFD >= 0 { _ = close(probeFD) }
    let passed = threw && bytes.isEmpty && unconnected && probeFD != hookFD
    if !passed { print("  T5b hookFD=\(hookFD) probeFD=\(probeFD) bytes=\(bytes.count)") }
    return passed
}

func testIPCIdleClientDoesNotBlockConcurrentStatus() -> Bool {
    let directory = URL(fileURLWithPath: "/tmp/xm6connect-ipc-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("agent.sock").path
    let firstClientAtReadBoundary = DispatchSemaphore(value: 0)
    let secondClientAtReadBoundary = DispatchSemaphore(value: 0)
    let releaseFirstClient = DispatchSemaphore(value: 0)
    let hookLock = NSLock()
    var clientReadCount = 0
    let server = UnixIPCServer(
        path: path,
        snapshot: AgentStateSnapshot(AgentState(connectionStatus: "connected")),
        commandHandler: { _ in AgentReply(state: AgentState(connectionStatus: "disconnected")) },
        // The first accepted client is held at the boundary immediately before its
        // blocking read. A correct server still accepts/starts the victim; the old
        // shared serial-queue implementation cannot reach the second boundary.
        beforeClientReadForTesting: {
            hookLock.lock(); clientReadCount += 1; let ordinal = clientReadCount; hookLock.unlock()
            if ordinal == 1 {
                firstClientAtReadBoundary.signal()
                _ = releaseFirstClient.wait(timeout: .distantFuture)
            } else {
                secondClientAtReadBoundary.signal()
            }
        }
    )
    guard (try? server.start()) != nil, let attacker = openUnixSocket(path) else { return false }
    defer { releaseFirstClient.signal(); _ = close(attacker); server.stop() }
    guard firstClientAtReadBoundary.wait(timeout: .now() + .seconds(1)) == .success else { return false }
    guard let victim = openUnixSocket(path) else { return false }
    defer { _ = close(victim) }
    let request = Data("{\"cmd\":\"status\"}\n".utf8)
    let started = Date()
    let wrote = request.withUnsafeBytes { Darwin.write(victim, $0.baseAddress, $0.count) == request.count }
    // This wait is the ordering proof. With the original serial queue, the first
    // hook owns it and this second accepted client cannot start reading at all.
    guard secondClientAtReadBoundary.wait(timeout: .now() + .milliseconds(500)) == .success else { return false }
    releaseFirstClient.signal()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let read = Darwin.read(victim, &buffer, buffer.count)
    return wrote && read > 0 && Date().timeIntervalSince(started) < 1
}

func testIPCSecondInstancePreservesFirstSocketAndStopIsIdempotent() -> Bool {
    let directory = URL(fileURLWithPath: "/tmp/xm6connect-lock-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("agent.sock").path
    let first = UnixIPCServer(path: path, snapshot: AgentStateSnapshot(), commandHandler: { _ in AgentReply(state: AgentState(connectionStatus: "disconnected")) })
    guard (try? first.start()) != nil, FileManager.default.fileExists(atPath: path) else { return false }
    let second = UnixIPCServer(path: path, snapshot: AgentStateSnapshot(), commandHandler: { _ in AgentReply(state: AgentState(connectionStatus: "disconnected")) })
    let refused: Bool
    do { try second.start(); refused = false } catch { refused = true }
    let untouched = FileManager.default.fileExists(atPath: path)
    second.stop(); first.stop(); first.stop()
    return refused && untouched
}

func testIPCSocketPermissionsAndAcceptErrors() -> Bool {
    let directory = URL(fileURLWithPath: "/tmp/xm6connect-perms-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("agent.sock").path
    let server = UnixIPCServer(path: path, snapshot: AgentStateSnapshot(), commandHandler: { _ in AgentReply(state: AgentState(connectionStatus: "disconnected")) })
    guard (try? server.start()) != nil else { return false }
    defer { server.stop() }
    var info = stat(); guard stat(path, &info) == 0 else { return false }
    let result = (info.st_mode & 0o777) == 0o600
        && UnixIPCServer.acceptFailureAction(for: ECONNABORTED) == .retry
        && UnixIPCServer.acceptFailureAction(for: EMFILE) == .suspend
        && UnixIPCServer.acceptFailureAction(for: EAGAIN) == .ignore
    return result
}

func testIPCClientsCanSendAfterAcceptAndRespectTotalDeadline() -> Bool {
    let directory = URL(fileURLWithPath: "/tmp/xm6connect-deadline-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("agent.sock").path
    let server = UnixIPCServer(path: path, snapshot: AgentStateSnapshot(AgentState(connectionStatus: "connected")), commandHandler: { _ in AgentReply(state: AgentState(connectionStatus: "disconnected")) }, clientReadDeadline: 0.2)
    guard (try? server.start()) != nil else { return false }
    defer { server.stop() }
    guard let delayed = openUnixSocket(path, timeoutSeconds: 1) else { return false }
    defer { _ = close(delayed) }
    usleep(50_000)
    let request = Array("{\"cmd\":\"status\"}\n".utf8)
    guard Darwin.write(delayed, request, request.count) == request.count else { return false }
    var reply = [UInt8](repeating: 0, count: 1024)
    guard Darwin.read(delayed, &reply, reply.count) > 0 else { return false }
    guard let idle = openUnixSocket(path, timeoutSeconds: 1) else { return false }
    defer { _ = close(idle) }
    let partial: UInt8 = 0x7b
    guard Darwin.write(idle, [partial], 1) == 1 else { return false }
    usleep(300_000)
    return Darwin.read(idle, &reply, reply.count) == 0
}

func testAppClientClosedSocketpairWriteDoesNotRaiseSIGPIPE() -> Bool {
    var pair: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return false }
    defer { _ = close(pair[0]); _ = close(pair[1]) }
    _ = close(pair[1])
    return !UnixAppSocketTransport.writeLine(Data("{}".utf8), to: pair[0])
}

func testAppSocketCancellationClosesBlockedFD() async -> Bool {
    let path = "/tmp/xm6connect-cancel-\(UUID().uuidString).sock"
    guard let listener = makeUnixListener(path) else { return false }
    defer { _ = close(listener); _ = unlink(path) }
    let keepOpen = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        let client = accept(listener, nil, nil)
        if client >= 0 { _ = keepOpen.wait(timeout: .now() + 2); _ = close(client) }
    }
    let transport = UnixAppSocketTransport(path: path)
    let task = Task { () -> Bool in
        do { _ = try await transport.request(Data("{\"cmd\":\"status\"}".utf8)); return false }
        catch { return true }
    }
    try? await Task.sleep(nanoseconds: 50_000_000)
    let started = Date(); task.cancel()
    let cancelled = await task.value
    keepOpen.signal()
    return cancelled && Date().timeIntervalSince(started) < 0.5
}
