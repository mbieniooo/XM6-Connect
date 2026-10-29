import Foundation
import SonyHeadphonesKit
import XM6ConnectAgentCore
import XM6ConnectAppLogic

func testACLBouncePolicyNeverBouncesDisconnectedAndRespectsRateCap() -> Bool {
    !ACLBounceRecoveryPolicy.mayBounce(alreadyBouncedThisEpisode: true, timeSinceLastBounce: 999)
        && !ACLBounceRecoveryPolicy.mayBounce(alreadyBouncedThisEpisode: false, timeSinceLastBounce: 59.999)
        && ACLBounceRecoveryPolicy.mayBounce(alreadyBouncedThisEpisode: false, timeSinceLastBounce: ACLBounceRecoveryPolicy.minimumBounceInterval)
}

@MainActor
func testAgentInvokesACLBounceSeamAtPolicyThreshold() -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    var clock = Date(timeIntervalSince1970: 1_000)
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start(); _ = agent.handle(.hold(true)); controller.emit("connected")
    _ = agent.handle(.hold(false)); clock.addTimeInterval(3); _ = agent.handle(.hold(true))
    controller.pendingTransportFailure = RFCOMMConnectionFailureContext(kind: .controlRefused, isConnected: true)
    controller.emit("failed")
    // The historical dead-end ended here with no scheduled reconnect.  A bounce now
    // always leaves a 3-second continuation armed.
    return controller.aclBounceCalls == 1 && scheduler.delays.last == 3 && agent.timerArmedForTesting
}

@MainActor func testUserCommandBreaksAYieldInsteadOfBeingDropped() -> Bool {
    // `xm6ctl playback` returned success with no error
    // while the agent was yielded, and nothing reached the headset. Any command the user
    // issues must take the channel back, not be silently swallowed.
    var clock = Date(timeIntervalSince1970: 1_500)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let acquisitionTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, writer, now: { clock }, acquisitionScheduler: acquisitionTimer)
    agent.start()
    _ = agent.handle(.refresh)
    clock.addTimeInterval(XM6ConnectAgentCore.openTimeout + 1)
    acquisitionTimer.fire()
    guard agent.ownershipForTesting == .yielded else { return false }
    // A user-issued device command arrives during the suppression window.
    _ = agent.handle(.setAmbient(mode: "nc", level: 12, focus: false))
    return agent.ownershipForTesting != .yielded && agent.state.connectionStatus != "yielded"
}

@MainActor func testExplicitReconnectOverridesAYield() -> Bool {
    // When the agent is yielded, `xm6ctl reconnect` (the same path as
    // the popover's Reconnect button) left it yielded — the user had no way back.
    var clock = Date(timeIntervalSince1970: 900)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let acquisitionTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, writer, now: { clock }, acquisitionScheduler: acquisitionTimer)
    agent.start()
    _ = agent.handle(.refresh)
    clock.addTimeInterval(XM6ConnectAgentCore.openTimeout + 1)
    acquisitionTimer.fire()
    guard agent.ownershipForTesting == .yielded else { return false }
    // The human asked directly: clear the suppression window, then still let the
    // just-started transport teardown finish before reconnecting.
    _ = agent.handle(.reconnect)
    guard agent.ownershipForTesting == .released,
          scheduler.armedDelay == 2,
          agent.lastCommandForTesting == clock else { return false }
    clock.addTimeInterval(2)
    scheduler.fire()
    return agent.ownershipForTesting == .acquiring && controller.connects.count == 2
}

@MainActor func testFenceTerminalDuringNewAcquisitionArmsRecovery() -> Bool {
    var clock = Date(timeIntervalSince1970: 950)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start(); _ = agent.handle(.refresh)
    controller.value = AgentState(connectionStatus: "connected")
    controller.emit()
    _ = agent.handle(.hold(false)) // establishes the teardown fence
    clock.addTimeInterval(0.5)
    _ = agent.handle(.setSTC(true))
    guard scheduler.armedDelay == 1.5 else { return false }
    clock.addTimeInterval(1.5)
    scheduler.fire()                // begins a new acquisition inside that fence
    guard agent.ownershipForTesting == .acquiring else { return false }
    controller.emit("failed")
    return agent.state.connectionStatus != "released"
        && agent.timerArmedForTesting
        && scheduler.armedDelay == 0.5
}

@MainActor func testYieldThenCommandHonorsTheTwoSecondReleaseGap() -> Bool {
    var clock = Date(timeIntervalSince1970: 975)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start(); _ = agent.handle(.yield(seconds: 60))
    clock.addTimeInterval(0.5)
    _ = agent.handle(.setSTC(true))
    guard controller.connects.isEmpty, scheduler.armedDelay == 1.5 else { return false }
    clock.addTimeInterval(1.5)
    scheduler.fire()
    return controller.connects.count == 1 && agent.ownershipForTesting == .acquiring
}

@MainActor func testIPCReconnectForcesAStuckAcquisition() -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter(), deadline = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, writer, acquisitionScheduler: deadline)
    agent.start(); _ = agent.handle(.refresh)
    guard controller.connects.count == 1, agent.ownershipForTesting == .acquiring else { return false }
    // A callback writes the status away from connecting, then the now-inapplicable
    // deadline fires. This reproduces the real wedge: acquiring, no phase deadline,
    // no retry, and no handshake-bounce recovery.
    controller.emit("released")
    deadline.fire()
    guard !agent.timerArmedForTesting, !agent.acquisitionDeadlineArmedForTesting else { return false }
    _ = agent.handle(.reconnect)
    return controller.connects.count == 2
        && agent.ownershipForTesting == .acquiring
        && agent.acquisitionDeadlineArmedForTesting
}

@MainActor func testCancelledAcquisitionDeadlineNoLongerReadsArmed() -> Bool {
    // Reconnect treats an armed acquisition deadline as a live way out. A deadline that
    // was cancelled rather than fired must stop reading as armed, or a later genuine
    // wedge could never be forced.
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), deadline = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, acquisitionScheduler: deadline)
    agent.start(); _ = agent.handle(.refresh)
    guard controller.connects.count == 1, agent.acquisitionDeadlineArmedForTesting else { return false }
    agent.setAsleep(true)
    return agent.ownershipForTesting == .released && !agent.acquisitionDeadlineArmedForTesting
}

@MainActor func testIPCReconnectLeavesHealthyAcquisitionDeadlineAlone() -> Bool {
    var clock = Date(timeIntervalSince1970: 1_000)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter(), deadline = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, writer, now: { clock }, acquisitionScheduler: deadline)
    agent.start(); _ = agent.handle(.refresh)
    guard controller.connects.count == 1,
          deadline.armedDelay == XM6ConnectAgentCore.openTimeout,
          agent.acquisitionDeadlineArmedForTesting else { return false }
    clock.addTimeInterval(1) // A healthy, already-running attempt must keep its clock.
    _ = agent.handle(.reconnect)
    return controller.connects.count == 1
        && deadline.armedDelay == XM6ConnectAgentCore.openTimeout
        && agent.acquisitionDeadlineArmedForTesting
}

@MainActor func testIPCReconnectLeavesHandshakeBounceRecoveryAlone() -> Bool {
    var clock = Date(timeIntervalSince1970: 1_025)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), deadline = FakeRetryScheduler(), resolver = FakeResolver()
    let agent = makeAgent(controller, scheduler, now: { clock }, acquisitionScheduler: deadline, resolver: resolver)
    agent.start(); _ = agent.handle(.refresh); controller.emit("initializing"); deadline.fire()
    guard controller.aclBounceCalls == 1, scheduler.armedDelay == 3 else { return false }
    // The bounce is taking the link down. The deferred retry must keep its special
    // retryingHandshake semantics instead of treating this as an absent headset.
    resolver.device = PairedDeviceInfo(id: "AA:BB", name: "WH-1000XM6", isConnected: false)
    clock.addTimeInterval(0.4); _ = agent.handle(.reconnect)
    guard controller.connects.count == 1, scheduler.armedDelay == 3 else { return false }
    clock.addTimeInterval(2.6); scheduler.fire()
    guard controller.connects.count == 2,
          deadline.armedDelay == XM6ConnectAgentCore.openTimeout else { return false }
    deadline.fire()
    return agent.ownershipForTesting == .yielded
        && agent.state.lastError != XM6ConnectAgentCore.missingHeadsetError
}

@MainActor func testStrayUnlockDuringHandshakeBounceKeepsTheReacquire() -> Bool {
    var clock = Date(timeIntervalSince1970: 1_060)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), deadline = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, acquisitionScheduler: deadline)
    agent.start(); _ = agent.handle(.refresh); controller.emit("initializing"); deadline.fire()
    guard controller.aclBounceCalls == 1, scheduler.armedDelay == 3 else { return false }
    // An unlock with no matching lock (the agent started while the screen was locked)
    // must not replace the bounce's only way back with a five-minute peek.
    clock.addTimeInterval(0.4); agent.setScreenLocked(false)
    guard scheduler.armedDelay == 3 else { return false }
    clock.addTimeInterval(2.6); scheduler.fire()
    return controller.connects.count == 2
}

@MainActor func testIPCReconnectLeavesStaleSessionBounceRecoveryAlone() -> Bool {
    var clock = Date(timeIntervalSince1970: 1_040)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter(), deadline = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, writer, now: { clock }, acquisitionScheduler: deadline)
    agent.start(); _ = agent.handle(.refresh); controller.emit("connected")
    _ = agent.handle(.hold(false)); clock.addTimeInterval(0.5); _ = agent.handle(.setSTC(true))
    clock.addTimeInterval(1.5); scheduler.fire()
    guard controller.connects.count == 2 else { return false }
    controller.pendingTransportFailure = RFCOMMConnectionFailureContext(kind: .controlRefused, isConnected: true)
    controller.emit("failed")
    guard controller.aclBounceCalls == 1, scheduler.armedDelay == 3 else { return false }
    clock.addTimeInterval(0.4); _ = agent.handle(.reconnect)
    guard controller.connects.count == 2, scheduler.armedDelay == 3 else { return false }
    clock.addTimeInterval(2.6); scheduler.fire()
    return controller.connects.count == 3
        && deadline.armedDelay == XM6ConnectAgentCore.openTimeout
}

@MainActor func testSeparateDuplicateTerminalReportsAdvanceOneFastRetryRung() -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter(), deadline = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, writer, acquisitionScheduler: deadline)
    agent.start(); _ = agent.handle(.refresh)
    controller.emit("failed")
    guard scheduler.armedDelay == 0.5 else { return false }
    // This is a later callback turn, not bridge coalescing of one turn's writes.
    controller.emit("failed")
    return scheduler.delays.suffix(1) == [0.5]
        && scheduler.armedDelay == 0.5
        && agent.ownershipForTesting == .acquiring
}

@MainActor func testDuplicateTerminalInsideFenceKeepsStaleSessionBounceArmed() -> Bool {
    var clock = Date(timeIntervalSince1970: 1_050)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start(); _ = agent.handle(.refresh); controller.emit("connected")
    _ = agent.handle(.hold(false))
    clock.addTimeInterval(0.5)
    _ = agent.handle(.setSTC(true))
    clock.addTimeInterval(1.5)
    scheduler.fire()
    guard controller.connects.count == 2, agent.ownershipForTesting == .acquiring else { return false }

    controller.pendingTransportFailure = RFCOMMConnectionFailureContext(kind: .controlRefused, isConnected: true)
    controller.emit("failed")
    // The duplicate has no new failure context, just as a second deferred bridge read
    // would not. It must not replace the caller-owned three-second reacquisition.
    controller.emit("failed")
    return controller.aclBounceCalls == 1
        && scheduler.armedDelay == 3
        && controller.connects.count == 2
}

@MainActor func testForeignHolderYieldNeverBecomesOurStaleSession() -> Bool {
    var clock = Date(timeIntervalSince1970: 1_100)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start(); _ = agent.handle(.refresh)
    controller.pendingTransportFailure = RFCOMMConnectionFailureContext(kind: .controlRefused, isConnected: true)
    controller.emit("failed")
    guard agent.ownershipForTesting == .yielded, controller.aclBounceCalls == 0 else { return false }

    clock.addTimeInterval(5)
    _ = agent.handle(.setSTC(true))
    guard controller.connects.count == 2, agent.ownershipForTesting == .acquiring else { return false }
    controller.pendingTransportFailure = RFCOMMConnectionFailureContext(kind: .controlRefused, isConnected: true)
    controller.emit("failed")
    return controller.aclBounceCalls == 0 && agent.ownershipForTesting == .yielded
}

@MainActor func testIPCReconnectHonorsTeardownGapAfterIdleRelease() -> Bool {
    var clock = Date(timeIntervalSince1970: 1_150)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let agent = makeAgent(controller, scheduler, writer, now: { clock })
    agent.start(); _ = agent.handle(.refresh); controller.emit("connected")
    scheduler.fire() // the held lease's 20-second idle-release timer
    guard agent.ownershipForTesting == .released, controller.disconnects == 1 else { return false }

    clock.addTimeInterval(0.4)
    _ = agent.handle(.reconnect)
    guard controller.connects.count == 1,
          abs((scheduler.armedDelay ?? 0) - 1.6) < 0.001,
          agent.lastCommandForTesting == clock else { return false }
    clock.addTimeInterval(1.6)
    scheduler.fire()
    return controller.connects.count == 2 && agent.ownershipForTesting == .acquiring
}

@MainActor func testStalledAcquisitionYieldsInsteadOfHangingForever() -> Bool {
    // When another controller holds the session the device never
    // completes our open and never errors. With no timeout the agent stayed
    // "connecting" forever and silently dropped every command.
    var clock = Date(timeIntervalSince1970: 500)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), writer = FakeStateWriter()
    let acquisitionTimer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, writer, now: { clock }, acquisitionScheduler: acquisitionTimer)
    agent.start()
    _ = agent.handle(.refresh)
    guard agent.state.connectionStatus == "connecting", acquisitionTimer.delays == [XM6ConnectAgentCore.openTimeout] else { return false }
    // The transport reports nothing at all — the hang case.
    clock.addTimeInterval(XM6ConnectAgentCore.openTimeout + 1)
    acquisitionTimer.fire()
    return agent.state.connectionStatus != "connecting"
        && agent.ownershipForTesting == .yielded
}

@MainActor private func makeAbsentHeadsetAgent(
    _ controller: FakeAgentController,
    _ scheduler: FakeRetryScheduler,
    _ acquisitionTimer: FakeRetryScheduler,
    _ resolver: FakeResolver,
    now: @escaping () -> Date
) -> XM6ConnectAgentCore {
    resolver.device = PairedDeviceInfo(id: "AA:BB", name: "WH-1000XM6", isConnected: false)
    return makeAgent(controller, scheduler, now: now,
                     acquisitionScheduler: acquisitionTimer, resolver: resolver)
}

@MainActor func testStalledAcquisitionWithNoBluetoothLinkReportsMissingHeadset() -> Bool {
    // When the XM6 is in Bluetooth's "Not Connected" list, commands are
    // accepted, the agent reported only "released" with no error, and the stall was
    // treated as another controller holding the session. The user had no way to learn
    // that the headset simply was not there.
    var clock = Date(timeIntervalSince1970: 2_000)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), acquisitionTimer = FakeRetryScheduler()
    let agent = makeAbsentHeadsetAgent(controller, scheduler, acquisitionTimer, FakeResolver(), now: { clock })
    agent.start()
    _ = agent.handle(.refresh)
    guard agent.state.connectionStatus == "connecting" else { return false }
    clock.addTimeInterval(XM6ConnectAgentCore.openTimeout + 1)
    acquisitionTimer.fire()
    return agent.ownershipForTesting == .unavailable
        && agent.state.connectionStatus == "failed"
        && agent.state.lastError == XM6ConnectAgentCore.missingHeadsetError
        && scheduler.delays.last == XM6ConnectAgentCore.unavailableRetry
}

@MainActor func testMissingHeadsetDoesNotAdvanceTheYieldLadder() -> Bool {
    // An absent headset is not contention. If it climbed the ladder, the agent would
    // ignore the headset for up to ten minutes after the user put it back on.
    var clock = Date(timeIntervalSince1970: 3_000)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), acquisitionTimer = FakeRetryScheduler()
    let resolver = FakeResolver()
    let agent = makeAbsentHeadsetAgent(controller, scheduler, acquisitionTimer, resolver, now: { clock })
    agent.start()
    _ = agent.handle(.refresh)
    clock.addTimeInterval(XM6ConnectAgentCore.openTimeout + 1)
    acquisitionTimer.fire()
    guard agent.ownershipForTesting == .unavailable else { return false }
    // The headset comes back, and this time a real holder stalls the acquisition: the
    // ladder must still start at its first step.
    resolver.device = PairedDeviceInfo(id: "AA:BB", name: "WH-1000XM6", isConnected: true)
    clock.addTimeInterval(XM6ConnectAgentCore.unavailableRetry)
    scheduler.fire()
    guard agent.state.connectionStatus == "connecting" else { return false }
    clock.addTimeInterval(XM6ConnectAgentCore.openTimeout + 1)
    acquisitionTimer.fire()
    guard agent.ownershipForTesting == .yielded else { return false }
    return scheduler.delays.last == 60
}

@MainActor func testTeardownFencePreservesTheMissingHeadsetDiagnosis() -> Bool {
    // The disconnect issued alongside the diagnosis comes back as a transport report.
    // Inside the teardown fence that report must not overwrite the reason with a
    // resting state, or the user sees "released" again and learns nothing.
    var clock = Date(timeIntervalSince1970: 4_000)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), acquisitionTimer = FakeRetryScheduler()
    let agent = makeAbsentHeadsetAgent(controller, scheduler, acquisitionTimer, FakeResolver(), now: { clock })
    agent.start()
    _ = agent.handle(.refresh)
    clock.addTimeInterval(XM6ConnectAgentCore.openTimeout + 1)
    acquisitionTimer.fire()
    guard agent.state.connectionStatus == "failed" else { return false }
    controller.value = AgentState(connectionStatus: "disconnected")
    controller.emit()
    return agent.state.connectionStatus == "failed"
        && agent.state.lastError == XM6ConnectAgentCore.missingHeadsetError
}

@MainActor func testHandshakeClockIsArmedOncePerPhaseEntry() -> Bool {
    // Dropping the
    // `previousStatus != "initializing"` guard re-arms the 5 s clock on EVERY controller
    // report while initializing. A headset that keeps sending frames but never answers
    // the handshake would then refresh the deadline forever and hold the one control
    // session indefinitely — the unbounded hang this whole design exists to prevent.
    let clock = Date(timeIntervalSince1970: 72_000)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), timer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, acquisitionScheduler: timer)
    agent.start(); _ = agent.handle(.refresh)
    controller.emit("initializing")
    let afterBoundary = timer.delays.count
    guard timer.armedDelay == XM6ConnectAgentCore.handshakeTimeout else { return false }
    // More traffic arrives, still mid-handshake: published values change, no protocolInfo.
    controller.value.battery = AgentBattery(level: 70, charging: false); controller.emit()
    controller.value.battery = AgentBattery(level: 69, charging: false); controller.emit()
    controller.emit()
    // The clock must not have been re-armed by any of them.
    return timer.delays.count == afterBoundary && timer.armedDelay == XM6ConnectAgentCore.handshakeTimeout
}

@MainActor func testOpenPhaseDeadlineUsesOneValueAndNeverBounces() -> Bool {
    guard XM6ConnectAgentCore.openTimeout == 6, XM6ConnectAgentCore.handshakeTimeout == 5 else { return false }
    let clock = Date(timeIntervalSince1970: 60_000)
    let linkedController = FakeAgentController(), linkedScheduler = FakeRetryScheduler(), linkedTimer = FakeRetryScheduler()
    let linked = makeAgent(linkedController, linkedScheduler, now: { clock }, acquisitionScheduler: linkedTimer)
    linked.start(); _ = linked.handle(.refresh)
    guard linkedTimer.armedDelay == XM6ConnectAgentCore.openTimeout else { return false }
    linkedTimer.fire()
    guard linked.ownershipForTesting == .yielded,
          linkedController.aclBounceCalls == 0,
          linkedScheduler.armedDelay == 60 else { return false }

    let absentController = FakeAgentController(), absentScheduler = FakeRetryScheduler(), absentTimer = FakeRetryScheduler()
    let absent = makeAbsentHeadsetAgent(absentController, absentScheduler, absentTimer, FakeResolver(), now: { clock })
    absent.start(); _ = absent.handle(.refresh)
    guard absentTimer.armedDelay == XM6ConnectAgentCore.openTimeout else { return false }
    absentTimer.fire()
    return absent.ownershipForTesting == .unavailable
        && absent.state.connectionStatus == "failed"
        && absent.state.lastError == XM6ConnectAgentCore.missingHeadsetError
        && absentScheduler.armedDelay == XM6ConnectAgentCore.unavailableRetry
        && absent.yieldStepForTesting == 0
        && absentController.aclBounceCalls == 0
}

@MainActor func testEarlyKitHandshakeVerdictUsesHandshakePolicy() -> Bool {
    // A kit that publishes failed while the agent is in its handshake phase, before the
    // agent's own deadline, must never send the agent into the generic 0.5/1/2 ladder.
    var clock = Date(timeIntervalSince1970: 61_000)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), timer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, acquisitionScheduler: timer)
    agent.start(); _ = agent.handle(.refresh); controller.emit("initializing")
    guard timer.armedDelay == XM6ConnectAgentCore.handshakeTimeout else { return false }
    clock.addTimeInterval(4); controller.emit("failed")
    return controller.aclBounceCalls == 1
        && controller.connects.count == 1
        && scheduler.armedDelay == 3
        && agent.yieldStepForTesting == 0
}

@MainActor func testHandshakeBounceRetriesOnceAndStandsDownHonestly() -> Bool {
    let clock = Date(timeIntervalSince1970: 62_000)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), timer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, now: { clock }, acquisitionScheduler: timer)
    agent.start(); _ = agent.handle(.refresh); controller.emit("initializing")
    timer.fire()
    guard controller.aclBounceCalls == 1, scheduler.armedDelay == 3, !timer.isArmed else { return false }

    // The bounce closes our own RFCOMM channel. Its teardown must not replace the
    // scheduled retry with generic recovery or yield to the phone.
    controller.pendingTransportFailure = RFCOMMConnectionFailureContext(kind: .controlRefused, isConnected: true)
    controller.emit("disconnected")
    guard scheduler.armedDelay == 3, agent.ownershipForTesting == .acquiring,
          agent.yieldStepForTesting == 0 else { return false }

    scheduler.fire()
    guard controller.connects.count == 2, timer.armedDelay == XM6ConnectAgentCore.openTimeout else { return false }
    controller.emit("initializing")
    guard timer.armedDelay == XM6ConnectAgentCore.handshakeTimeout else { return false }
    timer.fire()
    guard controller.aclBounceCalls == 1,
          agent.ownershipForTesting == .released,
          agent.state.connectionStatus == "failed",
          agent.state.lastError == XM6ConnectAgentCore.handshakeTimeoutError,
          scheduler.armedDelay == XM6ConnectAgentCore.unavailableRetry,
          agent.yieldStepForTesting == 0,
          !agent.bouncedThisEpisodeForTesting else { return false }
    let view = PopoverModel.map(AppState(connectionStatus: agent.state.connectionStatus, lastError: agent.state.lastError))
    guard case .disconnected(let message) = view.connection else { return false }
    return message == XM6ConnectAgentCore.handshakeTimeoutError
}

@MainActor func testPostBounceRetryDoesNotMisdiagnoseOurOwnACLTeardown() -> Bool {
    let clock = Date(timeIntervalSince1970: 62_500)
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), timer = FakeRetryScheduler(), resolver = FakeResolver()
    let agent = makeAgent(controller, scheduler, now: { clock }, acquisitionScheduler: timer, resolver: resolver)
    agent.start(); _ = agent.handle(.refresh); controller.emit("initializing"); timer.fire()
    // Our bounce closes the ACL, so a fresh resolve legitimately says “not connected”.
    // That must not turn the retry into the absent-headset path.
    resolver.device = PairedDeviceInfo(id: "AA:BB", name: "WH-1000XM6", isConnected: false)
    scheduler.fire()
    guard timer.armedDelay == XM6ConnectAgentCore.openTimeout else { return false }
    timer.fire()
    return agent.ownershipForTesting == .yielded
        && agent.state.lastError != XM6ConnectAgentCore.missingHeadsetError
}

@MainActor func testHandshakeLeaseCanEndForSleepAndHoldOff() -> Bool {
    let clock = Date(timeIntervalSince1970: 63_000)
    let sleepController = FakeAgentController(), sleepScheduler = FakeRetryScheduler(), sleepTimer = FakeRetryScheduler()
    let sleeping = makeAgent(sleepController, sleepScheduler, now: { clock }, acquisitionScheduler: sleepTimer)
    sleeping.start(); _ = sleeping.handle(.refresh); sleepController.emit("initializing")
    guard sleepTimer.armedDelay == XM6ConnectAgentCore.handshakeTimeout else { return false }
    sleeping.setAsleep(true)
    sleepTimer.fire()
    guard sleeping.ownershipForTesting == .released,
          sleeping.state.connectionStatus == "released",
          !sleepTimer.isArmed,
          sleepController.disconnects == 1 else { return false }

    let holdController = FakeAgentController(), holdScheduler = FakeRetryScheduler(), holdTimer = FakeRetryScheduler()
    let held = makeAgent(holdController, holdScheduler, now: { clock }, acquisitionScheduler: holdTimer)
    held.start(); _ = held.handle(.hold(true)); holdController.emit("initializing")
    guard held.ownershipForTesting == .acquiring else { return false }
    _ = held.handle(.hold(false))
    return held.ownershipForTesting == .released
        && held.state.connectionStatus == "released"
        && !holdTimer.isArmed
        && holdController.disconnects == 1
}

@MainActor func testCommandDuringAcquisitionQueuesWithoutRestartingDeadline() -> Bool {
    let controller = FakeAgentController(), scheduler = FakeRetryScheduler(), timer = FakeRetryScheduler()
    let agent = makeAgent(controller, scheduler, acquisitionScheduler: timer)
    agent.start(); _ = agent.handle(.refresh)
    let initialConnections = controller.connects.count
    guard timer.delays == [XM6ConnectAgentCore.openTimeout] else { return false }
    _ = agent.handle(.setSTC(true))
    guard controller.connects.count == initialConnections,
          timer.delays == [XM6ConnectAgentCore.openTimeout],
          agent.pendingActionCountForTesting == 1 else { return false }
    controller.emit("connected")
    return controller.stcWrites == [true] && controller.refreshes == 1
}
