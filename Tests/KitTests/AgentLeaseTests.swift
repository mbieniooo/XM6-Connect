import Foundation
import SonyHeadphonesKit
import XM6ConnectAgentCore

private final class OrderedStateWriter: StateWriting {
    private(set) var values: [AgentState] = []
    var didWrite: ((AgentState) -> Void)?
    func write(_ state: AgentState) throws { values.append(state); didWrite?(state) }
}

@MainActor func testStateFlushWritesBeforeItNotifies() async -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = OrderedStateWriter()
    var orderedLog: [String] = []
    writer.didWrite = { _ in orderedLog.append("write") }
    let agent = XM6ConnectAgentCore(
        controller: controller,
        resolver: FakeResolver(),
        scheduler: scheduler,
        writer: writer,
        configURL: URL(fileURLWithPath: "/tmp/xm6connect-state-flush-\(UUID().uuidString).json"),
        stateChanged: { orderedLog.append("notify") }
    )
    controller.value.battery = AgentBattery(level: 10, charging: false)
    controller.emit("connected")
    try? await Task.sleep(nanoseconds: 70_000_000)
    controller.value.battery = AgentBattery(level: 90, charging: false)
    controller.emit()
    try? await Task.sleep(nanoseconds: 200_000_000)
    let passed = orderedLog.last == "notify" && writer.values.last?.battery?.level == 90
    withExtendedLifetime(agent) {}
    return passed
}

@MainActor func testLeaseMergesNilSessionSnapshot() -> Bool {
    var clock = Date(timeIntervalSince1970: 100)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start(); _ = agent.handle(.refresh)
    controller.value.battery = AgentBattery(level: 83, charging: false); controller.emit("connected")
    guard agent.state.battery?.level == 83 else { return false }
    clock.addTimeInterval(1); controller.value = AgentState(connectionStatus: "connecting"); controller.emit()
    return agent.state.battery?.level == 83
}

@MainActor func testStateAsOfIsDeviceTimeNotCommitTime() -> Bool {
    var clock = Date(timeIntervalSince1970: 200)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start(); _ = agent.handle(.refresh); controller.value.battery = AgentBattery(level: 70, charging: false); controller.emit("connected")
    let reported = agent.state.stateAsOf; let firstWrite = agent.state.timestamp
    clock.addTimeInterval(7); controller.value = AgentState(connectionStatus: "connecting"); controller.emit()
    return reported == Date(timeIntervalSince1970: 200) && firstWrite == reported
        && agent.state.stateAsOf == reported && agent.state.timestamp == Date(timeIntervalSince1970: 207)
}

@MainActor func testThrottledWritesReturnForTheNextLease() -> Bool {
    // Writes still waiting in the 200 ms throttle when the lease ends must not fire into a
    // closed channel; they wait for the next lease instead.
    var clock = Date(timeIntervalSince1970: 430)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.refresh)
    controller.value.ambient = AgentAmbient(mode: "nc", level: 5, focus: false, subtype: 0x19); controller.emit("connected")
    _ = agent.handle(.setSTC(true)); _ = agent.handle(.setEQPreset(code: 0x31)); _ = agent.handle(.setBGMRoomSize(rawValue: 2))
    guard controller.stcWrites == [true], controller.equalizerPresetWrites.isEmpty, mutationTimer.isArmed else { return false }
    agent.setAsleep(true)
    guard !mutationTimer.isArmed, controller.equalizerPresetWrites.isEmpty, controller.bgmRoomSizeWrites.isEmpty else { return false }
    agent.setAsleep(false); clock.addTimeInterval(3); _ = agent.handle(.refresh)
    controller.emit("connected")
    for _ in 0..<3 where mutationTimer.isArmed { clock.addTimeInterval(0.2); mutationTimer.fire() }
    return controller.equalizerPresetWrites.map(\.0) == [0x31] && controller.bgmRoomSizeWrites == [2]
}

@MainActor func testPeekThatFlushesQueuedWritesKeepsTheLease() -> Bool {
    // A probe that connects and finds user writes waiting has become a real lease; releasing
    // on its first report would cut the throttled writes off again.
    var clock = Date(timeIntervalSince1970: 440)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.refresh)
    controller.value.ambient = AgentAmbient(mode: "nc", level: 5, focus: false, subtype: 0x19); controller.emit("connected")
    _ = agent.handle(.setSTC(true)); _ = agent.handle(.setEQPreset(code: 0x31)); _ = agent.handle(.setBGMRoomSize(rawValue: 2))
    agent.setAsleep(true); agent.setAsleep(false)
    guard scheduler.armedDelay == 5 * 60 else { return false }
    clock.addTimeInterval(5 * 60); scheduler.fire()
    controller.emit("connected")
    guard agent.ownershipForTesting == .held else { return false }
    for _ in 0..<3 where mutationTimer.isArmed { clock.addTimeInterval(0.2); mutationTimer.fire() }
    return controller.equalizerPresetWrites.map(\.0) == [0x31] && controller.bgmRoomSizeWrites == [2]
}

@MainActor func testThrottleDelayIsClampedWhenTheClockStepsBack() -> Bool {
    // The throttle compares wall-clock times; a clock that steps backwards must not hold
    // every later write for the size of the step.
    var clock = Date(timeIntervalSince1970: 450)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.refresh)
    controller.value.ambient = AgentAmbient(mode: "nc", level: 5, focus: false, subtype: 0x19); controller.emit("connected")
    _ = agent.handle(.setSTC(true))
    clock.addTimeInterval(-100)
    _ = agent.handle(.setEQPreset(code: 0x31))
    guard let delay = mutationTimer.armedDelay else { return controller.equalizerPresetWrites.count == 1 }
    return delay <= 0.2
}

@MainActor func testLeaseStartCommandIdleAndStatus() -> Bool {
    var clock = Date(timeIntervalSince1970: 400)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start(); let before = controller.connects.count; _ = agent.handle(.status)
    guard before == 0 && controller.connects.isEmpty && agent.state.connectionStatus == "released" else { return false }
    _ = agent.handle(.setSTC(true)); controller.value.battery = AgentBattery(level: 60, charging: false); controller.emit("connected")
    guard scheduler.delays.last == 20 else { return false }
    clock.addTimeInterval(20); scheduler.fire()
    return agent.state.connectionStatus == "released" && agent.ownershipForTesting == .released
}

@MainActor func testIdleReleaseIgnoresContinuousInboundReports() -> Bool {
    var clock = Date(timeIntervalSince1970: 450)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start()
    _ = agent.handle(.setSTC(true))
    controller.value.battery = AgentBattery(level: 60, charging: false)
    controller.emit("connected")
    for _ in 0..<12 {
        clock.addTimeInterval(5)
        controller.value.battery = AgentBattery(level: 60, charging: false)
        controller.emit()
    }
    guard scheduler.delays.last == 0 else { return false }
    scheduler.fire()
    return agent.ownershipForTesting == .released && agent.state.connectionStatus == "released"
}

@MainActor func testLeaseHonorsTwoSecondTeardownGap() -> Bool {
    let clock = Date(timeIntervalSince1970: 500)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start(); _ = agent.handle(.refresh); controller.value.battery = AgentBattery(level: 50, charging: false); controller.emit("connected")
    _ = agent.handle(.hold(false)); let connections = controller.connects.count
    _ = agent.handle(.refresh)
    return controller.connects.count == connections && scheduler.delays.last == 2 && agent.timerArmedForTesting
}

@MainActor func testYieldLadderAndForeignHolderNeverBounces() -> Bool {
    var clock = Date(timeIntervalSince1970: 600)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start(); _ = agent.handle(.refresh)
    controller.pendingTransportFailure = RFCOMMConnectionFailureContext(kind: .controlRefused, isConnected: true); controller.emit("failed")
    guard controller.aclBounceCalls == 0 && agent.state.connectionStatus == "yielded" && scheduler.delays.last == 60 else { return false }
    clock.addTimeInterval(60); scheduler.fire()
    controller.pendingTransportFailure = RFCOMMConnectionFailureContext(kind: .controlRefused, isConnected: true); controller.emit("failed")
    guard scheduler.delays.last == 180 else { return false }
    clock.addTimeInterval(180); scheduler.fire()
    controller.pendingTransportFailure = RFCOMMConnectionFailureContext(kind: .controlRefused, isConnected: true); controller.emit("failed")
    return scheduler.delays.last == 600 && controller.aclBounceCalls == 0
}

@MainActor func testYieldJitterStaysWithinTwentyPercent() -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { Date(timeIntervalSince1970: 650) }, jitter: { $0 * 1.2 })
    agent.start(); _ = agent.handle(.refresh)
    controller.pendingTransportFailure = RFCOMMConnectionFailureContext(kind: .controlRefused, isConnected: true); controller.emit("failed")
    guard let delay = scheduler.delays.last else { return false }
    guard delay == 72 else { return false }
    return (0..<1_000).allSatisfy { _ in (48...72).contains(XM6ConnectAgentCore.defaultJitter(60)) }
}

@MainActor func testPeekAndSleepDoNotPollOrStealOnWake() -> Bool {
    var clock = Date(timeIntervalSince1970: 700)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start(); guard scheduler.delays.last == 300 else { return false }
    clock.addTimeInterval(300); scheduler.fire(); guard controller.connects.count == 1 else { return false }
    controller.value.battery = AgentBattery(level: 40, charging: false); controller.emit("connected")
    guard agent.state.connectionStatus == "released" && scheduler.delays.last == 300 else { return false }
    agent.setAsleep(true); let count = controller.connects.count; agent.setAsleep(false)
    return controller.connects.count == count && agent.state.connectionStatus == "released"
}

@MainActor func testPeekIsSuppressedByYieldHoldAndSleep() -> Bool {
    let yieldedController = FakeAgentController(), yieldedScheduler = FakeRetryScheduler(), yieldedWriter = FakeStateWriter()
    let yielded = makeAgent(yieldedController, yieldedScheduler, yieldedWriter)
    yielded.start(); _ = yielded.handle(.yield(seconds: 600))
    guard let yieldedDelay = yieldedScheduler.delays.last, (599...601).contains(yieldedDelay) else { return false }
    let heldController = FakeAgentController(), heldScheduler = FakeRetryScheduler(), heldWriter = FakeStateWriter()
    let held = makeAgent(heldController, heldScheduler, heldWriter)
    held.start(); _ = held.handle(.hold(true))
    guard heldController.connects.count == 1 && !heldScheduler.isArmed else { return false }
    let sleepingController = FakeAgentController(), sleepingScheduler = FakeRetryScheduler(), sleepingWriter = FakeStateWriter()
    let sleeping = makeAgent(sleepingController, sleepingScheduler, sleepingWriter)
    sleeping.start(); sleeping.setAsleep(true); sleepingScheduler.fire()
    return sleepingController.connects.isEmpty
}

@MainActor func testSleepReleasesHeldLeaseAndWakeDoesNotAcquire() -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer)
    agent.start(); _ = agent.handle(.refresh); controller.value.battery = AgentBattery(level: 39, charging: false); controller.emit("connected")
    guard agent.ownershipForTesting == .held else { return false }
    let connects = controller.connects.count; agent.setAsleep(true); agent.setAsleep(false)
    return agent.ownershipForTesting == .released && agent.state.connectionStatus == "released" && controller.connects.count == connects
}

@MainActor
func testAgentReconnectBackoffAndNoStateWritesOnConnect() -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer)
    agent.start()
    guard controller.connects.isEmpty, agent.state.connectionStatus == "released" else { return false }
    _ = agent.handle(.setSTC(true))
    guard controller.connects.count == 1, controller.ambientWrites.isEmpty, controller.stcWrites.isEmpty, controller.equalizerPresetWrites.isEmpty else { return false }
    controller.emit("failed")
    guard scheduler.delays.last == 0.5 else { return false }
    scheduler.fire()
    guard controller.connects.count == 2 else { return false }
    controller.emit("failed")
    return scheduler.delays.suffix(2) == [0.5, 1] && agent.state.connectionStatus == "failed" && agent.timerArmedForTesting
}

@MainActor
func testAgentResyncsOncePerReconnectAndStoresNotifyState() -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer)
    agent.start(); _ = agent.handle(.refresh); controller.emit("connected")
    guard controller.refreshes == 1 else { return false }
    controller.value.ambient = AgentAmbient(mode: "nc", level: 12, focus: true, subtype: 0x19)
    controller.emit()
    guard controller.refreshes == 1, agent.state.ambient == AgentAmbient(mode: "nc", level: 12, focus: true, subtype: 0x19) else { return false }
    controller.emit("disconnected"); scheduler.fire(); controller.emit("connected")
    return controller.refreshes == 2 && controller.connects.count == 2
}

func testStateJSONAtomicity() -> Bool {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-atomic-\(UUID().uuidString)", isDirectory: true)
    let stateURL = directory.appendingPathComponent("state.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = AtomicStateWriter(url: stateURL)
    guard (try? writer.write(AgentState(connectionStatus: "connected"))) != nil,
          let data = try? Data(contentsOf: stateURL) else { return false }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    guard let decoded = try? decoder.decode(AgentState.self, from: data) else { return false }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return decoded.connectionStatus == "connected" && !names.contains(where: { $0.hasSuffix(".tmp") })
}

@MainActor func testOversizedConfigFallsBackToDefaults() -> Bool {
    let directory = URL(fileURLWithPath: "/tmp/xm6connect-config-size-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appendingPathComponent("config.json")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var config = Data("{\"hold\":true}".utf8); config.append(Data(repeating: 0x20, count: 64 * 1024))
    guard (try? config.write(to: configURL)) != nil else { print("  T6 config write failed"); return false }
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = XM6ConnectAgentCore(controller: controller, resolver: FakeResolver(), scheduler: scheduler, writer: writer, configURL: configURL, stateChanged: {})
    agent.start()
    let passed = controller.connects.isEmpty && agent.ownershipForTesting == .released
    if !passed { print("  T6 connects=\(controller.connects.count) ownership=\(agent.ownershipForTesting)") }
    return passed
}

@MainActor func testAgentMutationRateLimitCoalescesLatest() async -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer)
    agent.start(); _ = agent.handle(.hold(true)); controller.emit("connected")
    for value in 0..<100 { _ = agent.handle(.setSTC(value % 2 == 0)) }
    try? await Task.sleep(nanoseconds: 260_000_000)
    return controller.stcWrites.count <= 6 && controller.stcWrites.last == false
}

@MainActor func testStateCommitAndNotificationBurstsCoalesce() async -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    var notifications = 0
    let agent = XM6ConnectAgentCore(controller: controller, resolver: FakeResolver(), scheduler: scheduler, writer: writer, configURL: URL(fileURLWithPath: "/tmp/xm6connect-state-\(UUID().uuidString).json"), stateChanged: { notifications += 1 })
    agent.start()
    for _ in 0..<100 { controller.emit("connecting") }
    try? await Task.sleep(nanoseconds: 160_000_000)
    return writer.values.count == 1 && notifications == 1
}

@MainActor
private final class RecordingResolver: AgentDeviceResolving {
    private(set) var cachedAddresses: [String?] = []
    func resolve(cachedAddress: String?) -> PairedDeviceInfo? {
        cachedAddresses.append(cachedAddress)
        return PairedDeviceInfo(id: "AA:BB", name: "WH-1000XM6", isConnected: true)
    }
}

@MainActor func testConfigIsReadOnEveryAcquire() -> Bool {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-config-read-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appendingPathComponent("config.json")
    func writeConfig(address: String) { try? Data("{\"address\":\"\(address)\",\"hold\":false}".utf8).write(to: configURL) }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    writeConfig(address: "11:11")
    var clock = Date(timeIntervalSince1970: 1_000)
    let controller = FakeAgentController(), resolver = RecordingResolver()
    let scheduler = FakeRetryScheduler(), acquisition = FakeRetryScheduler(), mutation = FakeRetryScheduler()
    let agent = XM6ConnectAgentCore(
        controller: controller,
        resolver: resolver,
        scheduler: scheduler,
        writer: FakeStateWriter(),
        configURL: configURL,
        now: { clock },
        jitter: { $0 },
        acquisitionScheduler: acquisition,
        deviceMutationScheduler: mutation,
        stateChanged: {}
    )
    _ = agent.handle(.refresh)
    controller.emit("connected")
    guard agent.ownershipForTesting == .held else {
        print("    config read: first acquire did not reach held (ownership \(agent.ownershipForTesting))"); return false
    }
    let persisted = (try? Data(contentsOf: configURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    scheduler.fire()
    guard agent.ownershipForTesting == .released else {
        print("    config read: idle release did not release (ownership \(agent.ownershipForTesting))"); return false
    }
    writeConfig(address: "22:22")
    clock.addTimeInterval(3)
    _ = agent.handle(.refresh)
    let observed = resolver.cachedAddresses.map { $0 ?? "nil" }
    guard observed == ["11:11", "22:22"], persisted?["address"] as? String == "AA:BB", persisted?["hold"] as? Bool == false else {
        print("    config read: resolver saw \(observed) (expected [11:11, 22:22]); config after first connect: \(persisted.map { "\($0)" } ?? "nil")"); return false
    }
    return true
}

@MainActor func testAgentSeedsFromPersistedStateOnRestart() -> Bool {
    // After a restart, the agent must not write a blank snapshot over the
    // persisted file, so the widget/menu bar/popover showed dashes until something
    // acquired the channel. A restart must keep the last known device values.
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-seed-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let persisted = "{\"connectionStatus\":\"connected\",\"battery\":{\"level\":77,\"charging\":false},"
        + "\"ambient\":{\"mode\":\"nc\",\"level\":12,\"focus\":false,\"subtype\":23},"
        + "\"equalizer\":{\"presetCode\":32,\"bands\":[],\"subtype\":4},"
        + "\"timestamp\":\"1970-01-01T00:00:00Z\",\"stateAsOf\":\"1970-01-01T00:00:00Z\"}"
    try? Data(persisted.utf8).write(to: stateURL)

    let core = XM6ConnectAgentCore(
        controller: FakeAgentController(), resolver: FakeResolver(), scheduler: FakeRetryScheduler(),
        writer: FakeStateWriter(), configURL: directory.appendingPathComponent("config.json"),
        stateSnapshot: AgentStateSnapshot(),
        stateReader: AtomicStateReader(url: stateURL),
        stateChanged: {}
    )
    let seeded = core.state
    // Device values survive; connection authority does NOT come from the file.
    return seeded.battery?.level == 77 && seeded.ambient?.mode == "nc"
        && seeded.equalizer?.presetCode == 32 && seeded.connectionStatus == "released"
        && seeded.stateAsOf == ISO8601DateFormatter().date(from: "1970-01-01T00:00:00Z")
}

func testOwnershipNeverReportsAcquisitionAsUnavailable() -> Bool {
    // Every acquire must not flash ownership "unavailable" (which reads as broken)
    // because the snapshot mapping had no case for the acquisition phases.
    guard AgentLeaseOwnership.forConnectionStatus("connecting") == .acquiring else { return false }
    guard AgentLeaseOwnership.forConnectionStatus("initializing") == .acquiring else { return false }
    guard AgentLeaseOwnership.forConnectionStatus("connected") == .held else { return false }
    guard AgentLeaseOwnership.forConnectionStatus("released") == .released else { return false }
    guard AgentLeaseOwnership.forConnectionStatus("yielded") == .yielded else { return false }
    // Genuinely unusable states still read unavailable.
    guard AgentLeaseOwnership.forConnectionStatus("failed") == .unavailable else { return false }
    return AgentLeaseOwnership.forConnectionStatus("disconnected") == .unavailable
}

@MainActor func testLeaseLivenessAndTeardownRegressionPaths() -> Bool {
    var clock = Date(timeIntervalSince1970: 10_000)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), acquisition = FakeRetryScheduler(), writer = FakeStateWriter()
    let resolver = FakeResolver(); resolver.device = nil
    let agent = XM6ConnectAgentCore(controller: controller, resolver: resolver, scheduler: scheduler, writer: writer,
        configURL: URL(fileURLWithPath: "/tmp/xm6connect-liveness-\(UUID().uuidString).json"), now: { clock }, acquisitionScheduler: acquisition, stateChanged: {})
    agent.start()
    // Resolver miss is a normal boot state, not a terminal state.
    guard agent.state.connectionStatus == "failed", scheduler.delays.last == XM6ConnectAgentCore.unavailableRetry, scheduler.isArmed else { return false }
    resolver.device = PairedDeviceInfo(id: "AA:BB", name: "WH-1000XM6", isConnected: true); clock.addTimeInterval(60); scheduler.fire()
    guard controller.connects.count == 1, agent.ownershipForTesting == .acquiring, acquisition.delays.last == XM6ConnectAgentCore.openTimeout else { return false }
    // A connected bridge must cancel the exact 8-second acquisition watchdog.
    controller.value = AgentState(connectionStatus: "connected") ; controller.emit()
    guard !acquisition.isArmed, scheduler.delays.last == 20 else { return false }
    // lastAcquire prevents an inherited ancient activity timestamp from releasing now.
    clock.addTimeInterval(20); scheduler.fire()
    guard agent.state.connectionStatus == "released" else { return false }

    let deferredController = FakeAgentController(), deferredScheduler = FakeRetryScheduler(), deferredWriter = FakeStateWriter()
    let deferred = makeAgent(deferredController, deferredScheduler, deferredWriter, now: { clock })
    deferred.start(); _ = deferred.handle(.yield(seconds: 60)); deferredController.emitDeferredDisconnect()
    // Deferred duplicate disconnect must preserve yielded state and its five-minute-ish timer.
    return deferred.state.connectionStatus == "yielded" && deferred.ownershipForTesting == .yielded && deferredScheduler.delays.last == 60
}

@MainActor func testWakeAndBackoffRegressionPaths() -> Bool {
    let clock = Date(timeIntervalSince1970: 20_000)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start(); _ = agent.handle(.refresh); controller.value = AgentState(connectionStatus: "connected"); controller.emit()
    let connectsBeforeSleep = controller.connects.count
    agent.setAsleep(true); agent.setAsleep(false)
    // Wake restores a periodic peek, but does not immediately take the session.
    guard controller.connects.count == connectsBeforeSleep, scheduler.delays.last == 300, scheduler.isArmed else { return false }
    let retryController = FakeAgentController(), retryScheduler = FakeRetryScheduler(), retryWriter = FakeStateWriter()
    let retryAgent = makeAgent(retryController, retryScheduler, retryWriter, now: { clock })
    retryAgent.start(); _ = retryAgent.handle(.refresh)
    for expected in [0.5, 1.0, 2.0] {
        retryController.emit("failed")
        guard retryScheduler.delays.last == expected else { return false }
        retryScheduler.fire()
    }
    // The fourth unclassified failure goes to the yield ladder instead of reconnecting forever.
    retryController.emit("failed")
    guard retryAgent.state.connectionStatus == "yielded" && retryScheduler.delays.last == 60 else { return false }

    // Yield expiry while locked replaces itself with a peek instead of consuming the
    // only scheduler slot. It still does not acquire until wake.
    let yieldController = FakeAgentController(), yieldScheduler = FakeRetryScheduler(), yieldWriter = FakeStateWriter()
    let yielded = makeAgent(yieldController, yieldScheduler, yieldWriter, now: { clock })
    yielded.start(); _ = yielded.handle(.yield(seconds: 60)); yielded.setAsleep(true); yieldScheduler.fire()
    return yielded.ownershipForTesting == .released && yieldScheduler.isArmed && yieldScheduler.delays.last == 300
}

@MainActor func testSleepAndLockMustBothClearBeforeHoldResumes() -> Bool {
    func verify(lockThenSleep: Bool) -> Bool {
        var clock = Date(timeIntervalSince1970: 21_000)
        let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
        let agent = makeAgent(controller, scheduler, writer, now: { clock })
        agent.start()
        _ = agent.handle(.hold(true))
        guard controller.connects.count == 1 else { return false }
        if lockThenSleep {
            agent.setScreenLocked(true)
            agent.setAsleep(true)
            agent.setAsleep(false)
            guard controller.connects.count == 1, !scheduler.isArmed else { return false }
            agent.setScreenLocked(false)
        } else {
            agent.setAsleep(true)
            agent.setScreenLocked(true)
            agent.setScreenLocked(false)
            guard controller.connects.count == 1, !scheduler.isArmed else { return false }
            agent.setAsleep(false)
        }
        clock.addTimeInterval(2)
        scheduler.fire()
        return controller.connects.count == 2 && agent.ownershipForTesting == .acquiring
    }
    return verify(lockThenSleep: true) && verify(lockThenSleep: false)
}

func testStateReaderSymlinkCapAndProtocolBounds() -> Bool {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-symlink-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("large.json"), link = root.appendingPathComponent("state.json")
    let smallTarget = root.appendingPathComponent("small.json"), smallLink = root.appendingPathComponent("small-link.json")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let state = AgentState(connectionStatus: "connected", battery: AgentBattery(level: 50, charging: false))
    guard (try? AtomicStateWriter(url: smallTarget).write(state)) != nil,
          symlink(smallTarget.path, smallLink.path) == 0,
          AtomicStateReader(url: smallLink).read()?.connectionStatus == "connected",
          let encoded = try? Data(contentsOf: smallTarget) else { return false }
    var padded = encoded
    padded.append(Data(repeating: 0x20, count: AtomicStateReader.maximumStateFileBytes + 1 - encoded.count))
    try? padded.write(to: target)
    guard symlink(target.path, link.path) == 0, AtomicStateReader(url: link).read() == nil else { return false }
    // Long known ambient reports retain their documented fields; device-list parsing
    // requires one dedicated trailing playback byte.
    let ambient = SonyCommands.decodeAmbientSound([0x69, 0x19, 1, 1, 0, 1, 20, 0, 0, 0xaa, 0xbb])
    let malformedDeviceList = SonyCommands.decodeDeviceList([0, 2, 1] + Array("AA:BB:CC:DD:EE:FF".utf8) + [1, 0, 0, 0, 5] + Array("Phone".utf8))
    return ambient?.level == 20 && malformedDeviceList == nil
}

@MainActor func testAgentAmbientDialectAndRealSnapshotOwnership() async -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter(), mutations = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, writer, deviceMutationScheduler: mutations)
    agent.start(); _ = agent.handle(.hold(true))
    controller.value = AgentState(connectionStatus: "connected", ambient: AgentAmbient(mode: "nc", level: 11, focus: false, subtype: 0x17, hasWindNoiseByte: true)); controller.emit()
    _ = agent.handle(.setAmbient(mode: "ambient", level: 12, focus: true))
    guard controller.ambientWrites.last?.hasWindNoiseByte == false else { return false }
    // A persisted/attacker-provided selector is never passed through to a SET frame.
    // A reported 19 dialect (the one the old pass-through copied) never reaches a SET frame.
    controller.value.ambient = AgentAmbient(mode: "nc", level: 11, focus: false, subtype: 0x19); controller.emit()
    _ = agent.handle(.setAmbient(mode: "ambient", level: 12, focus: true))
    mutations.fire()
    guard controller.ambientWrites.count == 2, controller.ambientWrites.last?.subtype == 0x17 else {
        print("    agent writes: \(controller.ambientWrites.map { ($0.subtype, $0.hasWindNoiseByte) })"); return false
    }
    let snapshot = AgentStateSnapshot(AgentState(connectionStatus: "connecting"))
    let server = UnixIPCServer(path: "/unused", snapshot: snapshot, commandHandler: { _ in AgentReply(state: AgentState(connectionStatus: "disconnected")) })
    return server.reply(for: Data("{\"cmd\":\"status\"}".utf8)).ownership == "acquiring"
}

@MainActor func testExternalRateAndAgentQueueCaps() -> Bool {
    let clock = Date(timeIntervalSince1970: 30_000)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let resolver = FakeResolver(); resolver.device = nil
    let agent = XM6ConnectAgentCore(controller: controller, resolver: resolver, scheduler: scheduler, writer: writer,
        configURL: URL(fileURLWithPath: "/tmp/xm6connect-caps-\(UUID().uuidString).json"), now: { clock }, stateChanged: {})
    agent.start()
    for _ in 0..<(XM6ConnectAgentCore.maximumPendingActions + 10) { _ = agent.handle(.setSTC(true)) }
    for _ in 0..<(XM6ConnectAgentCore.maximumRefreshCompletions + 10) { agent.refresh { _ in } }
    guard XM6ConnectAgentCore.maximumPendingActions == 128,
          XM6ConnectAgentCore.maximumRefreshCompletions == 128,
          agent.pendingActionCountForTesting == 1,
          agent.refreshCompletionCountForTesting == 128 else { return false }
    var rateLimited = false
    for _ in 0...XM6ConnectAgentCore.maximumExternalActionsPerMinute {
        rateLimited = agent.handle(widgetAction: .cycle).error == "external action rate limited"
    }
    // Widget/URL-originated actions are explicitly excluded from lease activity.
    let heldController = FakeAgentController(), heldScheduler = FakeRetryScheduler(), heldWriter = FakeStateWriter()
    let held = makeAgent(heldController, heldScheduler, heldWriter, now: { clock })
    held.start(); _ = held.handle(.refresh); heldController.value = AgentState(connectionStatus: "connected"); heldController.emit()
    guard heldScheduler.delays.last == 20 else { return false }
    for _ in 0..<XM6ConnectAgentCore.maximumExternalActionsPerMinute { _ = held.handle(widgetAction: .cycle) }
    return rateLimited && heldScheduler.delays.last == 20
}

@MainActor func testPrewarmOnlyAcquiresFromReleasedAndNeverCommandStates() -> Bool {
    let clock = Date(timeIntervalSince1970: 40_000)
    let releasedController = FakeAgentController(), releasedScheduler = FakeRetryScheduler(), releasedWriter = FakeStateWriter()
    let released = makeAgent(releasedController, releasedScheduler, releasedWriter, now: { clock })
    released.start()
    _ = released.handle(.prewarm)
    guard releasedController.connects.count == 1, released.ownershipForTesting == .acquiring,
          released.prewarmAcquireAttemptsForTesting == 1 else { return false }

    // An in-flight acquisition is not a second acquisition opportunity.
    for _ in 0..<10 { _ = released.handle(.prewarm) }
    guard releasedController.connects.count == 1 else { return false }

    let yieldedController = FakeAgentController(), yieldedScheduler = FakeRetryScheduler(), yieldedWriter = FakeStateWriter()
    let yielded = makeAgent(yieldedController, yieldedScheduler, yieldedWriter, now: { clock })
    yielded.start(); _ = yielded.handle(.yield(seconds: 60)); _ = yielded.handle(.prewarm)
    guard yieldedController.connects.isEmpty, yielded.ownershipForTesting == .yielded,
          yielded.prewarmAcquireAttemptsForTesting == 0 else { return false }

    let heldController = FakeAgentController(), heldScheduler = FakeRetryScheduler(), heldWriter = FakeStateWriter()
    let held = makeAgent(heldController, heldScheduler, heldWriter, now: { clock })
    held.start(); _ = held.handle(.refresh); heldController.value = AgentState(connectionStatus: "connected", battery: AgentBattery(level: 81, charging: false)); heldController.emit()
    let heldConnects = heldController.connects.count; _ = held.handle(.prewarm)
    guard heldController.connects.count == heldConnects, held.ownershipForTesting == .held,
          held.prewarmAcquireAttemptsForTesting == 0 else { return false }

    let asleepController = FakeAgentController(), asleepScheduler = FakeRetryScheduler(), asleepWriter = FakeStateWriter()
    let asleep = makeAgent(asleepController, asleepScheduler, asleepWriter, now: { clock })
    asleep.start(); asleep.setAsleep(true); _ = asleep.handle(.prewarm)
    return asleepController.connects.isEmpty && asleep.ownershipForTesting == .released
        && asleep.prewarmAcquireAttemptsForTesting == 0
}

@MainActor func testPrewarmHasEightSecondCapAndDoesNotBecomeCommandActivity() -> Bool {
    var clock = Date(timeIntervalSince1970: 41_000)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start()
    let commandBefore = agent.lastCommandForTesting
    _ = agent.handle(.prewarm)
    controller.value = AgentState(connectionStatus: "connected", battery: AgentBattery(level: 72, charging: false))
    controller.emit()
    guard agent.lastCommandForTesting == commandBefore,
          agent.prewarmDeadlineForTesting == clock.addingTimeInterval(XM6ConnectAgentCore.prewarmHold),
          scheduler.delays.last == XM6ConnectAgentCore.prewarmHold else { return false }
    // A state report during the sweep must retain the remaining bounded deadline,
    // not reschedule the normal 20-second command idle lease.
    clock.addTimeInterval(3); controller.value.battery = AgentBattery(level: 71, charging: false); controller.emit()
    guard scheduler.delays.last == 5 else { return false }
    scheduler.fire()
    return agent.ownershipForTesting == .released && agent.state.connectionStatus == "released"
}

@MainActor func testQueuedCommandEntersBeforeFullStateSweepAtHandshake() -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer)
    agent.start(); _ = agent.handle(.setSTC(true))
    guard controller.stcWrites.isEmpty else { return false }
    controller.value = AgentState(connectionStatus: "connected")
    controller.emit()
    // `refreshState()` records after the queued setter. Reversing the P1 ordering
    // makes this fail and reproduces the full-sweep queueing regression.
    return controller.stcWrites == [true] && controller.refreshes == 1
        && controller.outboundEvents == ["stc", "refresh"]
}

@MainActor func testEnablingHoldOnAHeldLeaseDoesNotStrandTheAgent() -> Bool {
    // The lease can be held with hold
    // off, so an idle release was armed for +20 s. Enabling hold then returned early from
    // acquire() because the lease was already held, leaving that timer running. It fired,
    // tore the channel down, and schedulePeek() refused to arm anything because hold was
    // on — so the agent sat released forever while claiming to hold the channel.
    var clock = Date(timeIntervalSince1970: 8_000)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), timer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, acquisitionScheduler: timer)
    agent.start(); _ = agent.handle(.refresh)
    controller.value = AgentState(connectionStatus: "connected"); controller.emit()
    guard agent.ownershipForTesting == .held else { return false }
    _ = agent.handle(.hold(true))
    // Whatever the resting policy had armed must not now tear down a held lease.
    clock.addTimeInterval(25)
    if scheduler.isArmed { scheduler.fire() }
    return agent.ownershipForTesting == .held && controller.disconnects == 0
}

@MainActor func testUserCommandSupersedesPeekInYieldAndAcquisition() -> Bool {
    let yieldedController = FakeAgentController(), yieldedScheduler = FakeRetryScheduler(), yieldedDeadline = FakeRetryScheduler()
    let yielded = makeAgent(yieldedController, yieldedScheduler, acquisitionScheduler: yieldedDeadline)
    yielded.start(); yieldedScheduler.fire()
    yieldedDeadline.fire()
    guard yielded.state.connectionStatus == "yielded" else { return false }
    _ = yielded.handle(.setAmbient(mode: "ambient", level: 10, focus: false))
    yieldedController.value = AgentState(connectionStatus: "connected", battery: AgentBattery(level: 80, charging: false))
    yieldedController.emit()
    guard yieldedController.ambientWrites.count == 1 && yielded.ownershipForTesting == .held else { return false }

    let acquiringController = FakeAgentController(), acquiringScheduler = FakeRetryScheduler(), acquiringDeadline = FakeRetryScheduler()
    let acquiring = makeAgent(acquiringController, acquiringScheduler, acquisitionScheduler: acquiringDeadline)
    acquiring.start(); acquiringScheduler.fire()
    _ = acquiring.handle(.setAmbient(mode: "ambient", level: 11, focus: true))
    acquiringController.value = AgentState(connectionStatus: "connected", battery: AgentBattery(level: 80, charging: false))
    acquiringController.emit()
    return acquiringController.ambientWrites.count == 1 && acquiring.ownershipForTesting == .held
}

@MainActor func testHoldEnablePreservesPendingRetries() -> Bool {
    let fastController = FakeAgentController(), fastScheduler = FakeRetryScheduler()
    let fast = makeAgent(fastController, fastScheduler)
    fast.start(); _ = fast.handle(.refresh); fastController.emit("failed")
    guard fastScheduler.isArmed else { return false }
    _ = fast.handle(.hold(true)); fastScheduler.fire()
    guard fastController.connects.count == 2 else { return false }

    let bounceController = FakeAgentController(), bounceScheduler = FakeRetryScheduler(), deadline = FakeRetryScheduler()
    let bounce = makeAgent(bounceController, bounceScheduler, acquisitionScheduler: deadline)
    bounce.start(); _ = bounce.handle(.refresh); bounceController.emit("initializing")
    deadline.fire()
    guard bounceScheduler.isArmed else { return false }
    _ = bounce.handle(.hold(true)); bounceScheduler.fire()
    return bounceController.connects.count == 2
}
