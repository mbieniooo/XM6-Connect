import Foundation
import Combine

/// Stamps transport callbacks at the instant the transport reports them. The callback
/// may arrive on any queue, while controller state remains main-actor isolated.
private final class ConnectionAttemptTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = UInt64(0)

    func beginAttempt() {
        lock.lock()
        current &+= 1
        lock.unlock()
    }

    func snapshot() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

/// Orchestrates the connection lifecycle, the stop-and-wait sequence-number/ACK
/// handshake, and the outbound command queue for a single Sony headset, and exposes
/// the decoded device state as `@Published` properties for SwiftUI.
///
/// Sequence numbers are a single alternating bit: our commands carry the current
/// value, and an ACK from the device supplies the next one. A reply or event from the
/// device is acknowledged with the complement of that message's own sequence bit.
@MainActor
public final class HeadphonesController: ObservableObject {
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var deviceName: String?
    @Published public private(set) var protocolVersion: ProtocolVersion = .unknown

    @Published public private(set) var ambientSound: AmbientSoundState?
    @Published public private(set) var battery: BatteryStatus?
    @Published public private(set) var speakToChatEnabled: Bool?
    @Published public private(set) var speakToChatConfig: SpeakToChatConfigState?
    @Published public private(set) var automaticPowerOff: AutomaticPowerOffMode?
    @Published public private(set) var pauseWhenTakenOff: Bool?
    @Published public private(set) var equalizer: EqualizerState?
    @Published public private(set) var listeningMode: ListeningMode?
    @Published public private(set) var bgmRoomSize: BGMRoomSize?
    @Published public private(set) var devices: [MultipointDevice]?

    /// Raw BGM/cinema flags as last reported; listeningMode is derived from them.
    private var bgmEnabled = false
    private var cinemaEnabled = false
    private var hasBGMReportThisSession = false
    private var pendingBGMRoomSize: BGMRoomSize?
    private var pendingListeningMode: ListeningMode?
    @Published public private(set) var lastError: String?
    private let connection: any RFCOMMConnectionProviding
    private let frameParser = FrameParser()
    /// Frame log, switched by the `protocolLoggingEnabled` user default; the default is
    /// read on every write, so changing it takes effect without restarting the agent.
    private let protocolLog = ProtocolLog(enabled: { UserDefaults.standard.bool(forKey: "protocolLoggingEnabled") })

    private var sequenceNumber: UInt8 = 0
    private var outgoingQueue: [(SonyMessageType, [UInt8])] = []
    public static let maximumOutgoingQueueDepth = 64
    public private(set) var droppedOutgoingCommandCount = 0
    public var outgoingQueueDepthForTesting: Int { outgoingQueue.count }
    private var awaitingAck: Bool { inFlightCommand != nil }
    private struct InFlightCommand {
        let message: SonyMessage
        var expectedAckSequenceNumber: UInt8 { message.sequenceNumber ^ 0x01 }
        var retryCount: Int
    }
    private var inFlightCommand: InFlightCommand?
    private var outboundFailed = false
    private var hasEndedSession = false
    private let ackTimeoutNanoseconds: UInt64
    private var ackTimeoutTask: Task<Void, Never>?
    private var handshakeResendTask: Task<Void, Never>?
    /// Monotonic uptime prevents wall-clock corrections changing the five-second window.
    private var handshakeStartedAtUptime: UInt64?
    /// One second exceeds the 0.98 s p99 reply latency and 0.81 s ACK-to-reply gap;
    /// continuing through the fresh-link silence observed to 1.7 s yields sends at
    /// 0, 1, 2, 3, and 4 s, with no final shorter wait and every resend inside 5 s.
    private static let handshakeResendIntervalNanoseconds: UInt64 = 1_000_000_000
    private static let handshakeReplyGraceNanoseconds = handshakeResendIntervalNanoseconds
    private static let handshakeWindowNanoseconds: UInt64 = 5_000_000_000
    private var connectTarget: (address: String, name: String?)?
    private let connectionAttempt = ConnectionAttemptTracker()
    public convenience init() {
        self.init(connection: RFCOMMConnection())
    }

    /// The transport-taking initializer is internal so the package test target can use
    /// a deterministic fake without making a hardware transport part of the public API.
    // public for KitTests (CLT has no XCTest)
    public init(
        connection: any RFCOMMConnectionProviding,
        ackTimeoutNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.connection = connection
        self.ackTimeoutNanoseconds = ackTimeoutNanoseconds
        let connectionAttempt = connectionAttempt
        connection.onEvent = { [weak self, connectionAttempt] event in
            guard let self else { return }
            // Capture before the asynchronous main-actor hop: a callback from an old
            // RFCOMM attempt must not act on a later attempt.
            let reportedAttempt = connectionAttempt.snapshot()
            Task { @MainActor in
                self.handle(event, reportedForAttempt: reportedAttempt)
            }
        }
    }

    // MARK: - Public API

    public func connect(toAddress address: String, name: String?) {
        connectTarget = (address, name)
        attemptConnect()
    }

    private func attemptConnect() {
        guard let target = connectTarget else { return }
        // Tear down any live channel first; connecting on top of an open RFCOMM
        // channel leaks it and leaves two delegates fighting over one session.
        connection.disconnect()
        resetSessionState()
        hasEndedSession = false
        connectionAttempt.beginAttempt()
        deviceName = target.name
        connectionState = .connecting
        lastError = nil
        protocolLog.startSession(deviceName: target.name)
        connection.connect(toDeviceAddress: target.address)
    }

    public func disconnect() {
        ackTimeoutTask?.cancel()
        handshakeResendTask?.cancel()
        outboundFailed = true
        hasEndedSession = true
        connectTarget = nil
        connectionAttempt.beginAttempt()
        connection.disconnect()
        connectionState = .disconnected
    }

    /// Re-requests all device state (e.g. after the initial read timed out).
    public func refreshState() {
        guard connectionState == .connected else { return }
        requestFullState()
    }

    // MARK: - Raw access (developer tooling)

    /// Queues a raw payload for a test seam.
    public func sendRaw(_ payload: [UInt8], type: SonyMessageType = .primary) {
        enqueue(payload, type: type)
    }

    // public for KitTests (CLT has no XCTest)
    public func handleEventForKitTests(_ event: RFCOMMConnectionEvent) {
        handle(event, reportedForAttempt: connectionAttempt.snapshot())
    }

    // MARK: - Device-authoritative command seam
    //
    // XM6ConnectAgent persists a device-authoritative snapshot for other processes, so
    // these methods enqueue the protocol command and leave published state untouched
    // until the headset reports the change.
    public func sendAmbientSoundSetWithoutLocalState(_ state: AmbientSoundState) {
        enqueue(SonyCommands.buildAmbientSoundSet(state))
    }

    public func sendSpeakToChatSetWithoutLocalState(_ enabled: Bool) {
        enqueue(SonyCommands.buildSpeakToChatEnabledSet(enabled))
    }

    public func sendEqualizerPresetSetWithoutLocalState(code: UInt8) {
        enqueue(SonyCommands.buildEqualizerPresetSet(code: code))
    }

    public func sendEqualizerBandsSetWithoutLocalState(_ bands: [Int]) {
        enqueue(SonyCommands.buildEqualizerBandsSet(bands: bands))
    }

    /// Enqueues the two frames that form one listening-mode change without claiming
    /// that the headset accepted it.  `listeningMode` remains a device-report-only
    /// value for agent consumers.
    public func sendListeningModeSetWithoutLocalState(_ mode: ListeningMode) {
        guard hasBGMReportThisSession, let roomSize = bgmRoomSize else {
            pendingListeningMode = mode
            return
        }
        enqueueListeningMode(mode, roomSize: roomSize)
    }

    /// Same device-authoritative seam for the BGM room setting.  Preserve the last
    /// reported BGM flag instead of manufacturing a new derived listening mode.
    public func sendBGMRoomSizeSetWithoutLocalState(_ roomSize: BGMRoomSize) {
        guard hasBGMReportThisSession else {
            pendingBGMRoomSize = roomSize
            return
        }
        enqueue(SonyCommands.buildBGMModeSet(enabled: bgmEnabled, roomSize: roomSize))
    }

    /// Asks the headset to switch the active playback source to another connected device.
    /// `devices` keeps the headset's own list until the headset reports the switch.
    public func switchPlayback(to device: MultipointDevice) {
        guard let payload = SonyCommands.buildSourceSwitchSet(macAddress: device.macAddress) else { return }
        enqueue(payload, type: .secondary)
        // Read the new list with a device-list query after the switch; the headset may
        // also push an updated list on its own.
        enqueue(SonyCommands.buildDeviceListGet(), type: .secondary)
    }

    // MARK: - Connection events

    private func resetSessionState() {
        sequenceNumber = 0
        outgoingQueue.removeAll()
        inFlightCommand = nil
        outboundFailed = false
        ackTimeoutTask?.cancel()
        handshakeResendTask?.cancel()
        handshakeStartedAtUptime = nil
        frameParser.reset()
        ambientSound = nil
        battery = nil
        speakToChatEnabled = nil
        speakToChatConfig = nil
        automaticPowerOff = nil
        pauseWhenTakenOff = nil
        equalizer = nil
        listeningMode = nil
        bgmRoomSize = nil
        devices = nil
        bgmEnabled = false
        cinemaEnabled = false
        hasBGMReportThisSession = false
        pendingBGMRoomSize = nil
        pendingListeningMode = nil
        protocolVersion = .unknown
    }

    private func handle(_ event: RFCOMMConnectionEvent, reportedForAttempt: UInt64) {
        guard reportedForAttempt == connectionAttempt.snapshot() else { return }
        switch event {
        case .opened:
            guard connectionState == .connecting
                    || (connectionState == .disconnected && !hasEndedSession) else { return }
            outboundFailed = false
            connectionState = .initializing
            beginHandshake()

        case .closed:
            ackTimeoutTask?.cancel()
            handshakeResendTask?.cancel()
            outboundFailed = true
            hasEndedSession = true
            handshakeStartedAtUptime = nil
            connectionState = .disconnected

        case .dataReceived(let bytes):
            protocolLog.log("RX", bytes)
            for message in frameParser.feed(bytes) {
                handle(message: message)
            }

        case .failed(let message):
            ackTimeoutTask?.cancel()
            handshakeResendTask?.cancel()
            outboundFailed = true
            hasEndedSession = true
            handshakeStartedAtUptime = nil
            lastError = message
            connectionState = .failed(message)
        }
    }

    private func send(_ message: SonyMessage, note: String = "") {
        guard !outboundFailed else { return }
        let bytes = message.encode()
        protocolLog.log("TX", bytes, note: note)
        connection.write(bytes)
    }

    private func beginHandshake() {
        // A pre-open command may have armed the ordinary timer while disconnected.
        // Initialization owns its verdict, so that timer cannot affect this handshake.
        ackTimeoutTask?.cancel()
        handshakeResendTask?.cancel()
        handshakeStartedAtUptime = DispatchTime.now().uptimeNanoseconds
        let initMessage = SonyMessage(type: .primary, sequenceNumber: sequenceNumber, payload: SonyCommands.buildInit())
        // The agent owns the handshake deadline, so INIT never starts the generic
        // command-ACK failure timer.
        awaitAcknowledgement(for: initMessage, note: "init", startsAckTimeout: false)
        scheduleHandshakeResend(after: Self.handshakeResendIntervalNanoseconds)
    }

    private func scheduleHandshakeResend(after delay: UInt64) {
        handshakeResendTask?.cancel()
        guard let handshakeStartedAtUptime else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- handshakeStartedAtUptime
        guard elapsed < Self.handshakeWindowNanoseconds,
              delay < Self.handshakeWindowNanoseconds - elapsed else { return }
        handshakeResendTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.stepHandshakeResendForTesting()
        }
    }

    /// Performs one scheduled INIT retry. It is public so the handshake policy
    /// can be advanced without waiting for the timer in deterministic tests.
    public func stepHandshakeResendForTesting() {
        guard connectionState == .initializing,
              !outboundFailed,
              let handshakeStartedAtUptime,
              DispatchTime.now().uptimeNanoseconds &- handshakeStartedAtUptime < Self.handshakeWindowNanoseconds,
              protocolVersion == .unknown else { return }
        if awaitingAck, let inFlightCommand, inFlightCommand.message.payload == SonyCommands.buildInit() {
            // A lost ACK leaves the alternating bit unchanged, so retransmit exactly
            // the original INIT frame.
            send(inFlightCommand.message, note: "handshake resend")
        } else if !awaitingAck {
            // An ACK without its separate INIT reply advances the bit. The retry is
            // therefore a new INIT at that advanced bit.
            let initMessage = SonyMessage(type: .primary, sequenceNumber: sequenceNumber, payload: SonyCommands.buildInit())
            awaitAcknowledgement(for: initMessage, note: "handshake resend", startsAckTimeout: false)
        }

        scheduleHandshakeResend(after: Self.handshakeResendIntervalNanoseconds)
    }

    // MARK: - Message handling

    private func handle(message: SonyMessage) {
        if message.type == .ack {
            guard awaitingAck,
                  let inFlightCommand,
                  message.sequenceNumber == inFlightCommand.expectedAckSequenceNumber else { return }
            sequenceNumber = message.sequenceNumber
            self.inFlightCommand = nil
            ackTimeoutTask?.cancel()
            if connectionState == .initializing,
               inFlightCommand.message.payload == SonyCommands.buildInit() {
                // Do not immediately turn an ACK into another INIT: the independent
                // reply can arrive up to 0.81 s later.
                scheduleHandshakeResend(after: Self.handshakeReplyGraceNanoseconds)
            }
            // Queued controls wait for the INIT reply; if the ACK arrives first, the
            // resend policy retains ownership of the still-initializing handshake.
            if connectionState != .initializing {
                sendNextQueuedCommand()
            }
            return
        }

        guard !message.payload.isEmpty else { return }

        // Acknowledge with the complement of the received message's sequence bit, not
        // our own outgoing counter: with the wrong bit the headset treats its replies as
        // unacknowledged and stops answering.
        let ackSeq = message.sequenceNumber ^ 0x01
        send(SonyMessage(type: .ack, sequenceNumber: ackSeq, payload: []), note: "ack")

        guard let event = SonyEventDecoder.decode(payload: message.payload, messageType: message.type) else { return }
        apply(event)
    }

    // public for KitTests (CLT has no XCTest)
    public func apply(_ event: HeadphonesEvent) {
        switch event {
        case .protocolInfo(let version):
            // A late INIT reply must not revive a session whose outbound path already
            // failed or closed; the agent still needs to observe that terminal state.
            guard connectionState == .initializing, !outboundFailed,
                  protocolVersion == .unknown else { return }
            protocolVersion = version
            handshakeResendTask?.cancel()
            handshakeStartedAtUptime = nil
            connectionState = .connected
            if awaitingAck,
               inFlightCommand?.message.payload == SonyCommands.buildInit() {
                // A reply does not acknowledge this frame. Once the handshake phase
                // ends, give the outstanding INIT the ordinary ACK timeout policy.
                scheduleAcknowledgementTimeout()
            } else {
                sendNextQueuedCommand()
            }

        case .ambientSound(let state):
            ambientSound = state
        case .battery(let status):
            battery = status
        case .speakToChatEnabled(let enabled):
            speakToChatEnabled = enabled
        case .speakToChatConfig(let config):
            speakToChatConfig = config
        case .automaticPowerOff(let mode):
            automaticPowerOff = mode
        case .pauseWhenTakenOff(let enabled):
            pauseWhenTakenOff = enabled
        case .equalizer(let state):
            equalizer = state
        case .bgmMode(let enabled, let roomSize):
            bgmEnabled = enabled
            bgmRoomSize = roomSize
            hasBGMReportThisSession = true
            updateListeningMode()
            flushPendingBGMRequests()
        case .upmixCinema(let enabled):
            cinemaEnabled = enabled
            updateListeningMode()
        case .deviceList(let list):
            devices = list
        }
    }

    private func updateListeningMode() {
        listeningMode = bgmEnabled ? .backgroundMusic : (cinemaEnabled ? .cinema : .standard)
    }

    private func enqueueListeningMode(_ mode: ListeningMode, roomSize: BGMRoomSize) {
        enqueue(SonyCommands.buildBGMModeSet(enabled: mode == .backgroundMusic, roomSize: roomSize))
        enqueue(SonyCommands.buildUpmixCinemaSet(enabled: mode == .cinema))
    }

    private func flushPendingBGMRequests() {
        guard hasBGMReportThisSession else { return }
        if let roomSize = pendingBGMRoomSize {
            pendingBGMRoomSize = nil
            enqueue(SonyCommands.buildBGMModeSet(enabled: bgmEnabled, roomSize: roomSize))
        }
        if let mode = pendingListeningMode, let roomSize = bgmRoomSize {
            pendingListeningMode = nil
            enqueueListeningMode(mode, roomSize: roomSize)
        }
    }

    private func requestFullState() {
        // 0x15 is acknowledged without a reply and 0x17 returns a constant layout;
        // 0x19 is the only query that reports the ambient state.
        enqueue(SonyCommands.buildAmbientSoundGet(subtype: 0x19))
        enqueue(SonyCommands.buildBatteryGet())
        enqueue(SonyCommands.buildSpeakToChatEnabledGet())
        enqueue(SonyCommands.buildSpeakToChatConfigGet())
        enqueue(SonyCommands.buildAutomaticPowerOffGet())
        enqueue(SonyCommands.buildPauseWhenTakenOffGet())
        // Listening mode is reported as two independent flags (BGM and Upmix Cinema),
        // from which the kit derives Standard/Background Music/Cinema. The XM6 answers
        // BGM on inquired type 0x09 and acknowledges 0x03 without a reply.
        enqueue(SonyCommands.buildBGMModeGet(subtype: 0x09))
        enqueue(SonyCommands.buildUpmixCinemaGet())
        // XM6 answers EQ inquired type 0x04; 0x00 kept as a fallback for other firmware.
        enqueue(SonyCommands.buildEqualizerGet(subtype: 0x04))
        enqueue(SonyCommands.buildEqualizerGet(subtype: 0x00))
        enqueue(SonyCommands.buildDeviceListGet(), type: .secondary)
    }

    // MARK: - Outbound queue

    private func enqueue(_ payload: [UInt8], type: SonyMessageType = .primary) {
        if outgoingQueue.count >= Self.maximumOutgoingQueueDepth {
            outgoingQueue.removeFirst()
            droppedOutgoingCommandCount += 1
            if droppedOutgoingCommandCount == 1 {
                NSLog("XM6-Connect dropped %d queued headset commands", droppedOutgoingCommandCount)
            }
        }
        outgoingQueue.append((type, payload))
        if connectionState != .connecting && connectionState != .initializing && !awaitingAck && !outboundFailed {
            sendNextQueuedCommand()
        }
    }

    private func sendNextQueuedCommand() {
        guard connectionState != .connecting, connectionState != .initializing,
              !outboundFailed, !awaitingAck, !outgoingQueue.isEmpty else { return }
        let (type, payload) = outgoingQueue.removeFirst()
        let message = SonyMessage(type: type, sequenceNumber: sequenceNumber, payload: payload)
        awaitAcknowledgement(for: message)
    }

    private func awaitAcknowledgement(
        for message: SonyMessage,
        note: String = "",
        startsAckTimeout: Bool = true
    ) {
        inFlightCommand = InFlightCommand(
            message: message,
            retryCount: 0
        )
        send(message, note: note)

        guard startsAckTimeout else { return }
        scheduleAcknowledgementTimeout()
    }

    private func scheduleAcknowledgementTimeout() {
        ackTimeoutTask?.cancel()
        ackTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.ackTimeoutNanoseconds ?? 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.handleAckTimeout()
        }
    }

    private func handleAckTimeout() {
        // Section 2.4.3 gives the agent the handshake verdict. This applies to INIT
        // and to an ordinary ACK timer that existed before the channel opened.
        guard connectionState != .initializing,
              !outboundFailed, awaitingAck, var inFlightCommand else { return }
        guard inFlightCommand.retryCount < 2 else {
            self.inFlightCommand = nil
            outboundFailed = true
            lastError = "Command acknowledgement timed out."
            connectionState = .failed(lastError ?? "")
            return
        }
        inFlightCommand.retryCount += 1
        self.inFlightCommand = inFlightCommand
        // Retry the exact same encoded message: its sequence bit must remain stable
        // until the matching ACK arrives.
        send(inFlightCommand.message, note: "ack retry \(inFlightCommand.retryCount)")
        scheduleAcknowledgementTimeout()
    }

    /// Internal deterministic seam for the package's ACK state-machine tests.
    // public for KitTests (CLT has no XCTest)
    public func triggerAckTimeoutForTesting() {
        handleAckTimeout()
    }
}
