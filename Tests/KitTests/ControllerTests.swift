import Foundation
import Darwin
import SonyHeadphonesKit
import XM6ConnectAgentCore

@MainActor func testConstant67_17ReplyIsNotAnAmbientReport() -> Bool {
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.handleEventForKitTests(.opened)
    controller.apply(.protocolInfo(.v2))
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x67, 0x17, 0, 0, 0, 0, 0]).encode()))
    if controller.ambientSound != nil {
        print("  diagnostic testConstant67_17ReplyIsNotAnAmbientReport observed \(String(describing: controller.ambientSound))")
        return false
    }
    return true
}

@MainActor func testAmbient19Byte2ZeroIsAccepted() -> Bool {
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.handleEventForKitTests(.opened)
    controller.apply(.protocolInfo(.v2))
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x69, 0x19, 0, 1, 0, 0, 0x14, 0, 0]).encode()))
    guard controller.ambientSound?.mode == .noiseCancelling, controller.ambientSound?.level == 20 else {
        print("  diagnostic testAmbient19Byte2ZeroIsAccepted observed \(String(describing: controller.ambientSound))")
        return false
    }
    return true
}

@MainActor func testConstant17ReplyNeverOverwritesALive19Report() async -> Bool {
    let transport = FakeConnection(), bridge = SonyControllerBridge(connection: transport)
    transport.emit(.opened)
    transport.emit(.dataReceived(SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x67, 0x19, 1, 1, 1, 1, 13, 0, 0]).encode()))
    try? await Task.sleep(nanoseconds: 20_000_000)
    transport.emit(.dataReceived(SonyMessage(type: .primary, sequenceNumber: 1, payload: [0x67, 0x17, 0, 0, 0, 0, 0]).encode()))
    try? await Task.sleep(nanoseconds: 20_000_000)
    let ambient = bridge.snapshot(address: nil).ambient
    guard ambient?.mode == "ambient", ambient?.level == 13, ambient?.focus == true else {
        print("  diagnostic testConstant17ReplyNeverOverwritesALive19Report observed \(String(describing: ambient))")
        return false
    }
    return true
}

@MainActor
func testAmbientReportIsStoredWithoutUnsolicitedSetWrite() -> Bool {
    let transport = FakeConnection()
    let controller = HeadphonesController(connection: transport)
    let reported = AmbientSoundState(mode: .off, focusOnVoice: false, level: 0, subtype: 0x17)
    controller.apply(.ambientSound(reported))
    return controller.ambientSound == reported && transport.writes.isEmpty
}

@MainActor
func testStaleAndDuplicateAcknowledgementsAreIgnoredAndCorrectBitAdvancesQueue() -> Bool {
    let transport = FakeConnection()
    let controller = HeadphonesController(connection: transport)
    controller.sendRaw([0xa1])
    controller.sendRaw([0xa2])
    controller.sendRaw([0xa3])
    guard transport.writes.count == 1 else { return false }

    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 0, payload: []).encode()))
    guard transport.writes.count == 1 else { return false }

    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
    guard transport.writes.count == 2,
          SonyMessage.decode(rawFrame: transport.writes[1])?.sequenceNumber == 1 else {
        return false
    }

    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
    guard transport.writes.count == 2 else { return false }

    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 0, payload: []).encode()))
    guard transport.writes.count == 3,
          SonyMessage.decode(rawFrame: transport.writes[2])?.sequenceNumber == 0 else {
        return false
    }

    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
    guard transport.writes.count == 3 else { return false }

    // The queue is empty and the current sequence bit is 1. An idle ACK carrying 0
    // must be ignored; the old guard accepted it and corrupted the next command's bit.
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 0, payload: []).encode()))
    guard transport.writes.count == 3 else { return false }
    controller.sendRaw([0xa4])
    return transport.writes.count == 4
        && SonyMessage.decode(rawFrame: transport.writes[3])?.sequenceNumber == 1
}

@MainActor
func testAckTimeoutRetriesSameFrameTwiceThenFailsWithoutAdvancingQueue() -> Bool {
    let transport = FakeConnection()
    let controller = HeadphonesController(connection: transport)
    controller.sendRaw([0xa1])
    controller.sendRaw([0xa2])
    guard let firstFrame = transport.writes.first else { return false }

    controller.triggerAckTimeoutForTesting()
    controller.triggerAckTimeoutForTesting()
    controller.triggerAckTimeoutForTesting()

    return transport.writes == [firstFrame, firstFrame, firstFrame]
        && controller.connectionState == .failed("Command acknowledgement timed out.")
        && controller.lastError == "Command acknowledgement timed out."
}

func testDelayedOpenIsRejectedWhenGenerationChanged() -> Bool {
    var opened: [UInt64] = []
    for (delayed, current): (UInt64, UInt64) in [(7, 8), (8, 8), (9, 10)] {
        RFCOMMConnection.emitDelayedOpenIfCurrent(delayedGeneration: delayed, currentGeneration: current) { opened.append(delayed) }
    }
    return opened == [8]
}

func testChannelOpenRetryUsesAttemptGenerationInsteadOfDeviceIdentity() -> Bool {
    // The same IOBluetoothDevice instance can represent two attempts for one address.
    // Only the attempt token distinguishes a retry left over from the first attempt.
    !RFCOMMConnection.isCurrentAttempt(delayedGeneration: 11, currentGeneration: 12)
        && RFCOMMConnection.isCurrentAttempt(delayedGeneration: 12, currentGeneration: 12)
}

@MainActor func testDisconnectInvalidatesCapturedChannelOpenRetry() async -> Bool {
    // No device or channel is installed, so this exercises only the generation fence.
    let connection = RFCOMMConnection()
    let captured = connection.connectionGenerationForTesting
    connection.disconnect()
    // disconnect serializes its teardown through the main queue so it is safe when
    // called from a transport callback. Let that one queued turn run without asking
    // IOBluetooth to open or close anything on this channel-free instance.
    try? await Task.sleep(nanoseconds: 20_000_000)
    let current = connection.connectionGenerationForTesting
    return current == captured &+ 1
        && !RFCOMMConnection.isCurrentAttempt(
            delayedGeneration: captured,
            currentGeneration: current
        )
}

@MainActor func testProtocolInfoDefersTheFullStateSweepToRefresh() -> Bool {
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.handleEventForKitTests(.opened)
    transport.clearWrites()
    controller.apply(.protocolInfo(.v2))
    // A retransmitted INIT reply is not a new session and must be inert.
    controller.apply(.protocolInfo(.v2))
    guard controller.connectionState == .connected, transport.writes.isEmpty else { return false }
    // The protocol reply and the INIT ACK arrive independently. Clear the in-flight
    // INIT before asking the outbound FIFO to start the consumer-requested sweep.
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))

    controller.refreshState()
    var acknowledged = 0
    while acknowledged < transport.writes.count {
        guard let message = SonyMessage.decode(rawFrame: transport.writes[acknowledged]) else { return false }
        controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: message.sequenceNumber ^ 0x01, payload: []).encode()))
        acknowledged += 1
    }
    let payloads = transport.writes.compactMap { SonyMessage.decode(rawFrame: $0)?.payload }
    let expected: [[UInt8]] = [
        SonyCommands.buildAmbientSoundGet(subtype: 0x19),
        SonyCommands.buildBatteryGet(),
        SonyCommands.buildSpeakToChatEnabledGet(),
        SonyCommands.buildSpeakToChatConfigGet(),
        SonyCommands.buildAutomaticPowerOffGet(),
        SonyCommands.buildPauseWhenTakenOffGet(),
        SonyCommands.buildBGMModeGet(subtype: 0x09),
        SonyCommands.buildUpmixCinemaGet(),
        SonyCommands.buildEqualizerGet(subtype: 0x04),
        SonyCommands.buildEqualizerGet(subtype: 0x00),
        SonyCommands.buildDeviceListGet()
    ]
    if payloads != expected || Set(payloads).count != expected.count || payloads.contains([0x66, 0x15]) || payloads.contains([0x66, 0x17])
        || payloads.contains([0xe6, 0x03]) {
        let observed = payloads.map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") }.joined(separator: " | ")
        print("  diagnostic testProtocolInfoDefersTheFullStateSweepToRefresh observed \(observed)")
        return false
    }
    return true
}

@MainActor func testLateProtocolInfoCannotReviveFailedHandshake() -> Bool {
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.handleEventForKitTests(.opened)
    controller.handleEventForKitTests(.failed("INIT write failed"))
    controller.apply(.protocolInfo(.v2))
    return controller.connectionState == .failed("INIT write failed")
        && controller.lastError == "INIT write failed"
        && controller.protocolVersion == .unknown
}

@MainActor func testQueuedCommandIsFirstAfterInitThroughRealBridge() async -> Bool {
    let transport = FakeConnection(), bridge = SonyControllerBridge(connection: transport)
    let scheduler = FakeRetryScheduler(), deadline = FakeRetryScheduler()
    let agent = XM6ConnectAgentCore(
        controller: bridge,
        resolver: FakeResolver(),
        scheduler: scheduler,
        writer: FakeStateWriter(),
        configURL: URL(fileURLWithPath: "/tmp/xm6connect-bridge-order-\(UUID().uuidString).json"),
        acquisitionScheduler: deadline,
        stateChanged: {}
    )
    agent.start()
    _ = agent.handle(.setSTC(true))
    transport.emit(.opened)
    for _ in 0..<20 {
        if SonyMessage.decode(rawFrame: transport.writes.first ?? [])?.payload == SonyCommands.buildInit() { break }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    guard SonyMessage.decode(rawFrame: transport.writes.first ?? [])?.payload == SonyCommands.buildInit() else { return false }
    transport.clearWrites()

    // A v2 RET followed by the ACK for our INIT completes the actual kit handshake.
    transport.emit(.dataReceived(SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x01, 0, 0, 0, 0, 0, 0, 0]).encode()))
    transport.emit(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
    for _ in 0..<40 {
        let outboundCommands = transport.writes.compactMap(SonyMessage.decode(rawFrame:)).filter { $0.type == .primary }
        if !outboundCommands.isEmpty {
            return outboundCommands.first?.payload == SonyCommands.buildSpeakToChatEnabledSet(true)
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@MainActor func testBridgeCoalescesOneKitFailureIntoOneAgentCallback() async -> Bool {
    let transport = FakeConnection(), bridge = SonyControllerBridge(connection: transport)
    var callbacks = 0
    bridge.onStateChanged = { callbacks += 1 }
    // One .failed event writes both lastError and connectionState in the real kit.
    transport.emit(.failed("transport failed"))
    try? await Task.sleep(nanoseconds: 20_000_000)
    return callbacks == 1
}

@MainActor func testBridgeFailureAdvancesFastRetryOnlyOnceOutsideFence() async -> Bool {
    let transport = FakeConnection(), bridge = SonyControllerBridge(connection: transport)
    let scheduler = FakeRetryScheduler()
    let agent = XM6ConnectAgentCore(
        controller: bridge,
        resolver: FakeResolver(),
        scheduler: scheduler,
        writer: FakeStateWriter(),
        configURL: URL(fileURLWithPath: "/tmp/xm6connect-bridge-failure-\(UUID().uuidString).json"),
        stateChanged: {}
    )
    agent.start()
    _ = agent.handle(.refresh)
    transport.emit(.failed("transport failed"))
    try? await Task.sleep(nanoseconds: 20_000_000)
    // The real kit emits two objectWillChange signals for this one failure. A single
    // bridge callback leaves the first 0.5-second rung armed, not the 1-second rung.
    return scheduler.armedDelay == 0.5 && agent.yieldStepForTesting == 0
}

@MainActor func testDeadChannelStopsInitAndAcknowledgementTimers() async -> Bool {
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport, ackTimeoutNanoseconds: 1_000_000)
    controller.handleEventForKitTests(.opened)
    guard transport.writes.count == 1 else { return false }
    controller.handleEventForKitTests(.closed)
    // Drive the deterministic seam too. It must reject a dead handshake immediately.
    controller.stepHandshakeResendForTesting()
    controller.stepHandshakeResendForTesting()
    try? await Task.sleep(nanoseconds: 1_350_000_000)
    guard transport.writes.count == 1, controller.connectionState == .disconnected else { return false }

    let ackTransport = FakeConnection(), ackController = HeadphonesController(connection: ackTransport, ackTimeoutNanoseconds: 1_000_000)
    ackController.sendRaw([0xa1])
    ackController.handleEventForKitTests(.failed("channel closed"))
    try? await Task.sleep(nanoseconds: 10_000_000)
    return ackTransport.writes.count == 1
}

@MainActor func testOutgoingQueueIsBoundedUnderFlood() -> Bool {
    let transport = FakeConnection(); let controller = HeadphonesController(connection: transport)
    for value in 0..<10_000 { controller.sendRaw([UInt8(value & 0xff)]) }
    return controller.outgoingQueueDepthForTesting <= HeadphonesController.maximumOutgoingQueueDepth
        && controller.droppedOutgoingCommandCount > 0
}

@MainActor func testHandshakeKeepsResendingAnUnansweredInit() -> Bool {
    // Live: on a fresh link the first two INITs can go unanswered and only the third is
    // answered only after several seconds. With no ACK, each resend
    // repeats the identical frame.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.handleEventForKitTests(.opened)
    guard transport.writes.count == 1,
          SonyMessage.decode(rawFrame: transport.writes[0])?.payload == SonyCommands.buildInit() else { return false }
    controller.stepHandshakeResendForTesting()
    controller.stepHandshakeResendForTesting()
    return transport.writes.count == 3 && transport.writes.allSatisfy { $0 == transport.writes[0] }
}

@MainActor func testHandshakeResendAfterAnAckUsesTheNextSequenceBit() -> Bool {
    // The INIT was ACKed but its separate reply never came: the resend is a new INIT on the
    // sequence bit the ACK supplied.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.handleEventForKitTests(.opened)
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
    controller.stepHandshakeResendForTesting()
    let inits = transport.writes.compactMap(SonyMessage.decode(rawFrame:)).filter { $0.payload == SonyCommands.buildInit() }
    return inits.count == 2 && inits[0].sequenceNumber == 0 && inits[1].sequenceNumber == 1
}

@MainActor func testHandshakeDoesNotResendOnceTheReplyArrived() -> Bool {
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.handleEventForKitTests(.opened)
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x01, 0, 0, 0, 0, 0, 0, 0]).encode()))
    guard controller.connectionState == .connected else { return false }
    controller.stepHandshakeResendForTesting()
    let inits = transport.writes.compactMap(SonyMessage.decode(rawFrame:)).filter { $0.payload == SonyCommands.buildInit() }
    return inits.count == 1
}

@MainActor func testQueuedCommandFlushesWhenTheInitReplyFollowsItsAck() -> Bool {
    // A command queued while the INIT is in flight waits for the handshake. The headset may
    // ACK the INIT before sending its separate reply: the command still waits, and goes out
    // once that reply completes the handshake.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    func sent() -> Bool {
        transport.writes.compactMap(SonyMessage.decode(rawFrame:)).contains { $0.payload == SonyCommands.buildSpeakToChatEnabledSet(true) }
    }
    controller.handleEventForKitTests(.opened)
    controller.sendSpeakToChatSetWithoutLocalState(true)
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
    guard !sent() else { return false }
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x01, 0, 0, 0, 0, 0, 0, 0]).encode()))
    guard controller.connectionState == .connected else { return false }
    return sent()
}

@MainActor func testKitEqualizerWritesUseTheWritableSubtype() -> Bool {
    // The XM6 ignores equalizer writes on the read-only 0x00 dialect; the kit writes 0x04.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.sendEqualizerPresetSetWithoutLocalState(code: 0x31)
    return SonyMessage.decode(rawFrame: transport.writes.first ?? [])?.payload == [0x58, 0x04, 0x31, 0x00]
}

@MainActor func testLateReplyLeavesTheResentInitOutstandingUntilItsAck() -> Bool {
    // The first INIT was ACKed, its reply came late, and a second INIT went out on bit 1 first.
    // The reply completes the handshake, but that second INIT is still unacknowledged. Stop-and-
    // wait holds the next command until its ACK; sent earlier on bit 1, the command would take
    // that ACK as its own and could be dropped by the headset as a repeat of the INIT.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    let speakToChat = SonyCommands.buildSpeakToChatEnabledSet(true)
    func sent() -> [SonyMessage] { transport.writes.compactMap(SonyMessage.decode(rawFrame:)).filter { $0.payload == speakToChat } }
    controller.handleEventForKitTests(.opened)
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
    controller.stepHandshakeResendForTesting()
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x01, 0, 0, 0, 0, 0, 0, 0]).encode()))
    guard controller.connectionState == .connected else { return false }
    controller.sendSpeakToChatSetWithoutLocalState(true)
    guard sent().isEmpty else { return false }
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 0, payload: []).encode()))
    return sent().map(\.sequenceNumber) == [0]
}

@MainActor func testAnInitStillUnacknowledgedAfterItsReplyFailsVisibly() async -> Bool {
    // The reply came before any ACK. Once connected, the INIT is an outstanding frame like any
    // other: with no ACK it is resent identically at most twice, then the session fails visibly
    // instead of holding every later command forever.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport, ackTimeoutNanoseconds: 1_000_000)
    controller.handleEventForKitTests(.opened)
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x01, 0, 0, 0, 0, 0, 0, 0]).encode()))
    guard controller.connectionState == .connected else { return false }
    controller.sendSpeakToChatSetWithoutLocalState(true)
    try? await Task.sleep(nanoseconds: 200_000_000)
    let frames = transport.writes.compactMap(SonyMessage.decode(rawFrame:))
    let inits = frames.filter { $0.payload == SonyCommands.buildInit() }
    return controller.connectionState == .failed("Command acknowledgement timed out.")
        && inits.count == 3 && inits.allSatisfy { $0.sequenceNumber == 0 }
        && !frames.contains { $0.payload == SonyCommands.buildSpeakToChatEnabledSet(true) }
}

@MainActor func testNothingIsWrittenAfterAFailureOrADisconnect() -> Bool {
    // After a failure or our own disconnect, an inbound frame is not acknowledged: the
    // channel may be gone, and a write into it would report a second, spurious failure.
    let event = SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x25, 0x00, 0x32, 0x00]).encode()
    for end in 0..<2 {
        let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
        controller.handleEventForKitTests(.opened)
        controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
        controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x01, 0, 0, 0, 0, 0, 0, 0]).encode()))
        if end == 0 { controller.handleEventForKitTests(.failed("write failed")) } else { controller.disconnect() }
        transport.clearWrites()
        controller.handleEventForKitTests(.dataReceived(event))
        guard transport.writes.isEmpty else { return false }
    }
    return true
}

@MainActor func testHandshakeInitsNeverArmTheAcknowledgementFailureTimer() async -> Bool {
    // The agent owns the handshake verdict. Even with a 1 ms ACK timeout, neither the first INIT
    // nor a new INIT after an ACK may move the kit to a failure while it is initializing.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport, ackTimeoutNanoseconds: 1_000_000)
    controller.handleEventForKitTests(.opened)
    try? await Task.sleep(nanoseconds: 50_000_000)
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
    controller.stepHandshakeResendForTesting()
    try? await Task.sleep(nanoseconds: 50_000_000)
    return controller.connectionState == .initializing && controller.lastError == nil
}

@MainActor func testUnansweredInitIsResentByItsOwnTimer() async -> Bool {
    // With no seam call the policy resends by itself, early enough to reach a headset that stays
    // silent for the first 1.7 s of a fresh link and still answer inside the 5 s window.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.handleEventForKitTests(.opened)
    for _ in 0..<50 where transport.writes.count < 2 { try? await Task.sleep(nanoseconds: 50_000_000) }
    return transport.writes.count >= 2 && transport.writes[1] == transport.writes[0]
}

@MainActor func testAnAckedInitWaitsOutTheReplyGapBeforeANewInit() async -> Bool {
    // An INIT's separate reply can follow its ACK by up to 0.81 s, so no new INIT goes out within
    // that gap. If the reply never comes, a new INIT follows on the bit the ACK supplied.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    func inits() -> [SonyMessage] {
        transport.writes.compactMap(SonyMessage.decode(rawFrame:)).filter { $0.payload == SonyCommands.buildInit() }
    }
    controller.handleEventForKitTests(.opened)
    try? await Task.sleep(nanoseconds: 500_000_000)
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
    try? await Task.sleep(nanoseconds: 810_000_000)
    guard inits().count == 1 else { return false }
    for _ in 0..<60 where inits().count < 2 { try? await Task.sleep(nanoseconds: 50_000_000) }
    let sent = inits()
    return sent.count == 2 && sent[1].sequenceNumber == 1
}

@MainActor func testCommandsWaitForTheChannelAndTheHandshake() -> Bool {
    // The first frame of a session is INIT. A command issued while the channel is still opening
    // is held, not written into a channel that does not exist yet, and goes out after the
    // handshake like any command queued during it.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    let speakToChat = SonyCommands.buildSpeakToChatEnabledSet(true)
    controller.connect(toAddress: "AA:BB:CC:DD:EE:FF", name: "WH-1000XM6")
    guard controller.connectionState == .connecting else { return false }
    controller.sendSpeakToChatSetWithoutLocalState(true)
    guard transport.writes.isEmpty else { return false }
    controller.handleEventForKitTests(.opened)
    guard transport.writes.count == 1,
          SonyMessage.decode(rawFrame: transport.writes[0])?.payload == SonyCommands.buildInit() else { return false }
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x01, 0, 0, 0, 0, 0, 0, 0]).encode()))
    return transport.writes.compactMap(SonyMessage.decode(rawFrame:)).contains { $0.payload == speakToChat }
}

@MainActor func testAnAckTimerFromBeforeTheHandshakeCannotFailIt() async -> Bool {
    // A frame written before the channel opened left an ACK timer running. Once the handshake
    // starts, no ACK timer may move the kit to a failure while it is initializing.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport, ackTimeoutNanoseconds: 1_000_000)
    controller.sendRaw([0xa1])
    controller.handleEventForKitTests(.opened)
    guard controller.connectionState == .initializing else { return false }
    try? await Task.sleep(nanoseconds: 50_000_000)
    return controller.connectionState == .initializing && controller.lastError == nil
}

@MainActor func testTheAckTimeoutSeamCannotFailTheHandshake() -> Bool {
    // The same rule through the public ACK-timeout seam: while initializing, firing the ACK
    // timeout never reaches the generic failure.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.handleEventForKitTests(.opened)
    for _ in 0..<3 { controller.triggerAckTimeoutForTesting() }
    if case .failed = controller.connectionState { return false }
    return controller.lastError == nil
}

@MainActor func testASecondOpenedInALiveSessionIsIgnored() -> Bool {
    // A session opens once. A further .opened while initializing or connected neither restarts
    // the handshake (which would also restart its 5 s window) nor writes another INIT.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.handleEventForKitTests(.opened)
    controller.handleEventForKitTests(.opened)
    guard controller.connectionState == .initializing, transport.writes.count == 1 else { return false }
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x01, 0, 0, 0, 0, 0, 0, 0]).encode()))
    guard controller.connectionState == .connected else { return false }
    transport.clearWrites()
    controller.handleEventForKitTests(.opened)
    return controller.connectionState == .connected && transport.writes.isEmpty
}

@MainActor func testAClosedFromThePreviousSessionCannotEndTheNewAttempt() async -> Bool {
    // The transport reported .closed for the old channel before connect() was called, but the
    // kit handles transport events one main-actor hop later. That stale .closed must not end
    // the new attempt, whose channel then opens normally.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.connect(toAddress: "AA:BB:CC:DD:EE:FF", name: "WH-1000XM6")
    controller.handleEventForKitTests(.opened)
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
    controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x01, 0, 0, 0, 0, 0, 0, 0]).encode()))
    guard controller.connectionState == .connected else { return false }
    transport.emit(.closed)
    controller.connect(toAddress: "AA:BB:CC:DD:EE:FF", name: "WH-1000XM6")
    guard controller.connectionState == .connecting else { return false }
    try? await Task.sleep(nanoseconds: 20_000_000)
    transport.clearWrites()
    transport.emit(.opened)
    try? await Task.sleep(nanoseconds: 20_000_000)
    return controller.connectionState == .initializing && transport.writes.count == 1
}

@MainActor func testNoOpenedRevivesAnEndedSession() -> Bool {
    // Once the channel closed, failed or we disconnected, nothing more is written in that
    // session (rule 2.4.4). Only a new connect() starts another; a stray .opened does not.
    for end in 0..<3 {
        let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
        controller.handleEventForKitTests(.opened)
        controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
        controller.handleEventForKitTests(.dataReceived(SonyMessage(type: .primary, sequenceNumber: 0, payload: [0x01, 0, 0, 0, 0, 0, 0, 0]).encode()))
        guard controller.connectionState == .connected else { return false }
        switch end {
        case 0: controller.handleEventForKitTests(.closed)
        case 1: controller.handleEventForKitTests(.failed("write failed"))
        default: controller.disconnect()
        }
        let ended = controller.connectionState
        transport.clearWrites()
        controller.handleEventForKitTests(.opened)
        guard transport.writes.isEmpty, controller.connectionState == ended else { return false }
    }
    return true
}

@MainActor func testKitEqualizerBandWritesUseTheWritableSubtype() -> Bool {
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.sendEqualizerBandsSetWithoutLocalState(Array(repeating: 1, count: 10))
    return SonyMessage.decode(rawFrame: transport.writes.first ?? [])?.payload[1] == 0x04
}

func testProtocolLogDefersDirectoryAndRFCOMMLengthBound() -> Bool {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-log-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let log = ProtocolLog(baseURL: base)
    guard let url = log.logURLForTesting, !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { return false }
    ProtocolLog(baseURL: base, enabled: { true }).log("tx", [1])
    return FileManager.default.fileExists(atPath: url.path)
        && RFCOMMConnection.acceptsWriteLength(Int(UInt16.max))
        && !RFCOMMConnection.acceptsWriteLength(Int(UInt16.max) + 1)
}

func testProtocolLogIsPrivate() -> Bool {
    func mode(_ url: URL) -> String {
        var info = stat()
        return stat(url.path, &info) == 0 ? String(info.st_mode & 0o777, radix: 8) : "missing"
    }
    func size(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1 }
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-private-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let fresh = ProtocolLog(baseURL: root.appendingPathComponent("fresh"), enabled: { true })
    guard let freshURL = fresh.logURLForTesting else { print("    L1: fresh log has no URL"); return false }
    fresh.log("tx", [1])
    guard mode(freshURL) == "600" else { print("    L1: new log file mode was \(mode(freshURL)), want 600"); return false }

    let existing = ProtocolLog(baseURL: root.appendingPathComponent("existing"), enabled: { true })
    guard let existingURL = existing.logURLForTesting else { print("    L1: existing log has no URL"); return false }
    try? FileManager.default.createDirectory(at: existingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let old = Data("old line\n".utf8)
    guard FileManager.default.createFile(atPath: existingURL.path, contents: old, attributes: [.posixPermissions: 0o644]),
          mode(existingURL) == "644" else { print("    L1: could not create a 644 log, mode \(mode(existingURL))"); return false }
    existing.log("tx", [2])
    guard mode(existingURL) == "600" else { print("    L1: existing log mode after one line was \(mode(existingURL)), want 600"); return false }
    let appended = (try? Data(contentsOf: existingURL)) ?? Data()
    guard appended.starts(with: old), String(decoding: appended.dropFirst(old.count), as: UTF8.self).hasSuffix(" tx 02\n") else {
        print("    L1: existing log lost its old bytes or the new line: \(String(decoding: appended, as: UTF8.self).debugDescription)"); return false
    }

    let rotating = ProtocolLog(baseURL: root.appendingPathComponent("rotating"), enabled: { true })
    guard let rotatingURL = rotating.logURLForTesting else { print("    L1: rotating log has no URL"); return false }
    try? FileManager.default.createDirectory(at: rotatingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: rotatingURL.path, contents: Data(repeating: 0x41, count: 2_000_001), attributes: [.posixPermissions: 0o644]) else {
        print("    L1: could not pre-fill the rotating log"); return false
    }
    rotating.log("tx", [3])
    guard mode(rotatingURL) == "600", size(rotatingURL) >= 0, size(rotatingURL) < 2_000_000 else {
        print("    L1: after rotation mode \(mode(rotatingURL)), size \(size(rotatingURL)); want 600 and under 2 MB"); return false
    }
    return true
}

func testProtocolLogSwitchAppliesAtOnce() -> Bool {
    func size(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1 }
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-switch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    var on = false
    let log = ProtocolLog(baseURL: base, enabled: { on })
    guard let url = log.logURLForTesting else { print("    L2: log has no URL"); return false }
    log.startSession(deviceName: "test"); log.log("tx", [1])
    guard !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path), !FileManager.default.fileExists(atPath: url.path) else {
        print("    L2: a disabled log created its directory or file"); return false
    }
    on = true; log.log("tx", [2])
    let first = size(url)
    guard first > 0 else { print("    L2: switching on did not write a line (size \(first))"); return false }
    on = false; log.log("tx", [3]); log.log("tx", [4]); log.log("tx", [5])
    guard size(url) == first else { print("    L2: switching off left the log growing: \(first) -> \(size(url))"); return false }
    on = true; log.log("tx", [6])
    guard size(url) > first else { print("    L2: switching on again appended nothing (size \(size(url)))"); return false }
    return true
}

@MainActor func testBridgePublishesListeningModeFromARealDeviceFrame() async -> Bool {
    // Closes a mutation survivor: an earlier test fed the FAKE controller's snapshot
    // directly, so deleting the bridge's mapping broke nothing. This drives the real
    // codec, decoder, controller and bridge with bytes captured off the headset on
    // (RET audio param, inquired type 0x04, value 0x00 = Cinema enabled;
    // the wire encoding is inverted, 0x00 = on).
    let transport = FakeConnection()
    let bridge = SonyControllerBridge(connection: transport)
    let cinemaEnabled: [UInt8] = [0x3e, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x03, 0xe7, 0x04, 0x00, 0xfa, 0x3c]
    transport.emit(.dataReceived(cinemaEnabled))
    // The transport hands inbound events to a Task { @MainActor }, so yield before asserting.
    for _ in 0..<40 {
        if bridge.snapshot(address: nil).listeningMode == "cinema" { return true }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return false
}

@MainActor func testKitDerivesListeningModeFromBothFlags() -> Bool {
    // The device reports BGM and Upmix Cinema as two independent flags; the tri-state the
    // UI shows is derived from them, and that derivation had zero coverage. Wire-confirmed
    // shapes: RX e7 09 01 01 (BGM disabled, room 0x01) and RX e7 04 00 (Cinema enabled).
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.apply(.upmixCinema(true))
    guard controller.listeningMode == .cinema else { return false }
    // BGM outranks cinema while both are set.
    controller.apply(.bgmMode(enabled: true, roomSize: .middle))
    guard controller.listeningMode == .backgroundMusic else { return false }
    controller.apply(.bgmMode(enabled: false, roomSize: .middle))
    guard controller.listeningMode == .cinema else { return false }
    controller.apply(.upmixCinema(false))
    return controller.listeningMode == .standard
}

@MainActor func testListeningModeWithoutLocalStateWaitsForDeviceReport() -> Bool {
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.apply(.bgmMode(enabled: false, roomSize: .middle))
    controller.apply(.upmixCinema(false))
    guard controller.listeningMode == .standard, controller.bgmRoomSize == .middle else { return false }
    controller.sendListeningModeSetWithoutLocalState(.cinema)
    // Sending must not turn an unconfirmed request into a published state change.
    guard controller.listeningMode == .standard, controller.bgmRoomSize == .middle else { return false }
    controller.apply(.upmixCinema(true))
    return controller.listeningMode == .cinema
}

@MainActor func testRoomSizeSetPreservesTheReportedBGMFlag() -> Bool {
    // Prevents hardcoding `enabled:
    // true` in sendBGMRoomSizeSetWithoutLocalState broke no test, yet it would let a room
    // size change switch the headset INTO Background Music. The frame must carry the BGM
    // flag the device last reported. Wire shape: e8 09 <enabled> <roomSize>, inverted so
    // 0x00 = enabled.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.apply(.bgmMode(enabled: false, roomSize: .middle))
    transport.clearWrites()
    controller.sendBGMRoomSizeSetWithoutLocalState(.large)
    guard let frame = transport.writes.last else { return false }
    // Payload sits after the 7-byte header (0x3e, type, seq, 4-byte big-endian length).
    guard frame.count >= 11 else { return false }
    let payload = Array(frame[7..<11])
    return payload[0] == 0xe8 && payload[1] == 0x09 && payload[2] == 0x01 && payload[3] == 0x02
}

@MainActor func testColdBGMWritesWaitForThisSessionsReport() -> Bool {
    let roomTransport = FakeConnection(), roomController = HeadphonesController(connection: roomTransport)
    roomController.sendBGMRoomSizeSetWithoutLocalState(.small)
    guard roomTransport.writes.isEmpty else { return false }
    roomController.apply(.bgmMode(enabled: true, roomSize: .large))
    guard let roomFrame = roomTransport.writes.first,
          SonyMessage.decode(rawFrame: roomFrame)?.payload == [0xe8, 0x09, 0x00, 0x00] else { return false }

    let modeTransport = FakeConnection(), modeController = HeadphonesController(connection: modeTransport)
    modeController.sendListeningModeSetWithoutLocalState(.cinema)
    guard modeTransport.writes.isEmpty else { return false }
    modeController.apply(.bgmMode(enabled: false, roomSize: .large))
    guard let bgmFrame = modeTransport.writes.first,
          SonyMessage.decode(rawFrame: bgmFrame)?.payload == [0xe8, 0x09, 0x01, 0x02] else { return false }
    modeController.handleEventForKitTests(.dataReceived(SonyMessage(type: .ack, sequenceNumber: 1, payload: []).encode()))
    guard let cinemaFrame = modeTransport.writes.last else { return false }
    return SonyMessage.decode(rawFrame: cinemaFrame)?.payload == [0xe8, 0x04, 0x00]
}

func testRFCOMMOpenSettleIsAdaptive() -> Bool {
    // A reused ACL must notify the controller immediately. A newly-established ACL
    // retains a short safety settle for the observed first-write drop after wake.
    RFCOMMConnection.openSettleDelay(linkWasAlreadyEstablished: true) == 0
        && RFCOMMConnection.openSettleDelay(linkWasAlreadyEstablished: false) == 0.15
}

@MainActor func testBridgeSurfacesALingeringHandshakePhase() async -> Bool {
    // A healthy 1.2 s acquisition can go
    // connecting -> connected with no "initializing" ever visible, because the bridge
    // defers each @Published change by one run-loop turn and two fast transitions
    // collapse into a single read of the latest value. That is harmless when the
    // handshake completes — but the handshake deadline exists for the case where it
    // does NOT, and if a lingering .initializing were invisible too, armHandshakeDeadline
    // would never run in production and the whole phase policy would be dead code.
    // This drives the REAL bridge and controller through a fake transport.
    let transport = FakeConnection()
    let bridge = SonyControllerBridge(connection: transport)
    var seen: [String] = []
    bridge.onStateChanged = { MainActor.assumeIsolated { seen.append(bridge.snapshot(address: nil).connectionStatus) } }
    transport.emit(.opened)   // channel open, and nothing answers the handshake
    for _ in 0..<60 {
        if seen.contains("initializing") { return true }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return false
}

@MainActor func testKitNeverDeclaresTheAcquisitionFailedItself() -> Bool {
    // The agent owns the verdict. The kit may resend INIT, but it must never declare
    // .failed itself: that would pre-empt the agent's handshake deadline. The agent also
    // routes such a transition into the handshake policy; that routing is a safety net,
    // not a substitute for this kit-side rule.
    let transport = FakeConnection(), controller = HeadphonesController(connection: transport)
    controller.handleEventForKitTests(.opened)
    // Repeated resend steps with no protocolInfo reply must not end in a failure verdict.
    for _ in 0..<4 { controller.stepHandshakeResendForTesting() }
    if case .failed = controller.connectionState { return false }
    return controller.lastError == nil
}
