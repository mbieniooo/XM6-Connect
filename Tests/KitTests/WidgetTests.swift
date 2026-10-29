import Foundation
import Darwin
import SonyHeadphonesKit
import XM6ConnectAgentCore
import XM6ConnectWidgetLogic
import XM6ConnectAppLogic

func testWidgetIntentNotificationMapping() -> Bool {
    let actions = XM6ConnectDarwinNotification.commandActions
    let names = actions.map { XM6ConnectDarwinNotification.name(for: $0) }
    let modes: Set<XM6ConnectDarwinNotification.Action> = [.noiseCancelling, .ambient, .off]
    let everyPresetIsNamed = EqualizerPreset.allCases.allSatisfy { preset in
        let action = XM6ConnectDarwinNotification.Action.equalizer(preset)
        return actions.contains(action) && XM6ConnectDarwinNotification.agentAction(for: XM6ConnectDarwinNotification.name(for: action)) == action
    }
    return names.count == Set(names).count
        && XM6ConnectDarwinNotification.name(for: .noiseCancelling) == XM6ConnectDarwinNotification.productionNamespace + "mode.nc"
        && XM6ConnectDarwinNotification.url(for: .noiseCancelling).absoluteString == "xm6connect://action/mode.nc"
        && Set(actions.filter { modes.contains($0) }) == modes
        && everyPresetIsNamed
        && XM6ConnectDarwinNotification.agentAction(for: XM6ConnectDarwinNotification.productionNamespace + "eq.missing") == nil
}

func testEveryAgentSubscribedNotificationDecodes() -> Bool {
    // Every notification observed by the agent must decode through its wider action set.
    let subscribed = XM6ConnectDarwinNotification.agentActions
    let everySubscribedDecodes = subscribed.allSatisfy { action in
        XM6ConnectDarwinNotification.agentAction(for: XM6ConnectDarwinNotification.name(for: action)) == action
    }
    // Prewarm must NOT become reachable from the command/URL surface, which any local
    // process can post to: it is an advisory lease signal, not a headset command.
    let prewarmStaysOffTheCommandSurface =
        !XM6ConnectDarwinNotification.commandActions.contains(.prewarm)
        && XM6ConnectDarwinNotification.action(for: XM6ConnectDarwinNotification.url(for: .prewarm)) == nil
    let commandsStillDecodeBothWays = XM6ConnectDarwinNotification.commandActions.allSatisfy { action in
        XM6ConnectDarwinNotification.agentAction(for: XM6ConnectDarwinNotification.name(for: action)) == action
    }
    let otherUID: uid_t = getuid() == 0 ? 1 : 0
    let otherUserNamespace = "user.uid.\(otherUID).io.github.mbieniooo.xm6connect."
    return subscribed.contains(.prewarm)
        && everySubscribedDecodes
        && prewarmStaysOffTheCommandSurface
        && commandsStillDecodeBothWays
        && XM6ConnectDarwinNotification.agentAction(for: "io.github.mbieniooo.xm6connect.mode.nc") == nil
        && XM6ConnectDarwinNotification.agentAction(for: otherUserNamespace + "mode.nc") == nil
}

@MainActor private final class ActionRecorder {
    var received: [XM6ConnectDarwinNotification.Action] = []
}

@MainActor func testDarwinObserverDeliversPrewarmEndToEnd() async -> Bool {
    // Use a private user namespace so this integration test cannot signal a resident agent.
    let namespace = "user.uid.\(getuid()).xm6connect-test-\(UUID().uuidString)."
    let recorder = ActionRecorder()
    let observer = XM6ConnectDarwinNotification.agentActionObserver(namespace: namespace) { action in
        MainActor.assumeIsolated { recorder.received.append(action) }
    }
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(XM6ConnectDarwinNotification.name(for: .prewarm, namespace: namespace) as CFString),
        nil, nil, true
    )
    let deadline = Date().addingTimeInterval(5)
    while recorder.received.isEmpty && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    _ = observer
    return recorder.received == [.prewarm]
}

@MainActor func testDarwinObserverDeliversAndStops() async -> Bool {
    let namespace = "user.uid.\(getuid()).xm6connect-test-\(UUID().uuidString)."
    let name = namespace + "statechanged"
    var received: [String] = []
    var observer: DarwinObserver? = DarwinObserver(names: [name]) { receivedName in
        received.append(receivedName)
    }
    guard observer != nil else { return false }
    for _ in 0..<2 {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true
        )
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
    observer = nil
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFNotificationName(name as CFString), nil, nil, true
    )
    try? await Task.sleep(nanoseconds: 100_000_000)
    return received == [name, name]
}

func testWidgetActionURLRoundTripAndRejection() -> Bool {
    let actions = XM6ConnectDarwinNotification.commandActions
    let urls = actions.map(XM6ConnectDarwinNotification.url(for:))
    let invalidURLs = [
        "https://action/cycle",
        "xm6connect://other/cycle",
        "xm6connect://action/not-an-action",
        "xm6connect://action/cycle/extra",
        "xm6connect://action/cycle/",
        "xm6connect://action/cycle?raw=1",
        "xm6connect://action/",
        "XM6CONNECT://action/mode.nc",
        "xm6connect://ACTION/mode.nc",
        "xm6connect://action/mode%2Enc",
        "xm6connect://action/mode.nc/"
    ]
    return actions.count == Set(actions).count
        && urls.count == Set(urls).count
        && urls.allSatisfy { $0.scheme == "xm6connect" && XM6ConnectDarwinNotification.action(for: $0) != nil }
        && Set(urls.compactMap { XM6ConnectDarwinNotification.action(for: $0) }) == Set(actions)
        && invalidURLs.allSatisfy { URL(string: $0).flatMap(XM6ConnectDarwinNotification.action(for:)) == nil }
}

@MainActor
func testWidgetURLMapsToPopoverAppCommand() -> Bool {
    let model = PopoverModel()
    model.apply(AppReply(state: AppState(
        connectionStatus: "connected",
        ambient: AppAmbient(mode: "ambient", level: 14, focus: true, subtype: 0x19)
    )))
    for action in XM6ConnectDarwinNotification.commandActions {
        guard let parsed = XM6ConnectDarwinNotification.action(for: XM6ConnectDarwinNotification.url(for: action)) else { return false }
        let expected: AppCommand
        switch action {
        case .prewarm: expected = .status
        case .cycle: expected = .cycle
        case .noiseCancelling: expected = .setMode(.nc)
        case .ambient: expected = .setMode(.ambient)
        case .off: expected = .setMode(.off)
        case .equalizer(let preset): expected = .setEQPreset(Int(preset.rawValue))
        }
        guard AppCommand.command(for: parsed) == expected else { return false }
    }
    return true
}

func testFreshnessFollowsTheStateAge() -> Bool {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-control-label-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let staleURL = directory.appendingPathComponent("stale.json")
    let noBatteryURL = directory.appendingPathComponent("no-battery.json")
    let missingURL = directory.appendingPathComponent("missing.json")
    let formatter = ISO8601DateFormatter()
    let now = Date(timeIntervalSince1970: 10_000)
    let stateAsOf = now.addingTimeInterval(-XM6ConnectStateReader.maximumAge - 1)
    guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
        print("    could not create temporary state directory")
        return false
    }
    let stale = "{\"ambient\":{\"mode\":\"nc\"},\"battery\":{\"level\":80,\"charging\":false},\"stateAsOf\":\"" + formatter.string(from: stateAsOf) + "\"}"
    let noBattery = "{\"ambient\":{\"mode\":\"nc\"},\"stateAsOf\":\"" + formatter.string(from: now) + "\"}"
    guard let staleData = stale.data(using: .utf8), let noBatteryData = noBattery.data(using: .utf8) else {
        print("    could not encode temporary state")
        return false
    }
    do {
        try staleData.write(to: staleURL)
        try noBatteryData.write(to: noBatteryURL)
    } catch {
        print("    could not write temporary state: \(error)")
        return false
    }
    let agedModel = XM6ConnectStateReader.readViewModel(from: staleURL, now: now)
    guard agedModel.freshness == .stale && agedModel.batteryLevel == 80 else {
        print("    aged state: freshness \(agedModel.freshness), battery \(String(describing: agedModel.batteryLevel))")
        return false
    }
    let freshModel = XM6ConnectStateReader.readViewModel(from: staleURL, now: stateAsOf)
    guard freshModel.freshness == .fresh && freshModel.batteryLevel == 80 else {
        print("    same file read at its own timestamp: freshness \(freshModel.freshness)")
        return false
    }
    let noBatteryModel = XM6ConnectStateReader.readViewModel(from: noBatteryURL, now: now)
    guard noBatteryModel.freshness == .fresh && noBatteryModel.batteryLevel == nil else {
        print("    state without a battery: freshness \(noBatteryModel.freshness), battery \(String(describing: noBatteryModel.batteryLevel))")
        return false
    }
    guard XM6ConnectStateReader.readViewModel(from: missingURL, now: now) == .unavailable else {
        print("    a missing state file was not reported as unavailable")
        return false
    }
    return true
}

func testFailedStateDimsAtOnce() -> Bool {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-failed-state-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let formatter = ISO8601DateFormatter()
    let now = Date(timeIntervalSince1970: 10_000)
    guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
        print("    could not create temporary state directory")
        return false
    }
    func model(status: String?) -> XM6ConnectWidgetViewModel? {
        let statusField = status.map { "\"connectionStatus\":\"\($0)\"," } ?? ""
        let state = "{\(statusField)\"ambient\":{\"mode\":\"nc\"},\"battery\":{\"level\":80,\"charging\":false},\"stateAsOf\":\"" + formatter.string(from: now) + "\"}"
        guard let data = state.data(using: .utf8) else { return nil }
        do { try data.write(to: stateURL) } catch { return nil }
        return XM6ConnectStateReader.readViewModel(from: stateURL, now: now)
    }
    guard let failed = model(status: "failed") else {
        print("    could not write failed state")
        return false
    }
    guard failed.freshness == .stale else {
        print("    failed state: freshness \(failed.freshness)")
        return false
    }
    for status in ["disconnected", "released", "connected"] {
        guard model(status: status)?.freshness == .fresh else {
            print("    \(status) state was not fresh")
            return false
        }
    }
    guard model(status: nil)?.freshness == .fresh else {
        print("    state without connectionStatus was not fresh")
        return false
    }
    return true
}

func testTimelineSchedulesTheStaleSwitch() -> Bool {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-widget-timeline-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateURL = directory.appendingPathComponent("state.json")
    let formatter = ISO8601DateFormatter()
    let now = Date(timeIntervalSince1970: 10_000)
    let stateAsOf = now.addingTimeInterval(-19 * 60)
    let expectedStaleAt = stateAsOf.addingTimeInterval(XM6ConnectStateReader.maximumAge + 1)
    guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
        print("    could not create temporary state directory")
        return false
    }
    func writeState(connectionStatus: String? = nil, stateAsOf: Date) -> Bool {
        let statusField = connectionStatus.map { "\"connectionStatus\":\"\($0)\"," } ?? ""
        let state = "{\(statusField)\"ambient\":{\"mode\":\"nc\"},\"stateAsOf\":\"" + formatter.string(from: stateAsOf) + "\"}"
        guard let data = state.data(using: .utf8) else { return false }
        do { try data.write(to: stateURL); return true } catch { return false }
    }
    guard writeState(stateAsOf: stateAsOf) else {
        print("    could not write fresh state")
        return false
    }
    let fresh = XM6ConnectStateReader.readViewModel(from: stateURL, now: now)
    guard fresh.staleAt == expectedStaleAt else {
        print("    staleAt: \(String(describing: fresh.staleAt)) expected \(expectedStaleAt)")
        return false
    }
    guard XM6ConnectWidgetLogic.timelineDates(for: fresh, now: now) == [now, expectedStaleAt] else {
        print("    scheduled dates: \(XM6ConnectWidgetLogic.timelineDates(for: fresh, now: now))")
        return false
    }
    guard XM6ConnectStateReader.readViewModel(from: stateURL, now: expectedStaleAt).freshness == .stale,
          XM6ConnectStateReader.readViewModel(from: stateURL, now: expectedStaleAt.addingTimeInterval(-1)).freshness == .fresh else {
        print("    age boundary did not switch from fresh to stale")
        return false
    }
    guard writeState(stateAsOf: now.addingTimeInterval(-XM6ConnectStateReader.maximumAge - 1)) else {
        print("    could not write stale state")
        return false
    }
    let stale = XM6ConnectStateReader.readViewModel(from: stateURL, now: now)
    guard stale.staleAt == nil && XM6ConnectWidgetLogic.timelineDates(for: stale, now: now) == [now] else {
        print("    stale state scheduled \(String(describing: stale.staleAt))")
        return false
    }
    guard writeState(connectionStatus: "failed", stateAsOf: now) else {
        print("    could not write failed state")
        return false
    }
    let failed = XM6ConnectStateReader.readViewModel(from: stateURL, now: now)
    guard XM6ConnectWidgetLogic.timelineDates(for: failed, now: now) == [now] else {
        print("    failed state scheduled extra dates")
        return false
    }
    let pastStaleAt = XM6ConnectWidgetViewModel(freshness: .fresh, staleAt: now)
    guard XM6ConnectWidgetLogic.timelineDates(for: pastStaleAt, now: now) == [now] else {
        print("    past staleAt scheduled extra dates")
        return false
    }
    return true
}

func testWidgetStateDecodeFallbacks() -> Bool {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-widget-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let validURL = directory.appendingPathComponent("valid.json")
    let corruptURL = directory.appendingPathComponent("corrupt.json")
    let unknownURL = directory.appendingPathComponent("unknown.json")
    let staleURL = directory.appendingPathComponent("stale.json")
    let oversizedURL = directory.appendingPathComponent("oversized.json")
    let formatter = ISO8601DateFormatter()
    let now = Date(timeIntervalSince1970: 10_000)
    let valid = "{\"connectionStatus\":\"connected\",\"ambient\":{\"mode\":\"ambient\",\"subtype\":25},\"battery\":{\"level\":87,\"charging\":true},\"equalizer\":{\"presetCode\":50},\"timestamp\":\"" + formatter.string(from: Date(timeIntervalSince1970: 1)) + "\",\"stateAsOf\":\"" + formatter.string(from: now) + "\"}"
    let unknown = "{\"ambient\":{\"mode\":\"nc\"},\"equalizer\":{\"presetCode\":127},\"stateAsOf\":\"" + formatter.string(from: now) + "\"}"
    let stale = "{\"ambient\":{\"mode\":\"off\"},\"stateAsOf\":\"" + formatter.string(from: now.addingTimeInterval(-XM6ConnectStateReader.maximumAge - 1)) + "\"}"
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let validData = valid.data(using: .utf8) else { return false }
    try? validData.write(to: validURL)
    try? Data("not json".utf8).write(to: corruptURL)
    try? Data(unknown.utf8).write(to: unknownURL)
    try? Data(stale.utf8).write(to: staleURL)
    try? Data(repeating: 0, count: XM6ConnectStateReader.maximumStateFileBytes + 1).write(to: oversizedURL)
    let model = XM6ConnectStateReader.readViewModel(from: validURL, now: now)
    let unknownModel = XM6ConnectStateReader.readViewModel(from: unknownURL, now: now)
    let staleModel = XM6ConnectStateReader.readViewModel(from: staleURL, now: now)
    return model.selectedMode == .ambient && model.selectedPreset == .hard && model.batteryLevel == 87 && model.charging && model.freshness == .fresh
        && unknownModel.selectedMode == .noiseCancelling && unknownModel.selectedPreset == nil && unknownModel.freshness == .fresh
        && staleModel.selectedMode == .off && staleModel.freshness == .stale
        && XM6ConnectStateReader.readViewModel(from: directory.appendingPathComponent("missing.json"), now: now) == .unavailable
        && XM6ConnectStateReader.readViewModel(from: corruptURL, now: now) == .unavailable
        && XM6ConnectStateReader.readViewModel(from: oversizedURL, now: now) == .unavailable
}

func testWidgetAgentStatePathAgreement() -> Bool {
    let home = URL(fileURLWithPath: "/tmp/xm6connect-home", isDirectory: true)
    let expected = home
        .appendingPathComponent(XM6ConnectPaths.agentSupportDirectoryRelativePath, isDirectory: true)
        .appendingPathComponent("state.json")
    let socket = XM6ConnectPaths.agentSocketPath(homeDirectory: home)
    let socketExpected = "/tmp/xm6connect-home/Library/Application Support/XM6Connect/agent.sock"
    let transportPath = UnixAppSocketTransport().path
    let defaultSocket = XM6ConnectPaths.agentSocketPath()
    let agrees = XM6ConnectStateReader.agentStateURL(homeDirectory: home) == expected
        && socket == socketExpected
        && transportPath == defaultSocket
    if !agrees {
        print("    socket path for the test home: \(socket) (expected \(socketExpected)); app transport: \(transportPath) (default \(defaultSocket))")
    }
    return agrees
}

func testWidgetReaderDoesNotFallBackToContainerMirror() -> Bool {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-no-fallback-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let oldMirror = home.appendingPathComponent("Library/Containers/io.github.mbieniooo.xm6connect.widget/Data/Library/Application Support/XM6Connect/state.json")
    let now = Date(timeIntervalSince1970: 10_000)
    let stamp = ISO8601DateFormatter().string(from: now)
    let snapshot = "{\"ambient\":{\"mode\":\"ambient\"},\"stateAsOf\":\"" + stamp + "\"}"
    try? FileManager.default.createDirectory(at: oldMirror.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(snapshot.utf8).write(to: oldMirror)
    return XM6ConnectStateReader.readViewModel(
        from: XM6ConnectStateReader.agentStateURL(homeDirectory: home),
        now: now
    ) == .unavailable
}

func testWidgetReaderSymlinkSizeCap() -> Bool {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-widget-symlink-cap-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let smallTarget = root.appendingPathComponent("small.json")
    let largeTarget = root.appendingPathComponent("large.json")
    let smallLink = root.appendingPathComponent("small-link.json")
    let largeLink = root.appendingPathComponent("large-link.json")
    let now = Date(timeIntervalSince1970: 10_000)
    let stamp = ISO8601DateFormatter().string(from: now)
    let snapshot = "{\"ambient\":{\"mode\":\"nc\"},\"stateAsOf\":\"" + stamp + "\"}"
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? Data(snapshot.utf8).write(to: smallTarget)
    try? Data((snapshot + String(repeating: " ", count: XM6ConnectStateReader.maximumStateFileBytes + 1)).utf8).write(to: largeTarget)
    try? FileManager.default.createSymbolicLink(at: smallLink, withDestinationURL: smallTarget)
    try? FileManager.default.createSymbolicLink(at: largeLink, withDestinationURL: largeTarget)
    return XM6ConnectStateReader.readViewModel(from: smallLink, now: now).freshness == .fresh
        && XM6ConnectStateReader.readViewModel(from: smallLink, now: now).selectedMode == .noiseCancelling
        && XM6ConnectStateReader.readViewModel(from: largeLink, now: now) == .unavailable
}

@MainActor func testWidgetActionsUseLeaseAndIPCRouteExactlyOnce() async -> Bool {
    let actions: [XM6ConnectDarwinNotification.Action] = [.noiseCancelling, .ambient, .off] + EqualizerPreset.allCases.map { .equalizer($0) }
    for action in actions {
        let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
        let agent = makeAgent(controller, scheduler, writer)
        agent.start()
        guard agent.ownershipForTesting == .released else { return false }
        _ = agent.handle(widgetAction: action)
        // The widget command takes the same real acquisition path as IPC; it is
        // explicitly acquiring until the bridge publishes a connected snapshot.
        guard controller.connects.count == 1, agent.ownershipForTesting == .acquiring else { return false }
        controller.value = AgentState(connectionStatus: "connected", ambient: AgentAmbient(mode: "ambient", level: 12, focus: true, subtype: 0x19))
        controller.emit()
        switch action {
        case .prewarm: return false
        case .noiseCancelling:
            guard controller.ambientWrites.count == 1, controller.ambientWrites[0].mode == .noiseCancelling, controller.ambientWrites[0].subtype == 0x17 else { return false }
        case .ambient:
            guard controller.ambientWrites.count == 1, controller.ambientWrites[0].mode == .ambientSound else { return false }
        case .off:
            guard controller.ambientWrites.count == 1, controller.ambientWrites[0].mode == .off else { return false }
        case .equalizer(let preset):
            guard controller.equalizerPresetWrites.count == 1,
                  controller.equalizerPresetWrites[0].0 == preset.rawValue,
                  controller.equalizerPresetWrites[0].1 == 0x04 else { return false }
        case .cycle: return false
        }
        // This is the same S1 idle-release path used by IPC mutations, not a
        // widget-held connection.  The last scheduled action is its 20-second lease.
        guard let idleDelay = scheduler.delays.last, (19...20).contains(idleDelay) else { return false }
        scheduler.fire()
        guard agent.state.connectionStatus == "released" else { return false }
    }
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer)
    agent.start(); _ = agent.handle(.hold(true)); controller.emit("connected")
    for index in 0..<100 { _ = agent.handle(widgetAction: .equalizer(EqualizerPreset.allCases[index % EqualizerPreset.allCases.count])) }
    try? await Task.sleep(nanoseconds: 260_000_000)
    return controller.equalizerPresetWrites.count <= 6
}

func testInputBoundaryGuardsAreRealNotDecorative() -> Bool {
    // Each payload below is valid in EVERY respect except the
    // one guard under test — an earlier version of this test padded with an extra JSON
    // field and with JSON lacking stateAsOf, so both were rejected for unrelated reasons
    // and the test passed with the guards removed.

    // 1. URL parsing. The scheme check is redundant defence-in-depth: the real gate is
    //    the exact round-trip against the canonical URL, so assert THAT holds.
    let good = XM6ConnectDarwinNotification.url(for: .noiseCancelling)
    guard XM6ConnectDarwinNotification.action(for: good) == .noiseCancelling else { return false }
    for bad in ["http://action/mode.nc", "xm6connect://elsewhere/mode.nc", "xm6connect://action",
                "xm6connect://action/mode.nc?x=1", "xm6connect://action/mode.nc#f",
                "xm6connect://user@action/mode.nc", "xm6connect://action/deeper/mode.nc"] {
        guard let url = URL(string: bad), XM6ConnectDarwinNotification.action(for: url) == nil else { return false }
    }

    // 2. Widget state-file size cap: valid, decodable, FRESH JSON whose only sin is size.
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-cap-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 50_000)
    let stamp = ISO8601DateFormatter().string(from: now)
    let smallURL = directory.appendingPathComponent("small.json")
    let hugeURL = directory.appendingPathComponent("huge.json")
    let body = "{\"connectionStatus\":\"connected\",\"ambient\":{\"mode\":\"nc\"},\"stateAsOf\":\"" + stamp + "\",\"timestamp\":\"" + stamp + "\"}"
    try? Data(body.utf8).write(to: smallURL)
    // Same document, padded with whitespace (still valid JSON) past the cap.
    let padded = body + String(repeating: " ", count: XM6ConnectStateReader.maximumStateFileBytes + 1024)
    try? Data(padded.utf8).write(to: hugeURL)
    // Control: the unpadded document decodes, proving only size differs.
    guard XM6ConnectStateReader.readViewModel(from: smallURL, now: now).selectedMode == .noiseCancelling else { return false }
    guard XM6ConnectStateReader.readViewModel(from: hugeURL, now: now) == .unavailable else { return false }

    // 3. IPC request size cap: a well-formed status request with ONLY the cmd key,
    //    padded with in-JSON whitespace so nothing but the cap can reject it.
    let smallRequest = Data("{\"cmd\":\"status\"}".utf8)
    guard case .success = IPCRequest.parse(smallRequest) else { return false }
    let hugeRequest = Data(("{\"cmd\":\"status\"" + String(repeating: " ", count: IPCRequest.maximumLineBytes + 1024) + "}").utf8)
    guard hugeRequest.count > IPCRequest.maximumLineBytes else { return false }
    if case .success = IPCRequest.parse(hugeRequest) { return false }
    return true
}
