import Foundation
import SonyHeadphonesKit
import XM6ConnectAgentCore

@MainActor func testCycleUsesFreshReportAfterRelease() -> Bool {
    var clock = Date(timeIntervalSince1970: 300)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start(); _ = agent.handle(.refresh)
    controller.value.ambient = AgentAmbient(mode: "nc", level: 9, focus: false, subtype: 0x19); controller.emit("connected")
    _ = agent.handle(.hold(false)); clock.addTimeInterval(3)
    _ = agent.handle(.cycle)
    controller.value = AgentState(connectionStatus: "connected")
    controller.emit()
    controller.value.ambient = AgentAmbient(mode: "ambient", level: 9, focus: false, subtype: 0x19)
    controller.emit()
    return controller.ambientWrites.last?.mode == .off
}

@MainActor func testKeyedColdMutationQueueSendsEverySettingInOrder() -> Bool {
    var clock = Date(timeIntervalSince1970: 350)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start()
    _ = agent.handle(.setAmbient(mode: "nc", level: 8, focus: false))
    _ = agent.handle(.setEQPreset(code: 0x31))
    _ = agent.handle(.setSTC(true))
    controller.emit("connected")
    guard controller.outboundEvents.filter({ $0 != "refresh" }) == ["ambient"], mutationTimer.armedDelay == 0.2 else { return false }
    clock.addTimeInterval(0.2); mutationTimer.fire()
    guard controller.outboundEvents.filter({ $0 != "refresh" }) == ["ambient", "equalizer"], mutationTimer.armedDelay == 0.2 else { return false }
    clock.addTimeInterval(0.2); mutationTimer.fire()
    return controller.outboundEvents.filter({ $0 != "refresh" }) == ["ambient", "equalizer", "stc"]
}

@MainActor func testKeyedHeldMutationQueueSendsEverySettingInOrder() -> Bool {
    var clock = Date(timeIntervalSince1970: 360)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.hold(true)); controller.emit("connected")
    _ = agent.handle(.setSTC(true)); _ = agent.handle(.setEQPreset(code: 0x31)); _ = agent.handle(.setListeningMode(mode: "cinema"))
    guard controller.outboundEvents.filter({ $0 != "refresh" }) == ["stc"], mutationTimer.armedDelay == 0.2 else { return false }
    clock.addTimeInterval(0.2); mutationTimer.fire()
    guard controller.outboundEvents.filter({ $0 != "refresh" }) == ["stc", "equalizer"], mutationTimer.armedDelay == 0.2 else { return false }
    clock.addTimeInterval(0.2); mutationTimer.fire()
    return controller.outboundEvents.filter({ $0 != "refresh" }) == ["stc", "equalizer", "listening"]
}

@MainActor func testKeyedAmbientMutationKeepsOnlyLatestPendingValue() -> Bool {
    var clock = Date(timeIntervalSince1970: 370)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.hold(true)); controller.emit("connected")
    _ = agent.handle(.setSTC(true))
    for level in 1...5 { _ = agent.handle(.setAmbient(mode: "ambient", level: level, focus: false)) }
    guard controller.ambientWrites.isEmpty, mutationTimer.armedDelay == 0.2 else { return false }
    clock.addTimeInterval(0.2); mutationTimer.fire()
    return controller.ambientWrites.map(\.level) == [5]
}

@MainActor func testPendingCycleAndOtherSettingsAllSend() -> Bool {
    var clock = Date(timeIntervalSince1970: 380)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.hold(true))
    controller.value.ambient = AgentAmbient(mode: "ambient", level: 9, focus: true, subtype: 0x19); controller.emit("connected")
    _ = agent.handle(.setSTC(true))
    _ = agent.handle(.cycle); _ = agent.handle(.setEQPreset(code: 0x31)); _ = agent.handle(.setBGMRoomSize(rawValue: 2))
    clock.addTimeInterval(0.2); mutationTimer.fire()
    clock.addTimeInterval(0.2); mutationTimer.fire()
    clock.addTimeInterval(0.2); mutationTimer.fire()
    return controller.ambientWrites.last?.mode == .off
        && controller.equalizerPresetWrites.count == 1
        && controller.bgmRoomSizeWrites == [2]
}

@MainActor func testWidgetModeUsesCurrentSessionAmbientReport() -> Bool {
    var clock = Date(timeIntervalSince1970: 390)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.refresh)
    controller.value.ambient = AgentAmbient(mode: "ambient", level: 2, focus: false, subtype: 0x19); controller.emit("connected")
    _ = agent.handle(.hold(false)); clock.addTimeInterval(3)
    _ = agent.handle(widgetAction: .noiseCancelling)
    controller.value = AgentState(connectionStatus: "connected"); controller.emit()
    guard controller.ambientWrites.isEmpty else { return false }
    controller.value.ambient = AgentAmbient(mode: "ambient", level: 7, focus: true, subtype: 0x19); controller.emit()
    return controller.ambientWrites.last?.mode == .noiseCancelling
        && controller.ambientWrites.last?.level == 7
        && controller.ambientWrites.last?.focusOnVoice == true
}

@MainActor func testWidgetPrewarmNeverConsumesTheActionAllowance() -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer)
    for _ in 0...30 { _ = agent.handle(widgetAction: .prewarm) }
    return agent.handle(widgetAction: .noiseCancelling).error != "external action rate limited"
}

@MainActor func testHeldRelativeAmbientWaitsForThisSessionsReport() -> Bool {
    // The real kit publishes "connected" before the new session's ambient report. A widget
    // mode tap in that window must wait for the report, not run, find nothing and vanish.
    var clock = Date(timeIntervalSince1970: 395)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.refresh)
    controller.value = AgentState(connectionStatus: "connected"); controller.emit()
    guard agent.ownershipForTesting == .held else { return false }
    clock.addTimeInterval(1)
    _ = agent.handle(widgetAction: .noiseCancelling)
    guard controller.ambientWrites.isEmpty else { return false }
    controller.value.ambient = AgentAmbient(mode: "ambient", level: 7, focus: true, subtype: 0x19); controller.emit()
    if mutationTimer.isArmed { clock.addTimeInterval(0.2); mutationTimer.fire() }
    return controller.ambientWrites.count == 1
        && controller.ambientWrites.last?.mode == .noiseCancelling
        && controller.ambientWrites.last?.level == 7
        && controller.ambientWrites.last?.focusOnVoice == true
}

@MainActor func testExplicitAmbientSupersedesAWaitingWidgetMode() -> Bool {
    // Latest wins per setting across both queues: a widget mode still waiting for this
    // session's report must not be sent after a newer explicit ambient choice.
    var clock = Date(timeIntervalSince1970: 397)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.refresh)
    controller.value = AgentState(connectionStatus: "connected"); controller.emit()
    guard agent.ownershipForTesting == .held else { return false }
    clock.addTimeInterval(1)
    _ = agent.handle(widgetAction: .noiseCancelling)
    clock.addTimeInterval(0.5)
    _ = agent.handle(.setAmbient(mode: "ambient", level: 12, focus: false))
    if mutationTimer.isArmed { clock.addTimeInterval(0.2); mutationTimer.fire() }
    controller.value.ambient = AgentAmbient(mode: "nc", level: 7, focus: true, subtype: 0x19); controller.emit()
    if mutationTimer.isArmed { clock.addTimeInterval(0.2); mutationTimer.fire() }
    return controller.ambientWrites.count == 1
        && controller.ambientWrites.last?.mode == .ambientSound
        && controller.ambientWrites.last?.level == 12
}

@MainActor func testSetModeTakesLevelAndFocusFromThisSessionsReport() -> Bool {
    // The phone changed level and focus while the Mac was released; a mode change from the
    // widget, popover or CLI must not write back the remembered values.
    var clock = Date(timeIntervalSince1970: 410)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.refresh)
    controller.value.ambient = AgentAmbient(mode: "ambient", level: 2, focus: false, subtype: 0x19); controller.emit("connected")
    _ = agent.handle(.hold(false)); clock.addTimeInterval(3)
    _ = agent.handle(.setMode(mode: "nc"))
    controller.value = AgentState(connectionStatus: "connected"); controller.emit()
    guard controller.ambientWrites.isEmpty else { return false }
    controller.value.ambient = AgentAmbient(mode: "ambient", level: 7, focus: true, subtype: 0x19); controller.emit()
    if mutationTimer.isArmed { clock.addTimeInterval(0.2); mutationTimer.fire() }
    return controller.ambientWrites.count == 1
        && controller.ambientWrites.last?.mode == .noiseCancelling
        && controller.ambientWrites.last?.level == 7
        && controller.ambientWrites.last?.focusOnVoice == true
}

@MainActor func testRelativeCycleEndsWhenTheHeadsetIsAbsent() -> Bool {
    // A cycle is relative to the mode the headset is in when it is sent. If the headset is
    // absent, the cycle ends; it must not fire on some later lease, aimed at whatever mode
    // the headset happens to be in by then.
    var clock = Date(timeIntervalSince1970: 420)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), deadline = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler(), resolver = FakeResolver()
    resolver.device = PairedDeviceInfo(id: "AA:BB", name: "WH-1000XM6", isConnected: false)
    let agent = makeAgent(controller, scheduler, now: { clock }, acquisitionScheduler: deadline, deviceMutationScheduler: mutationTimer, resolver: resolver)
    agent.start(); _ = agent.handle(.cycle)
    guard agent.pendingCycleForTesting, deadline.isArmed else { return false }
    deadline.fire()
    guard agent.state.lastError == XM6ConnectAgentCore.missingHeadsetError, !agent.pendingCycleForTesting else { return false }
    resolver.device = PairedDeviceInfo(id: "AA:BB", name: "WH-1000XM6", isConnected: true)
    clock.addTimeInterval(60); scheduler.fire()
    controller.value = AgentState(connectionStatus: "connected"); controller.emit()
    controller.value.ambient = AgentAmbient(mode: "nc", level: 5, focus: false, subtype: 0x19); controller.emit()
    if mutationTimer.isArmed { clock.addTimeInterval(0.2); mutationTimer.fire() }
    return controller.ambientWrites.isEmpty
}

@MainActor
func testCycleUsesReported19SubtypeForEveryStartingMode() async -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer)
    for (current, expected) in [("nc", "ambient"), ("ambient", "off"), ("off", "nc")] {
        controller.value.ambient = AgentAmbient(mode: current, level: 8, focus: true, subtype: 0x19)
        controller.emit("connected")
        _ = agent.handle(.cycle)
        try? await Task.sleep(nanoseconds: 220_000_000)
        guard controller.ambientWrites.last?.subtype == 0x17,
              controller.ambientWrites.last?.level == 8,
              controller.ambientWrites.last?.focusOnVoice == true else { return false }
        let written = controller.ambientWrites.last?.mode
        let mode = written == .noiseCancelling ? "nc" : (written == .ambientSound ? "ambient" : "off")
        guard mode == expected else { return false }
    }
    return true
}

@MainActor func testPlaybackSwitchWaitsForTheHeadsetsList() async -> Bool {
    // A source switch is a request, not a fact: the agent keeps the headset's last list, and
    // nothing presents the request as a new report, until the headset sends one.
    let h = WireHarness()
    _ = h.agent.handle(.refresh)
    h.transport.emit(.opened)
    guard await h.pump(until: { h.agent.ownershipForTesting == .held }) else { print("    T5 never held"); return false }
    let a = "AA:BB:CC:DD:EE:FF", b = "11:22:33:44:55:66"
    var list: [UInt8] = [0x39, 0x02, 0x02]
    list += Array(a.utf8) + [0x01, 0, 0, 0, 5] + Array("Phone".utf8)
    list += Array(b.utf8) + [0x02, 0, 0, 0, 3] + Array("Mac".utf8)
    list += [0x01]
    h.send(list, type: .secondary)
    let reported = [
        AgentMultipointDevice(macAddress: a, name: "Phone", connected: true, playback: true),
        AgentMultipointDevice(macAddress: b, name: "Mac", connected: true, playback: false)
    ]
    guard await h.pump(until: { h.agent.state.multipoint == reported }) else {
        print("    T5 list never reported: \(String(describing: h.agent.state.multipoint))"); return false
    }
    let asOf = h.agent.state.stateAsOf
    var refreshed = false
    h.agent.refresh { _ in refreshed = true }
    h.clock.date.addTimeInterval(5)
    _ = h.agent.handle(.switchPlayback(macAddress: b))
    let switchFrame = SonyCommands.buildSourceSwitchSet(macAddress: b)
    let switchedThenAsked = await h.pump(until: {
        let commands = h.commands()
        guard let index = commands.lastIndex(where: { $0 == switchFrame }) else { return false }
        return commands[(index + 1)...].contains(SonyCommands.buildDeviceListGet())
    })
    guard switchedThenAsked, h.agent.state.multipoint == reported, h.agent.state.stateAsOf == asOf, !refreshed else {
        print("    T5 switchedThenAsked=\(switchedThenAsked) playing=\(h.agent.state.multipoint?.filter(\.playback).map(\.name) ?? []) stateAsOfChanged=\(h.agent.state.stateAsOf != asOf) refreshed=\(refreshed)")
        return false
    }
    return true
}

@MainActor func testSetFocusTakesModeAndLevelFromThisSessionsReport() -> Bool {
    // The phone changed mode and level while the Mac was released; a focus change must not
    // write back the remembered values.
    var clock = Date(timeIntervalSince1970: 2_100)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.refresh)
    controller.value.ambient = AgentAmbient(mode: "ambient", level: 2, focus: false, subtype: 0x19); controller.emit("connected")
    _ = agent.handle(.hold(false)); clock.addTimeInterval(3)
    _ = agent.handle(.setFocus(enabled: true))
    controller.value = AgentState(connectionStatus: "connected"); controller.emit()
    guard controller.ambientWrites.isEmpty else { print("    T7 wrote before this session's report: \(controller.ambientWrites)"); return false }
    controller.value.ambient = AgentAmbient(mode: "nc", level: 7, focus: false, subtype: 0x19); controller.emit()
    if mutationTimer.isArmed { clock.addTimeInterval(0.2); mutationTimer.fire() }
    guard controller.ambientWrites.count == 1, controller.ambientWrites.last?.mode == .noiseCancelling,
          controller.ambientWrites.last?.level == 7, controller.ambientWrites.last?.focusOnVoice == true else {
        print("    T7 writes: \(controller.ambientWrites)"); return false
    }
    return true
}

@MainActor func testModeThenFocusWhileReleasedComposeOneWrite() -> Bool {
    // Two ambient commands made while released are one intent: neither may erase the other.
    var clock = Date(timeIntervalSince1970: 2_200)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start()
    _ = agent.handle(.setMode(mode: "nc")); _ = agent.handle(.setFocus(enabled: true))
    controller.value = AgentState(connectionStatus: "connected"); controller.emit()
    guard controller.ambientWrites.isEmpty else { print("    T8 wrote before this session's report: \(controller.ambientWrites)"); return false }
    controller.value.ambient = AgentAmbient(mode: "ambient", level: 7, focus: false, subtype: 0x19); controller.emit()
    if mutationTimer.isArmed { clock.addTimeInterval(0.2); mutationTimer.fire() }
    guard controller.ambientWrites.count == 1, controller.ambientWrites.last?.mode == .noiseCancelling,
          controller.ambientWrites.last?.level == 7, controller.ambientWrites.last?.focusOnVoice == true else {
        print("    T8 writes: \(controller.ambientWrites)"); return false
    }
    return true
}

@MainActor func testCycleThenFocusWhileReleasedCompose() -> Bool {
    // A cycle and a focus change made while released compose: the cycle resolves from this
    // session's mode and the focus change survives it.
    var clock = Date(timeIntervalSince1970: 2_300)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start()
    _ = agent.handle(.cycle); _ = agent.handle(.setFocus(enabled: true))
    controller.value = AgentState(connectionStatus: "connected"); controller.emit()
    guard controller.ambientWrites.isEmpty else { print("    T9 wrote before this session's report: \(controller.ambientWrites)"); return false }
    controller.value.ambient = AgentAmbient(mode: "nc", level: 3, focus: false, subtype: 0x19); controller.emit()
    if mutationTimer.isArmed { clock.addTimeInterval(0.2); mutationTimer.fire() }
    guard controller.ambientWrites.count == 1, controller.ambientWrites.last?.mode == .ambientSound,
          controller.ambientWrites.last?.level == 3, controller.ambientWrites.last?.focusOnVoice == true else {
        print("    T9 writes: \(controller.ambientWrites)"); return false
    }
    return true
}

@MainActor func testAbsoluteAmbientThenFocusStillSendsAtConnect() async -> Bool {
    // A focus change on top of a complete ambient choice is still complete: it is the first
    // command after INIT and does not wait for an ambient report.
    let h = WireHarness()
    _ = h.agent.handle(.setAmbient(mode: "ambient", level: 8, focus: false))
    _ = h.agent.handle(.setFocus(enabled: true))
    h.transport.emit(.opened)
    _ = await h.pump(until: { !h.ambientWrites().isEmpty })
    let commands = h.commands()
    guard commands.count >= 2, commands[0] == SonyCommands.buildInit(),
          commands[1] == [0x68, 0x17, 0x01, 0x01, 0x01, 0x01, 0x08] else {
        print("    T10 commands after INIT: \(commands.dropFirst().prefix(2).map { hexBytes($0) })"); return false
    }
    return true
}

@MainActor func testSecondWriteInOneThrottleWindowResolvesFromTheFirst() -> Bool {
    // The headset's event for a write can arrive after the throttle window, so a second write
    // in that window resolves from the first write, not from the report that preceded it. A
    // different report supersedes this session's own write.
    var clock = Date(timeIntervalSince1970: 2_400)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.hold(true))
    controller.value.ambient = AgentAmbient(mode: "ambient", level: 5, focus: false, subtype: 0x19); controller.emit("connected")
    _ = agent.handle(.setMode(mode: "nc"))
    _ = agent.handle(.setFocus(enabled: true))
    let first = controller.ambientWrites.map { "\($0.mode)/\($0.level)/\($0.focusOnVoice)" }
    guard agent.ownershipForTesting == .held, first == ["noiseCancelling/5/false"], mutationTimer.isArmed else {
        print("    T11 held=\(agent.ownershipForTesting) writes before the throttle=\(first) armed=\(mutationTimer.isArmed)"); return false
    }
    mutationTimer.fire()
    controller.value.ambient = AgentAmbient(mode: "ambient", level: 9, focus: false, subtype: 0x19); controller.emit()
    clock.addTimeInterval(1)
    _ = agent.handle(.setFocus(enabled: false))
    let writes = controller.ambientWrites.map { "\($0.mode)/\($0.level)/\($0.focusOnVoice)" }
    guard writes == ["noiseCancelling/5/false", "noiseCancelling/5/true", "ambientSound/9/false"] else {
        print("    T11 writes: \(writes)"); return false
    }
    return true
}

@MainActor func testAmbientLevelUsesThisSessionsFocus() -> Bool {
    // An ambient level means Ambient at that level with the focus the headset reports in this
    // session, never the focus remembered from the persisted snapshot.
    var clock = Date(timeIntervalSince1970: 2_500)
    let persisted = AgentState(connectionStatus: "connected", ambient: AgentAmbient(mode: "nc", level: 4, focus: true, subtype: 0x19))
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = XM6ConnectAgentCore(controller: controller, resolver: FakeResolver(), scheduler: scheduler, writer: FakeStateWriter(),
        configURL: URL(fileURLWithPath: "/tmp/xm6connect-kit-tests-config-\(UUID().uuidString).json"), now: { clock },
        stateReader: FixedStateReader(state: persisted), deviceMutationScheduler: mutationTimer, stateChanged: {})
    agent.start()
    _ = agent.handle(.setAmbientLevel(level: 10))
    controller.value = AgentState(connectionStatus: "connected"); controller.emit()
    guard agent.state.ambient?.focus == true, controller.ambientWrites.isEmpty else {
        print("    T12 retained focus=\(String(describing: agent.state.ambient?.focus)) writes before this session's report: \(controller.ambientWrites)"); return false
    }
    controller.value.ambient = AgentAmbient(mode: "nc", level: 4, focus: false, subtype: 0x19); controller.emit()
    if mutationTimer.isArmed { clock.addTimeInterval(0.2); mutationTimer.fire() }
    guard controller.ambientWrites.count == 1, controller.ambientWrites.last?.mode == .ambientSound,
          controller.ambientWrites.last?.level == 10, controller.ambientWrites.last?.focusOnVoice == false else {
        print("    T12 writes: \(controller.ambientWrites)"); return false
    }
    return true
}

@MainActor func testLateEchoDoesNotUndoANewerWrite() -> Bool {
    // The headset echoes each write up to 806 ms later. An echo of an earlier write is not a
    // newer state: the next write still builds on the agent's own latest write.
    var clock = Date(timeIntervalSince1970: 2_600)
    let start = clock
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.hold(true))
    controller.value.ambient = AgentAmbient(mode: "ambient", level: 5, focus: false, subtype: 0x19); controller.emit("connected")
    _ = agent.handle(.setMode(mode: "nc"))
    _ = agent.handle(.setFocus(enabled: true))
    clock = start.addingTimeInterval(0.2); mutationTimer.fire()
    clock = start.addingTimeInterval(0.25)
    controller.value.ambient = AgentAmbient(mode: "nc", level: 5, focus: false, subtype: 0x19); controller.emit()
    clock = start.addingTimeInterval(0.3)
    _ = agent.handle(.setMode(mode: "ambient"))
    clock = start.addingTimeInterval(0.4); if mutationTimer.isArmed { mutationTimer.fire() }
    let writes = controller.ambientWrites.map { "\($0.mode)/\($0.level)/\($0.focusOnVoice)" }
    guard writes == ["noiseCancelling/5/false", "noiseCancelling/5/true", "ambientSound/5/true"] else {
        print("    late echo writes: \(writes)"); return false
    }
    return true
}

@MainActor func testThreeQuickCyclesAdvanceThreeTimes() -> Bool {
    // Three cycles 0.2 s apart are three steps, even when the first write's echo arrives
    // between the second and the third.
    var clock = Date(timeIntervalSince1970: 2_700)
    let start = clock
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.hold(true))
    controller.value.ambient = AgentAmbient(mode: "nc", level: 5, focus: false, subtype: 0x19); controller.emit("connected")
    _ = agent.handle(.cycle); if mutationTimer.isArmed { mutationTimer.fire() }
    clock = start.addingTimeInterval(0.2)
    _ = agent.handle(.cycle); if mutationTimer.isArmed { mutationTimer.fire() }
    clock = start.addingTimeInterval(0.3)
    controller.value.ambient = AgentAmbient(mode: "ambient", level: 5, focus: false, subtype: 0x19); controller.emit()
    clock = start.addingTimeInterval(0.4)
    _ = agent.handle(.cycle); if mutationTimer.isArmed { mutationTimer.fire() }
    let modes = controller.ambientWrites.map(\.mode)
    guard modes == [.ambientSound, .off, .noiseCancelling] else { print("    three cycles wrote: \(modes)"); return false }
    return true
}

@MainActor func testOwnWriteBasisEndsWithTheSession() -> Bool {
    // The agent's own write is a basis only inside the session that sent it. A link loss whose
    // forced fast retry reconnects within a second starts from the new session's report.
    var clock = Date(timeIntervalSince1970: 2_800)
    let start = clock
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, deviceMutationScheduler: mutationTimer)
    agent.start(); _ = agent.handle(.refresh)
    controller.value.ambient = AgentAmbient(mode: "ambient", level: 5, focus: false, subtype: 0x19); controller.emit("connected")
    _ = agent.handle(.setMode(mode: "nc"))
    clock = start.addingTimeInterval(0.1); controller.emit("disconnected")
    let retry = scheduler.armedDelay
    clock = start.addingTimeInterval(0.6); scheduler.fire()
    controller.value = AgentState(connectionStatus: "connected", ambient: AgentAmbient(mode: "off", level: 9, focus: true, subtype: 0x19))
    controller.emit()
    let held = agent.ownershipForTesting == .held
    clock = start.addingTimeInterval(0.7)
    _ = agent.handle(.setFocus(enabled: false))
    if mutationTimer.isArmed { clock = start.addingTimeInterval(0.9); mutationTimer.fire() }
    let writes = controller.ambientWrites.map { "\($0.mode)/\($0.level)/\($0.focusOnVoice)" }
    guard retry == 0.5, held, writes == ["noiseCancelling/5/false", "off/9/false"] else {
        print("    session boundary: retry=\(String(describing: retry)) held=\(held) writes=\(writes)"); return false
    }
    return true
}

@MainActor func testDroppedCycleKeepsTheFocusChange() -> Bool {
    // A cycle cannot outlive an absent headset, but a focus change composed with it is the
    // caller's own absolute choice and waits for the next lease like a lone focus change.
    var clock = Date(timeIntervalSince1970: 2_900)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), deadline = FakeRetryScheduler(), mutationTimer = FakeRetryScheduler(), resolver = FakeResolver()
    resolver.device = PairedDeviceInfo(id: "AA:BB", name: "WH-1000XM6", isConnected: false)
    let agent = makeAgent(controller, scheduler, now: { clock }, acquisitionScheduler: deadline, deviceMutationScheduler: mutationTimer, resolver: resolver)
    agent.start(); _ = agent.handle(.cycle); _ = agent.handle(.setFocus(enabled: true))
    let armed = deadline.isArmed
    deadline.fire()
    let absent = agent.state.lastError == XM6ConnectAgentCore.missingHeadsetError
    let cycleAfterDrop = agent.pendingCycleForTesting, pendingAfterDrop = agent.pendingActionCountForTesting
    resolver.device = PairedDeviceInfo(id: "AA:BB", name: "WH-1000XM6", isConnected: true)
    clock.addTimeInterval(60); scheduler.fire()
    controller.value = AgentState(connectionStatus: "connected"); controller.emit()
    controller.value.ambient = AgentAmbient(mode: "nc", level: 3, focus: false, subtype: 0x19); controller.emit()
    if mutationTimer.isArmed { clock.addTimeInterval(0.2); mutationTimer.fire() }
    let writes = controller.ambientWrites.map { "\($0.mode)/\($0.level)/\($0.focusOnVoice)" }
    guard armed, absent, !cycleAfterDrop, writes == ["noiseCancelling/3/true"] else {
        print("    dropped cycle: armed=\(armed) absent=\(absent) cycleAfterDrop=\(cycleAfterDrop) pendingAfterDrop=\(pendingAfterDrop) writes=\(writes)")
        return false
    }
    return true
}

@MainActor func testAcceptedPlaybackSwitchReArmsTheIdleRelease() -> Bool {
    // The headset's new list arrives after the switch. An idle release armed before an
    // accepted switch must not cut the lease in that gap.
    var clock = Date(timeIntervalSince1970: 3_000)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock })
    let playing = AgentMultipointDevice(macAddress: "AA:BB:CC:DD:EE:FF", name: "Phone", connected: true, playback: true)
    let idle = AgentMultipointDevice(macAddress: "11:22:33:44:55:66", name: "Mac", connected: true, playback: false)
    agent.start(); _ = agent.handle(.refresh)
    controller.value = AgentState(connectionStatus: "connected", multipoint: [playing, idle]); controller.emit()
    let heldWithIdleRelease = agent.ownershipForTesting == .held && scheduler.armedDelay == 20
    let armsBefore = scheduler.delays.count
    clock.addTimeInterval(19.5)
    let reply = agent.handle(.switchPlayback(macAddress: idle.macAddress))
    guard heldWithIdleRelease, reply.error == nil, controller.playbackWrites.map(\.macAddress) == [idle.macAddress],
          scheduler.delays.count == armsBefore + 1, scheduler.armedDelay == 20 else {
        print("    switch at 19.5 s: heldWithIdleRelease=\(heldWithIdleRelease) error=\(String(describing: reply.error)) re-arms=\(scheduler.delays.count - armsBefore) armedDelay=\(String(describing: scheduler.armedDelay))")
        return false
    }
    return true
}

@MainActor func testListeningModeQueuesWhileNotHeldAndSurfacesInState() -> Bool {
    // Like every other device mutation, a mode change issued while the lease is not held
    // must wait for the lease rather than be dropped, and the derived mode must reach
    // agent state so the popover and widget can render it.
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer)
    agent.start()
    _ = agent.handle(.setListeningMode(mode: "backgroundMusic"))
    guard controller.listeningModeWrites.isEmpty else { return false }
    controller.value = AgentState(connectionStatus: "connected", listeningMode: "backgroundMusic")
    controller.emit()
    return controller.listeningModeWrites == ["backgroundMusic"]
        && agent.state.listeningMode == "backgroundMusic"
}

@MainActor func testNilAmbientCycleDoesNotDiscardQueuedCommands() -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), timer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, acquisitionScheduler: timer)
    agent.start(); _ = agent.handle(.cycle); _ = agent.handle(.setSTC(true))
    controller.emit("connected")
    return controller.stcWrites == [true]
        && agent.pendingActionCountForTesting == 1
        && agent.pendingCycleForTesting
}

private final class WireTestClock { var date = Date() }

private struct FixedStateReader: StateReading {
    let state: AgentState
    func read() -> AgentState? { state }
}

/// A headset stand-in around a real bridge and agent: it answers INIT, acknowledges every command
/// frame the kit writes, answers the queries a test scripts, and yields between frames so the bridge
/// publishes each report in its own turn.
@MainActor private final class WireHarness {
    let transport: FakeConnection
    let clock: WireTestClock
    let agent: XM6ConnectAgentCore
    var replies: [[UInt8]: [UInt8]] = [:]
    private var handled = 0
    private var headsetBit: UInt8 = 0

    init(stateReader: StateReading? = nil) {
        let transport = FakeConnection(), clock = WireTestClock()
        self.transport = transport
        self.clock = clock
        agent = XM6ConnectAgentCore(
            controller: SonyControllerBridge(connection: transport),
            resolver: FakeResolver(),
            scheduler: FakeRetryScheduler(),
            writer: FakeStateWriter(),
            configURL: URL(fileURLWithPath: "/tmp/xm6connect-wire-\(UUID().uuidString).json"),
            now: { clock.date },
            stateReader: stateReader,
            acquisitionScheduler: FakeRetryScheduler(),
            deviceMutationScheduler: FakeRetryScheduler(),
            stateChanged: {}
        )
        agent.start()
    }

    func commands() -> [[UInt8]] {
        transport.writes.compactMap(SonyMessage.decode(rawFrame:)).filter { $0.type != .ack }.map(\.payload)
    }
    func ambientWrites() -> [[UInt8]] { commands().filter { $0.first == 0x68 } }

    /// Sends one headset data frame (a reply or an event).
    func send(_ payload: [UInt8], type: SonyMessageType = .primary) {
        transport.emit(.dataReceived(SonyMessage(type: type, sequenceNumber: headsetBit, payload: payload).encode()))
        headsetBit ^= 1
    }

    /// Plays the headset until `done` holds (about 3 s at most).
    func pump(until done: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            let written = transport.writes.compactMap(SonyMessage.decode(rawFrame:))
            while handled < written.count {
                let frame = written[handled]
                handled += 1
                guard frame.type != .ack else { continue }
                let ack = SonyMessage(type: .ack, sequenceNumber: frame.sequenceNumber ^ 0x01, payload: []).encode()
                if frame.payload == SonyCommands.buildInit() {
                    send([0x01, 0, 0, 0, 0, 0, 0, 0])
                    transport.emit(.dataReceived(ack))
                } else {
                    transport.emit(.dataReceived(ack))
                    if let reply = replies[frame.payload] { send(reply) }
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            if done() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return done()
    }
}

@MainActor func testWaitingModeChangeResolvesFromThe19ReplyNotTheZeros() async -> Bool {
    // A mode change made while released waits for this session's ambient report. The constant
    // 67 17 reply is not that report: level and focus come from the 67 19 reply (off, level 13).
    let h = WireHarness()
    _ = h.agent.handle(.setMode(mode: "ambient"))
    h.transport.emit(.opened)
    guard await h.pump(until: { h.agent.ownershipForTesting == .held }) else { print("    T4 never held"); return false }
    h.send([0x67, 0x17, 0x00, 0x00, 0x00, 0x00, 0x00])
    try? await Task.sleep(nanoseconds: 50_000_000)
    h.send([0x67, 0x19, 0x01, 0x00, 0x00, 0x00, 0x0d, 0x00, 0x00])
    _ = await h.pump(until: { !h.ambientWrites().isEmpty })
    let first = h.ambientWrites().first
    guard first == [0x68, 0x17, 0x01, 0x01, 0x01, 0x00, 0x0d] else { print("    T4 first 68: \(hexBytes(first))"); return false }
    return true
}

@MainActor func testSecondAmbientWriteInOneLeaseStays68_17() async -> Bool {
    // The popover case: an ambient write, the headset's 69 19 event, then a second write in the
    // same lease. The event's 19 dialect must not leak into the second write.
    let h = WireHarness()
    _ = h.agent.handle(.refresh)
    h.transport.emit(.opened)
    guard await h.pump(until: { h.commands().contains([0x36, 0x02]) }) else { print("    T5 no sweep"); return false }
    _ = h.agent.handle(.setAmbient(mode: "nc", level: 20, focus: false))
    guard await h.pump(until: { h.ambientWrites().count == 1 }),
          h.ambientWrites()[0] == [0x68, 0x17, 0x01, 0x01, 0x00, 0x00, 0x14] else {
        print("    T5 first 68: \(hexBytes(h.ambientWrites().first))"); return false
    }
    h.send([0x69, 0x19, 0x01, 0x01, 0x00, 0x00, 0x14, 0x00, 0x00])
    guard await h.pump(until: { h.agent.state.ambient?.subtype == 0x19 }) else { print("    T5 event never absorbed"); return false }
    h.clock.date.addTimeInterval(1)
    _ = h.agent.handle(.setAmbient(mode: "ambient", level: 8, focus: false))
    _ = await h.pump(until: { h.ambientWrites().count == 2 })
    let second = h.ambientWrites().dropFirst().first
    guard second == [0x68, 0x17, 0x01, 0x01, 0x01, 0x00, 0x08] else { print("    T5 second 68: \(hexBytes(second))"); return false }
    return true
}

@MainActor func testAbsoluteWriteAtConnectIgnoresPersisted19State() async -> Bool {
    // After a restart the saved report can be in the 19 dialect. The absolute write flushed at
    // connect, the first command after INIT, is still the proven 7-byte 68 17 form.
    let persisted = AgentState(connectionStatus: "connected", ambient: AgentAmbient(mode: "nc", level: 20, focus: false, subtype: 0x19))
    let h = WireHarness(stateReader: FixedStateReader(state: persisted))
    _ = h.agent.handle(.setAmbient(mode: "ambient", level: 8, focus: false))
    h.transport.emit(.opened)
    _ = await h.pump(until: { !h.ambientWrites().isEmpty })
    let commands = h.commands()
    guard commands.count >= 2, commands[0] == SonyCommands.buildInit(),
          commands[1] == [0x68, 0x17, 0x01, 0x01, 0x01, 0x00, 0x08] else {
        print("    T6 commands after INIT: \(commands.dropFirst().prefix(2).map { hexBytes($0) })"); return false
    }
    return true
}

@MainActor func testRefreshReplyCarriesThe19Report() async -> Bool {
    // A refresh completes on the first report it receives. That report must carry the headset's
    // real ambient state (the 67 19 reply), never the constant 67 17 reply.
    let h = WireHarness()
    h.replies = [
        [0x66, 0x19]: [0x67, 0x19, 0x01, 0x01, 0x00, 0x00, 0x14, 0x00, 0x00],
        [0x66, 0x17]: [0x67, 0x17, 0x00, 0x00, 0x00, 0x00, 0x00],
        [0x22, 0x00]: [0x23, 0x00, 0x3d, 0x00],
    ]
    var reply: AgentReply?
    h.agent.refresh { reply = $0 }
    h.transport.emit(.opened)
    guard await h.pump(until: { reply != nil }) else { print("    T10 no refresh completion"); return false }
    let asked19 = h.commands().contains([0x66, 0x19])
    let ambient = reply?.state.ambient
    guard asked19, reply?.stale == false, ambient?.mode == "nc", ambient?.level == 20,
          h.agent.state.ambient?.mode == "nc" else {
        print("    T10 asked66_19=\(asked19) stale=\(String(describing: reply?.stale)) ambient=\(String(describing: ambient))")
        return false
    }
    return true
}
