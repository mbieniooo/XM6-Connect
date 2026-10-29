import Foundation
import Darwin
import SonyHeadphonesKit
import XM6ConnectAgentCore
import XM6ConnectAppLogic

private func parseIPC(_ body: String) -> Result<IPCRequest, IPCRequest.ParseError> { IPCRequest.parse(Data(body.utf8)) }

func testSetModeRequestCarriesOnlyTheMode() -> Bool {
    // A mode change states only the mode; level and focus belong to the headset's report.
    guard IPCRequest.parse(Data(#"{"cmd":"set_mode","mode":"nc"}"#.utf8)) == .success(.setMode(mode: "nc")) else { return false }
    guard case .failure = IPCRequest.parse(Data(#"{"cmd":"set_mode","mode":"nc","level":3}"#.utf8)),
          case .failure = IPCRequest.parse(Data(#"{"cmd":"set_mode","mode":"loud"}"#.utf8)) else { return false }
    guard let data = try? AppRequestEncoder.data(for: .setMode(.nc)),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return false }
    return object == ["cmd": "set_mode", "mode": "nc"]
}

func testIPCParserAndReplyShape() -> Bool {
    let valid = parseIPC("{\"cmd\":\"set_eq_bands\",\"bands\":[0,0,0,0,0,0,0,0,0,0]}")
    let malformed = parseIPC("not json")
    let unknown = parseIPC("{\"cmd\":\"erase\"}")
    let oversized = parseIPC(String(repeating: "a", count: 16 * 1024 + 1))
    let refresh = parseIPC("{\"cmd\":\"refresh\"}")
    let yield = parseIPC("{\"cmd\":\"yield\",\"seconds\":60}")
    let hold = parseIPC("{\"cmd\":\"hold\",\"enabled\":true}")
    let switchPlayback = parseIPC("{\"cmd\":\"switch_playback\",\"mac\":\"AA:BB:CC:DD:EE:FF\"}")
    let lowerCaseMAC = parseIPC("{\"cmd\":\"switch_playback\",\"mac\":\"aa:bb:cc:dd:ee:ff\"}")
    let expectedBands: Result<IPCRequest, IPCRequest.ParseError> = .success(.setEQBands(Array(repeating: 0, count: 10)))
    let malformedExpected = parseIPC("[")
    let unknownExpected = parseIPC("{\"cmd\":\"erase\"}")
    let oversizedExpected = parseIPC(String(repeating: "b", count: 16 * 1024 + 1))
    let lowerCaseMACExpected = parseIPC("{\"cmd\":\"switch_playback\",\"mac\":\"11:22:33:44:55:aa\"}")
    let shape = AgentReply(state: AgentState()).state
    return valid == expectedBands
        && malformed == malformedExpected
        && unknown == unknownExpected
        && oversized == oversizedExpected
        && refresh == .success(.refresh)
        && yield == .success(.yield(seconds: 60))
        && hold == .success(.hold(true))
        && switchPlayback == .success(.switchPlayback(macAddress: "AA:BB:CC:DD:EE:FF"))
        && lowerCaseMAC == lowerCaseMACExpected
        && shape.connectionStatus == "disconnected"
}

@MainActor
func testSwitchPlaybackRejectsUntrustedOrDisconnectedTargets() -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer)
    let playing = AgentMultipointDevice(macAddress: "AA:BB:CC:DD:EE:FF", name: "Phone", connected: true, playback: true)
    let disconnected = AgentMultipointDevice(macAddress: "11:22:33:44:55:66", name: "iPad", connected: false, playback: false)
    agent.start(); _ = agent.handle(.refresh)
    controller.value = AgentState(connectionStatus: "connected", multipoint: [playing, disconnected]); controller.emit()

    let malformed = agent.handle(.switchPlayback(macAddress: "AA:BB:CC"))
    let unknown = agent.handle(.switchPlayback(macAddress: "77:88:99:AA:BB:CC"))
    let unavailable = agent.handle(.switchPlayback(macAddress: disconnected.macAddress))
    return malformed.error?.contains("canonical") == true
        && unknown.error == "playback device is not in the current multipoint list"
        && unavailable.error == "playback device is not connected"
        && controller.playbackWrites.isEmpty
}

@MainActor
func testSwitchPlaybackUsesKnownDeviceOnceAndRateLimits() async -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer)
    let mac = "AA:BB:CC:DD:EE:FF"
    let phone = AgentMultipointDevice(macAddress: mac, name: "Phone", connected: true, playback: true)
    agent.start(); _ = agent.handle(.refresh)
    controller.value = AgentState(connectionStatus: "connected", multipoint: [phone]); controller.emit()
    _ = agent.handle(.switchPlayback(macAddress: mac))
    guard controller.playbackWrites.map(\.macAddress) == [mac] else { return false }

    var rateLimited = false
    for _ in 0...XM6ConnectAgentCore.maximumExternalActionsPerMinute {
        rateLimited = agent.handle(.switchPlayback(macAddress: mac)).error == "external action rate limited"
    }
    try? await Task.sleep(nanoseconds: 260_000_000)
    return rateLimited && controller.playbackWrites.count <= 2
}

func testXM6CTLPlaybackNameResolutionAndNoDispatchOnFailure() -> Bool {
    let phone = AgentMultipointDevice(macAddress: "AA:BB:CC:DD:EE:FF", name: "Phone", connected: true, playback: true)
    let mac = AgentMultipointDevice(macAddress: "11:22:33:44:55:66", name: "Laptop", connected: true, playback: false)
    let duplicate = AgentMultipointDevice(macAddress: "77:88:99:AA:BB:CC", name: "Laptop", connected: true, playback: false)
    var sent: [String] = []
    let named = PlaybackTargetResolver.dispatch("phone", in: [phone, mac]) { sent.append($0) }
    let ambiguous = PlaybackTargetResolver.dispatch("LAPTOP", in: [phone, mac, duplicate]) { sent.append($0) }
    let unknown = PlaybackTargetResolver.dispatch("iPad", in: [phone, mac]) { sent.append($0) }
    return { if case .success = named { return true } else { return false } }()
        && { if case .failure(let error) = ambiguous { return error.description.contains("ambiguous") } else { return false } }()
        && { if case .failure(let error) = unknown { return error.description.contains("unknown") } else { return false } }()
        && sent == [phone.macAddress]
}

@MainActor func testConfigAndAppSocketSecuritySeams() -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let configURL = URL(fileURLWithPath: "/tmp/xm6connect-config-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: configURL) }
    let agent = XM6ConnectAgentCore(controller: controller, resolver: FakeResolver(), scheduler: scheduler, writer: writer, configURL: configURL, stateChanged: {})
    agent.start(); controller.emit("connected")
    var info = stat()
    return stat(configURL.path, &info) == 0 && (info.st_mode & 0o777) == 0o600
}

func testIPCStatusUsesSnapshotWithoutMainDispatch() -> Bool {
    let snapshot = AgentStateSnapshot(AgentState(connectionStatus: "connected"))
    var mainDispatchCount = 0
    let server = UnixIPCServer(path: "/unused", snapshot: snapshot, commandHandler: { _ in
        mainDispatchCount += 100
        return AgentReply(state: AgentState(connectionStatus: "disconnected"))
    }, mainDispatch: { _ in
        // This is the main-queue sentinel: status must not touch it at all.
        mainDispatchCount += 1
    })
    let reply = server.reply(for: Data("{\"cmd\":\"status\"}".utf8))
    let malformed = server.reply(for: Data("not json".utf8))
    return reply.state.connectionStatus == "connected"
        && malformed.state.connectionStatus == "connected"
        && malformed.error != nil
        && mainDispatchCount == 0
}

@MainActor
func testIPCCommandIsDeferredAndReachesCoreExactlyOnce() -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let snapshot = AgentStateSnapshot()
    let agent = XM6ConnectAgentCore(controller: controller, resolver: FakeResolver(), scheduler: scheduler, writer: writer, configURL: URL(fileURLWithPath: "/tmp/xm6connect-ipc-\(UUID().uuidString).json"), stateSnapshot: snapshot, stateChanged: {})
    var mainDispatchCount = 0
    var pending: (() -> Void)?
    var handlerRuns = 0
    let server = UnixIPCServer(path: "/unused", snapshot: snapshot, commandHandler: { request in
        handlerRuns += 1
        return agent.handle(request)
    }, mainDispatch: { action in
        mainDispatchCount += 1
        pending = action
    }, commandReplyTimeout: 2)
    // On the main thread the reply must never wait for the main queue it is running on.
    let started = Date()
    let reply = server.reply(for: Data("{\"cmd\":\"set_stc\",\"enabled\":true}".utf8))
    let elapsed = Date().timeIntervalSince(started)
    guard elapsed < 0.3, reply.stale, reply.error == nil else {
        print("    T3 main-thread reply took \(elapsed)s stale=\(reply.stale) error=\(String(describing: reply.error))"); return false
    }
    guard mainDispatchCount == 1, controller.stcWrites.isEmpty, reply.state.connectionStatus == "disconnected" else { return false }
    pending?()
    return controller.stcWrites.isEmpty && controller.connects.count == 1 && mainDispatchCount == 1 && handlerRuns == 1
}

@MainActor func testIPCCommandErrorsReachTheClient() -> Bool {
    // A rejected command's error is the agent's own reply, not a snapshot taken before the
    // command ran: the client must see why nothing happened.
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer)
    let playing = AgentMultipointDevice(macAddress: "AA:BB:CC:DD:EE:FF", name: "Phone", connected: true, playback: true)
    let absent = AgentMultipointDevice(macAddress: "11:22:33:44:55:66", name: "iPad", connected: false, playback: false)
    agent.start(); _ = agent.handle(.refresh)
    controller.value = AgentState(connectionStatus: "connected", multipoint: [playing, absent]); controller.emit()
    guard agent.state.multipoint == [playing, absent] else {
        print("    T1 multipoint not reported: \(String(describing: agent.state.multipoint))"); return false
    }
    let server = UnixIPCServer(path: "/unused", snapshot: agent.stateSnapshot, commandHandler: { agent.handle($0) }, mainDispatch: { $0() })
    let unknown = server.reply(for: Data(#"{"cmd":"switch_playback","mac":"77:88:99:AA:BB:CC"}"#.utf8))
    let disconnected = server.reply(for: Data(#"{"cmd":"switch_playback","mac":"11:22:33:44:55:66"}"#.utf8))
    guard unknown.error == "playback device is not in the current multipoint list", !unknown.stale,
          disconnected.error == "playback device is not connected", !disconnected.stale else {
        print("    T1 unknown=(\(String(describing: unknown.error)), stale \(unknown.stale)) disconnected=(\(String(describing: disconnected.error)), stale \(disconnected.stale))")
        return false
    }
    return true
}

@MainActor func testEveryAcceptedWriteIsStale() -> Bool {
    // An accepted write or reconnect reaches the headset after its reply is built, so the
    // reply's state predates it. A read, a lease request or a rejected request does not.
    let clock = Date(timeIntervalSince1970: 2_000)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    let playing = AgentMultipointDevice(macAddress: "AA:BB:CC:DD:EE:FF", name: "Phone", connected: true, playback: true)
    let idle = AgentMultipointDevice(macAddress: "11:22:33:44:55:66", name: "Mac", connected: true, playback: false)
    agent.start(); _ = agent.handle(.refresh)
    controller.value = AgentState(connectionStatus: "connected", ambient: AgentAmbient(mode: "nc", level: 5, focus: false, subtype: 0x19), multipoint: [playing, idle])
    controller.emit()
    let writes: [(String, IPCRequest)] = [
        ("reconnect", .reconnect), ("cycle", .cycle), ("setAmbient", .setAmbient(mode: "ambient", level: 8, focus: false)),
        ("setMode", .setMode(mode: "nc")), ("setFocus", .setFocus(enabled: true)), ("setAmbientLevel", .setAmbientLevel(level: 10)),
        ("setEQPreset", .setEQPreset(code: 0x31)), ("setEQBands", .setEQBands(Array(repeating: 0, count: 10))),
        ("setSTC", .setSTC(true)), ("setListeningMode", .setListeningMode(mode: "cinema")),
        ("setBGMRoomSize", .setBGMRoomSize(rawValue: 1)), ("switchPlayback", .switchPlayback(macAddress: idle.macAddress))
    ]
    for (name, request) in writes {
        let reply = agent.handle(request)
        guard reply.stale, reply.error == nil else {
            print("    T2 first failing write: \(name) stale=\(reply.stale) error=\(String(describing: reply.error))"); return false
        }
    }
    let others: [(String, IPCRequest)] = [
        ("status", .status), ("prewarm", .prewarm), ("refresh", .refresh),
        ("rejected switchPlayback", .switchPlayback(macAddress: "77:88:99:AA:BB:CC")),
        ("hold", .hold(true)), ("yield", .yield(seconds: 60))
    ]
    for (name, request) in others {
        let reply = agent.handle(request)
        guard !reply.stale else { print("    T2 first failing non-write: \(name) is stale (error \(String(describing: reply.error)))"); return false }
    }
    return true
}

private final class CommandReplyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedBlock: (() -> Void)?
    private var storedReply: AgentReply?
    private var runs = 0
    func store(_ block: @escaping () -> Void) { lock.lock(); storedBlock = block; lock.unlock() }
    func block() -> (() -> Void)? { lock.lock(); defer { lock.unlock() }; return storedBlock }
    func setReply(_ reply: AgentReply) { lock.lock(); storedReply = reply; lock.unlock() }
    func reply() -> AgentReply? { lock.lock(); defer { lock.unlock() }; return storedReply }
    func countRun() { lock.lock(); runs += 1; lock.unlock() }
    func runCount() -> Int { lock.lock(); defer { lock.unlock() }; return runs }
}

private struct UncheckedBlock: @unchecked Sendable { let run: () -> Void }

func testIPCWorkerWaitsForTheCommandsOwnReply() -> Bool {
    // Production's path: the client worker is never the main thread, and mainDispatch hops to
    // another queue. The worker must return that run's own reply (here its error), not the
    // stale snapshot, when the run finishes inside the timeout.
    let probe = CommandReplyProbe()
    let server = UnixIPCServer(path: "/unused", snapshot: AgentStateSnapshot(), commandHandler: { _ in
        AgentReply(state: AgentState(connectionStatus: "connected"), error: "from the handler", ownership: "held", stale: false)
    }, mainDispatch: { block in
        let work = UncheckedBlock(run: block)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { work.run() }
    }, commandReplyTimeout: 1)
    let done = DispatchSemaphore(value: 0)
    let began = Date()
    DispatchQueue.global().async {
        probe.setReply(server.reply(for: Data(#"{"cmd":"set_stc","enabled":true}"#.utf8)))
        done.signal()
    }
    let arrived = done.wait(timeout: .now() + 2) == .success
    let elapsed = Date().timeIntervalSince(began)
    let reply = probe.reply()
    guard arrived, let reply, reply.error == "from the handler", !reply.stale, elapsed < 0.9 else {
        print("    worker reply: arrived=\(arrived) error=\(String(describing: reply?.error)) stale=\(String(describing: reply?.stale)) after \(String(format: "%.2f", elapsed))s")
        return false
    }
    return true
}

func testIPCCommandReplyTimesOutToAStaleSnapshot() -> Bool {
    // A worker waits for a command's reply only as long as the timeout. A main queue that
    // has not run the command leaves the client with the stale snapshot; the block that runs
    // later still runs the command once and writes nothing anyone reads.
    let probe = CommandReplyProbe()
    let server = UnixIPCServer(path: "/unused", snapshot: AgentStateSnapshot(AgentState(connectionStatus: "connected")), commandHandler: { _ in
        probe.countRun()
        return AgentReply(state: AgentState(connectionStatus: "disconnected"))
    }, mainDispatch: { probe.store($0) }, commandReplyTimeout: 0.1)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        probe.setReply(server.reply(for: Data(#"{"cmd":"set_stc","enabled":true}"#.utf8)))
        done.signal()
    }
    let arrived = done.wait(timeout: .now() + 1) == .success
    let late = probe.block()
    late?()
    let reply = probe.reply()
    guard arrived, let reply, reply.stale, reply.error == nil, reply.state.connectionStatus == "connected",
          late != nil, probe.runCount() == 1 else {
        print("    T4 arrived=\(arrived) stale=\(String(describing: reply?.stale)) status=\(String(describing: reply?.state.connectionStatus)) stored=\(late != nil) runs=\(probe.runCount())")
        return false
    }
    return true
}

func testSessionAmbientVerbsParseStrictly() -> Bool {
    // Focus is a JSON boolean and an ambient level an integer in 1...20. JSONSerialization
    // bridges 1 and 1.0 to true and true to 1, so only the CF type tells them apart.
    let accepted: [(String, IPCRequest)] = [
        (#"{"cmd":"set_focus","enabled":true}"#, .setFocus(enabled: true)),
        (#"{"cmd":"set_focus","enabled":false}"#, .setFocus(enabled: false)),
        (#"{"cmd":"set_ambient_level","level":1}"#, .setAmbientLevel(level: 1)),
        (#"{"cmd":"set_ambient_level","level":20}"#, .setAmbientLevel(level: 20))
    ]
    for (body, expected) in accepted where parseIPC(body) != .success(expected) {
        print("    T6 \(body) parsed as \(parseIPC(body))"); return false
    }
    let rejected: [(String, String)] = [
        (#"{"cmd":"set_focus","enabled":1}"#, "set_focus requires boolean enabled"),
        (#"{"cmd":"set_focus","enabled":1.0}"#, "set_focus requires boolean enabled"),
        (#"{"cmd":"set_focus","enabled":"true"}"#, "set_focus requires boolean enabled"),
        (#"{"cmd":"set_focus"}"#, "set_focus requires boolean enabled"),
        (#"{"cmd":"set_focus","enabled":true,"mode":"nc"}"#, "set_focus requires boolean enabled"),
        (#"{"cmd":"set_ambient_level","level":0}"#, "set_ambient_level requires level 1...20"),
        (#"{"cmd":"set_ambient_level","level":21}"#, "set_ambient_level requires level 1...20"),
        (#"{"cmd":"set_ambient_level","level":true}"#, "set_ambient_level requires level 1...20"),
        (#"{"cmd":"set_ambient_level","level":1.5}"#, "set_ambient_level requires level 1...20"),
        (#"{"cmd":"set_ambient_level","level":10,"focus":false}"#, "set_ambient_level requires level 1...20")
    ]
    for (body, message) in rejected {
        guard case .failure(let error) = parseIPC(body), error.description == message else {
            print("    T6 \(body) parsed as \(parseIPC(body))"); return false
        }
    }
    return true
}

@MainActor func testListeningModeIPCValidationAndRouting() -> Bool {
    // The socket is a trust boundary: only the kit's own mode names may ever reach a
    // device write (TX e8 04 00 -> RX e9 04 00), so this
    // path really does change the headset and must not accept anything else.
    let rejected = ["", "Cinema", "cinema ", "off", "nc", "standard;cinema", "CINEMA"]
    for mode in rejected {
        if case .success = parseIPC("{\"cmd\":\"set_listening_mode\",\"mode\":\"\(mode)\"}") { return false }
    }
    // An unexpected field must be refused, like every other verb in this parser.
    if case .success = parseIPC("{\"cmd\":\"set_listening_mode\",\"mode\":\"cinema\",\"extra\":1}") { return false }
    // The accepted set must not drift from the kit enum the bridge converts back into.
    let kitModes = Set(ListeningMode.allCases.map { $0.rawValue })
    guard kitModes == ["standard", "backgroundMusic", "cinema"] else { return false }
    for mode in kitModes {
        guard case .success(.setListeningMode(let parsed)) = parseIPC("{\"cmd\":\"set_listening_mode\",\"mode\":\"\(mode)\"}"),
              parsed == mode, ListeningMode(rawValue: parsed) != nil else { return false }
    }
    // Routing: on a held lease a valid mode reaches the controller exactly once.
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer)
    agent.start()
    controller.value = AgentState(connectionStatus: "connected"); controller.emit()
    _ = agent.handle(.setListeningMode(mode: "cinema"))
    return controller.listeningModeWrites == ["cinema"]
}

@MainActor func testBGMRoomSizeIPCValidationAndNoWriteOnRejectedInput() -> Bool {
    // Exact raw enum values only; a JSON string and an extra key are distinct trust
    // boundary failures, not values to coerce or silently ignore.
    let rejected = [
        "{\"cmd\":\"set_bgm_room_size\",\"roomSize\":3}",
        "{\"cmd\":\"set_bgm_room_size\",\"roomSize\":\"1\"}",
        "{\"cmd\":\"set_bgm_room_size\",\"roomSize\":true}",
        "{\"cmd\":\"set_bgm_room_size\",\"roomSize\":1,\"extra\":1}"
    ]
    for body in rejected { if case .success = parseIPC(body) { return false } }
    for rawValue in BGMRoomSize.allCases.map(\.rawValue) {
        guard case .success(.setBGMRoomSize(let parsed)) = parseIPC("{\"cmd\":\"set_bgm_room_size\",\"roomSize\":\(rawValue)}"), parsed == rawValue else { return false }
    }
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer)
    agent.start(); controller.value = AgentState(connectionStatus: "connected"); controller.emit()
    let snapshot = AgentStateSnapshot(agent.state)
    var dispatches = 0
    let server = UnixIPCServer(path: "/unused", snapshot: snapshot, commandHandler: { request in
        agent.handle(request)
    }, mainDispatch: { action in
        dispatches += 1
        action()
    })
    // Exercise the actual socket parsing/dispatch seam, rather than merely proving
    // the parser's return value: none of the rejected JSON reaches the controller.
    for body in rejected {
        guard server.reply(for: Data(body.utf8)).error != nil else { return false }
    }
    guard dispatches == 0, controller.bgmRoomSizeWrites.isEmpty else { return false }
    _ = agent.handle(.setBGMRoomSize(rawValue: BGMRoomSize.large.rawValue))
    return controller.bgmRoomSizeWrites == [BGMRoomSize.large.rawValue]
}
