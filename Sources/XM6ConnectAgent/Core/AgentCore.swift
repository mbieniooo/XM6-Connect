import Combine
import Darwin
import Foundation
import os
import SonyHeadphonesKit

public struct AgentAmbient: Codable, Equatable {
    public var mode: String
    public var level: Int
    public var focus: Bool
    public var subtype: Int
    /// Optional for backward-compatible decoding of snapshots written before the
    /// 0x17 wind-noise dialect was represented in agent state.
    public var hasWindNoiseByte: Bool?
    public init(mode: String, level: Int, focus: Bool, subtype: Int, hasWindNoiseByte: Bool? = nil) { self.mode = mode; self.level = level; self.focus = focus; self.subtype = subtype; self.hasWindNoiseByte = hasWindNoiseByte }
}

public struct AgentBattery: Codable, Equatable {
    public var level: Int
    public var charging: Bool
    public init(level: Int, charging: Bool) { self.level = level; self.charging = charging }
}

public struct AgentEqualizer: Codable, Equatable {
    public var presetCode: Int
    public var bands: [Int]
    public var subtype: Int
}

public struct AgentSpeakToChatConfig: Codable, Equatable {
    public var sensitivity: Int
    public var timeout: Int
    public init(sensitivity: Int, timeout: Int) { self.sensitivity = sensitivity; self.timeout = timeout }
}

public struct AgentMultipointDevice: Codable, Equatable {
    public var macAddress: String
    public var name: String
    public var connected: Bool
    public var playback: Bool
    public init(macAddress: String, name: String, connected: Bool, playback: Bool) {
        self.macAddress = macAddress
        self.name = name
        self.connected = connected
        self.playback = playback
    }
}

/// Resolves the human-facing `xm6ctl playback` selector against a single
/// device-reported list.  It deliberately returns the report's canonical MAC instead
/// of echoing command-line input back toward the device path.
public enum PlaybackTargetResolver {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case ambiguous(String)

        public var description: String {
            switch self {
            case .unknown(let value): return "unknown playback device: \(value)"
            case .ambiguous(let value): return "ambiguous playback device name: \(value)"
            }
        }
    }

    public static func resolve(_ query: String, in devices: [AgentMultipointDevice]) -> Result<AgentMultipointDevice, Error> {
        let macMatches = devices.filter { $0.macAddress.caseInsensitiveCompare(query) == .orderedSame }
        if let match = macMatches.first { return .success(match) }
        let nameMatches = devices.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        guard nameMatches.count == 1, let match = nameMatches.first else {
            return nameMatches.isEmpty ? .failure(.unknown(query)) : .failure(.ambiguous(query))
        }
        return .success(match)
    }

    /// Keeps CLI failure behavior testable: an unknown or ambiguous target cannot
    /// invoke its request-sending closure.
    @discardableResult public static func dispatch(
        _ query: String,
        in devices: [AgentMultipointDevice],
        send: (String) -> Void
    ) -> Result<Void, Error> {
        switch resolve(query, in: devices) {
        case .success(let device): send(device.macAddress); return .success(())
        case .failure(let error): return .failure(error)
        }
    }
}

/// Resolves the `xm6ctl eq preset` argument: a kit preset label in any case, or a
/// numeric code 0...255. The names come from `EqualizerPreset.allCases`.
public enum EqualizerPresetResolver {
    public static func code(for input: String) -> Int? {
        let name = input.lowercased()
        if let preset = EqualizerPreset.allCases.first(where: { $0.label.lowercased() == name }) { return Int(preset.rawValue) }
        guard let code = Int(input), (0...255).contains(code) else { return nil }
        return code
    }
}

/// The on-disk and IPC snapshot.  Every nullable field means "not yet reported by
/// the headset", never a guessed device setting.
public struct AgentState: Codable, Equatable {
    public var connectionStatus: String
    public var deviceName: String?
    public var deviceAddress: String?
    public var ambient: AgentAmbient?
    public var battery: AgentBattery?
    public var equalizer: AgentEqualizer?
    public var speakToChat: Bool?
    public var speakToChatConfig: AgentSpeakToChatConfig?
    public var automaticPowerOff: Int?
    public var pauseOnRemove: Bool?
    public var multipoint: [AgentMultipointDevice]?
    /// Standard / backgroundMusic / cinema, derived by the kit from the BGM and
    /// Upmix Cinema flags. Nil until the device reports them.
    public var listeningMode: String?
    /// Raw `BGMRoomSize` value (0...2), nil until the device reports BGM state.
    public var bgmRoomSize: Int?
    public var lastError: String?
    /// Time the headset last supplied state, distinct from the persistence time.
    public var stateAsOf: Date?
    public var timestamp: Date

    public init(
        connectionStatus: String = "disconnected", deviceName: String? = nil,
        deviceAddress: String? = nil, ambient: AgentAmbient? = nil,
        battery: AgentBattery? = nil, equalizer: AgentEqualizer? = nil,
        speakToChat: Bool? = nil, speakToChatConfig: AgentSpeakToChatConfig? = nil, automaticPowerOff: Int? = nil,
        pauseOnRemove: Bool? = nil, multipoint: [AgentMultipointDevice]? = nil,
        listeningMode: String? = nil, bgmRoomSize: Int? = nil,
        lastError: String? = nil, stateAsOf: Date? = nil, timestamp: Date = Date()
    ) {
        self.connectionStatus = connectionStatus; self.deviceName = deviceName
        self.deviceAddress = deviceAddress; self.ambient = ambient; self.battery = battery
        self.equalizer = equalizer; self.speakToChat = speakToChat; self.speakToChatConfig = speakToChatConfig
        self.automaticPowerOff = automaticPowerOff; self.pauseOnRemove = pauseOnRemove
        self.multipoint = multipoint; self.listeningMode = listeningMode; self.bgmRoomSize = bgmRoomSize
        self.lastError = lastError; self.stateAsOf = stateAsOf; self.timestamp = timestamp
    }
}

public struct AgentReply: Codable {
    public var state: AgentState
    public var error: String?
    public var ownership: String
    public var stateAsOf: Date?
    public var stale: Bool
    public init(state: AgentState, error: String? = nil, ownership: String = "unavailable", stateAsOf: Date? = nil, stale: Bool = false) {
        self.state = state; self.error = error; self.ownership = ownership
        self.stateAsOf = stateAsOf ?? state.stateAsOf; self.stale = stale
    }
}

/// Cross-queue copy of the device-authoritative state.  The agent main actor is the
/// only writer; IPC workers take a short lock only to copy this value.  A worker waits
/// for the main queue only for a command's own reply, and only for a bounded time.
public final class AgentStateSnapshot {
    private let lock = NSLock()
    private var value: AgentState
    public init(_ initial: AgentState = AgentState()) { value = initial }
    public func store(_ state: AgentState) { lock.lock(); value = state; lock.unlock() }
    public func load() -> AgentState { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor public protocol AgentHeadphonesControlling: AnyObject {
    var onStateChanged: (() -> Void)? { get set }
    func snapshot(address: String?) -> AgentState
    func connect(address: String, name: String?)
    func disconnect()
    func refreshState()
    func sendAmbient(_ state: AmbientSoundState)
    func sendEqualizerPreset(code: UInt8)
    func sendEqualizerBands(_ bands: [Int])
    func sendSpeakToChat(_ enabled: Bool)
    func setListeningMode(_ mode: String)
    func setBGMRoomSize(_ rawValue: UInt8)
    func switchPlayback(to device: AgentMultipointDevice)
    func consumeTransportFailure() -> RFCOMMConnectionFailureContext?
    func bounceACL()
}

public extension AgentHeadphonesControlling {
    func consumeTransportFailure() -> RFCOMMConnectionFailureContext? { nil }
    func bounceACL() {}
}

/// Hardware-free ACL recovery policy.  Time is supplied as an elapsed duration so
/// callers can test every branch without changing a clock or touching Bluetooth.
public enum ACLBounceRecoveryPolicy {
    public static let minimumBounceInterval: TimeInterval = 60

    /// A handshake timeout proves that our RFCOMM channel opened, unlike an open
    /// timeout which may belong to another controller.  Keep the shared episode and
    /// interval guards here so every ACL disruption has one policy boundary.
    public static func mayBounce(
        alreadyBouncedThisEpisode: Bool,
        timeSinceLastBounce: TimeInterval
    ) -> Bool {
        !alreadyBouncedThisEpisode && timeSinceLastBounce >= minimumBounceInterval
    }
}

@MainActor public protocol AgentDeviceResolving {
    func resolve(cachedAddress: String?) -> PairedDeviceInfo?
}

@MainActor public protocol RetryScheduling: AnyObject {
    func schedule(after seconds: TimeInterval, action: @escaping () -> Void)
    func cancel()
}

public protocol StateWriting {
    func write(_ state: AgentState) throws
}

public final class AtomicStateWriter: StateWriting {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func write(_ state: AgentState) throws {
        let data = try JSONEncoder.xm6Connect.encode(state)
        try Self.writeData(data, to: url)
    }
    public static func writeData(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".state-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.write(fd, base, raw.count)
        }
        _ = close(fd)
        guard written == data.count else { try? fm.removeItem(at: temporary); throw POSIXError(.EIO) }
        guard rename(temporary.path, url.path) == 0 else {
            let error = errno; try? fm.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        _ = chmod(url.path, S_IRUSR | S_IWUSR)
    }
}

extension JSONEncoder {
    static var xm6Connect: JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var xm6Connect: JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Reads the persisted snapshot so a restart does not start blind.  Without this the
/// agent wrote a blank state over the file at launch and every surface — widget,
/// menu bar, popover — showed dashes until something happened to acquire the channel.
public protocol StateReading {
    func read() -> AgentState?
}

public struct AtomicStateReader: StateReading {
    public static let maximumStateFileBytes = 64 * 1024
    public let url: URL
    public init(url: URL) { self.url = url }
    public func read() -> AgentState? {
        // `attributesOfItem` measures the link itself while Data follows it. Resolve
        // first so a small symlink cannot turn the 64 KiB guard into an unbounded read.
        let resolvedURL = url.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumStateFileBytes,
              let handle = try? FileHandle(forReadingFrom: resolvedURL),
              let data = try? handle.read(upToCount: Self.maximumStateFileBytes + 1) else { return nil }
        try? handle.close()
        guard data.count <= Self.maximumStateFileBytes else { return nil }
        return try? JSONDecoder.xm6Connect.decode(AgentState.self, from: data)
    }
}

@MainActor public final class DispatchRetryScheduler: RetryScheduling {
    private var source: DispatchSourceTimer?
    public init() {}
    public func schedule(after seconds: TimeInterval, action: @escaping () -> Void) {
        cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in self?.source = nil; action() }
        source = timer; timer.resume()
    }
    public func cancel() { source?.setEventHandler {}; source?.cancel(); source = nil }
}

@MainActor public final class SonyControllerBridge: AgentHeadphonesControlling {
    private let controller: HeadphonesController
    private let transport: any RFCOMMConnectionProviding
    private var observation: AnyCancellable?
    /// `objectWillChange` fires before every @Published write.  Several writes can
    /// describe one transport event, so expose one deferred, live-state read per turn.
    private var stateCallbackPending = false
    public var onStateChanged: (() -> Void)?

    public init(connection: (any RFCOMMConnectionProviding)? = nil) {
        let transport = connection ?? RFCOMMConnection()
        self.transport = transport
        controller = HeadphonesController(connection: transport)
        observation = controller.objectWillChange.sink { [weak self] _ in
            // ObservableObject emits before mutation.  Deferring one main-loop turn
            // captures the new value. Coalescing keeps one kit transition from
            // advancing agent recovery more than once.
            guard let self, !self.stateCallbackPending else { return }
            self.stateCallbackPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stateCallbackPending = false
                self.onStateChanged?()
            }
        }
    }
    public func connect(address: String, name: String?) { controller.connect(toAddress: address, name: name) }
    public func disconnect() { controller.disconnect() }
    public func refreshState() { controller.refreshState() }
    public func sendAmbient(_ state: AmbientSoundState) { controller.sendAmbientSoundSetWithoutLocalState(state) }
    public func sendEqualizerPreset(code: UInt8) { controller.sendEqualizerPresetSetWithoutLocalState(code: code) }
    public func sendEqualizerBands(_ bands: [Int]) { controller.sendEqualizerBandsSetWithoutLocalState(bands) }
    public func sendSpeakToChat(_ enabled: Bool) { controller.sendSpeakToChatSetWithoutLocalState(enabled) }
    public func setListeningMode(_ mode: String) {
        guard let value = ListeningMode(rawValue: mode) else { return }
        controller.sendListeningModeSetWithoutLocalState(value)
    }
    public func setBGMRoomSize(_ rawValue: UInt8) {
        guard let roomSize = BGMRoomSize(rawValue: rawValue) else { return }
        controller.sendBGMRoomSizeSetWithoutLocalState(roomSize)
    }
    public func switchPlayback(to device: AgentMultipointDevice) {
        controller.switchPlayback(to: MultipointDevice(
            macAddress: device.macAddress,
            name: device.name,
            connectedStatus: device.connected ? 1 : 0,
            isPlayback: device.playback
        ))
    }
    public func consumeTransportFailure() -> RFCOMMConnectionFailureContext? { transport.consumeFailureContext() }
    public func bounceACL() { transport.bounceACL() }

    public func snapshot(address: String?) -> AgentState {
        let status: String
        switch controller.connectionState {
        case .disconnected: status = "disconnected"
        case .connecting: status = "connecting"; case .initializing: status = "initializing"
        case .connected: status = "connected"; case .failed: status = "failed"
        }
        let ambient = controller.ambientSound.map { AgentAmbient(mode: $0.mode == .noiseCancelling ? "nc" : ($0.mode == .ambientSound ? "ambient" : "off"), level: $0.level, focus: $0.focusOnVoice, subtype: Int($0.subtype), hasWindNoiseByte: $0.hasWindNoiseByte) }
        let battery = controller.battery.map { AgentBattery(level: $0.level, charging: $0.isCharging) }
        let eq = controller.equalizer.map { AgentEqualizer(presetCode: Int($0.presetCode), bands: $0.bands, subtype: Int($0.subtype)) }
        let devices = controller.devices.map { $0.map { AgentMultipointDevice(macAddress: $0.macAddress, name: $0.name, connected: $0.connectedStatus != 0, playback: $0.isPlayback) } }
        let stcConfig = controller.speakToChatConfig.map { AgentSpeakToChatConfig(sensitivity: Int($0.sensitivity.rawValue), timeout: Int($0.timeout.rawValue)) }
        return AgentState(connectionStatus: status, deviceName: controller.deviceName, deviceAddress: address, ambient: ambient, battery: battery, equalizer: eq, speakToChat: controller.speakToChatEnabled, speakToChatConfig: stcConfig, automaticPowerOff: controller.automaticPowerOff.map { Int($0.rawValue) }, pauseOnRemove: controller.pauseWhenTakenOff, multipoint: devices, listeningMode: controller.listeningMode?.rawValue, bgmRoomSize: controller.bgmRoomSize.map { Int($0.rawValue) }, lastError: controller.lastError)
    }
}

@MainActor public final class PairedXM6Resolver: AgentDeviceResolving {
    public init() {}
    public func resolve(cachedAddress: String?) -> PairedDeviceInfo? {
        let devices = RFCOMMConnection.pairedDevices()
        if let cachedAddress, let cached = devices.first(where: { $0.id.caseInsensitiveCompare(cachedAddress) == .orderedSame }) {
            return cached
        }
        return devices.first(where: { $0.name.localizedCaseInsensitiveContains("WH-1000XM6") })
    }
}

private struct AgentConfig: Codable {
    var address: String?
    var hold: Bool?
}

public enum AgentLeaseOwnership: String, Codable, Equatable {
    case held, released, yielded, acquiring, unavailable

    /// Maps a persisted `connectionStatus` to the lease ownership a client should see.
    /// Kept here so the agent and the snapshot-serving IPC path cannot disagree.
    public static func forConnectionStatus(_ status: String) -> AgentLeaseOwnership {
        switch status {
        case "connected": return .held
        case "released": return .released
        case "yielded": return .yielded
        case "connecting", "initializing": return .acquiring
        default: return .unavailable
        }
    }
}

/// Connection and state authority.  The single timer is deliberately a one-shot: it
/// is either an acquisition retry, the idle release, a yield expiry, or the next peek.
@MainActor public final class XM6ConnectAgentCore {
    private enum DeviceMutationKey: Hashable {
        case ambient, equalizer, speakToChat, listeningMode, bgmRoomSize, playback
    }
    private enum DeviceMutationRequirement: Equatable {
        case none, sessionAmbient
    }
    /// What ambient commands asked for, merged into the one pending `.ambient` mutation.
    /// A nil field, and every cycle, resolves at send time from this session's state.
    private struct AmbientIntent {
        var mode: String?
        var level: Int?
        var focus: Bool?
        var cycles = 0
        /// Only a complete absolute choice may be sent without this session's state.
        var requirement: DeviceMutationRequirement {
            mode != nil && level != nil && focus != nil && cycles == 0 ? .none : .sessionAmbient
        }
        var isRelative: Bool { cycles > 0 && mode == nil }
        /// What survives when a lease end drops the cycles: the explicit level or focus,
        /// still waiting for this session's state. Nil when nothing absolute is left.
        var withoutCycles: AmbientIntent? {
            guard level != nil || focus != nil else { return nil }
            var kept = self
            kept.cycles = 0
            return kept
        }
    }
    private struct DeviceMutation {
        let key: DeviceMutationKey
        let requirement: DeviceMutationRequirement
        /// A cycle is relative to the mode the headset is in when it is sent, so it never
        /// outlives a release or an absent headset.
        let isRelative: Bool
        /// Set on an `.ambient` mutation only: the intent its action writes. A later ambient
        /// command starts from it, so it lives exactly as long as the pending mutation.
        let ambientIntent: AmbientIntent?
        let action: () -> Void
    }

    public private(set) var state = AgentState()
    private let controller: AgentHeadphonesControlling
    private let resolver: AgentDeviceResolving
    private let scheduler: RetryScheduling
    private let writer: StateWriting
    public let stateSnapshot: AgentStateSnapshot
    private let configURL: URL
    private let stateChanged: () -> Void
    private let now: () -> Date
    private let jitter: (TimeInterval) -> TimeInterval
    /// This timer is independent of the lease/retry timer: queued device writes must
    /// never replace an acquisition, release, yield, or peek deadline.
    private let deviceMutationScheduler: RetryScheduling
    private var activeDevice: PairedDeviceInfo?
    private var ownership: AgentLeaseOwnership = .released
    private var holdEnabled = false
    /// The agent owns both phase deadlines. A channel-open stall may be contention;
    /// a handshake stall proves our own channel opened and may be ACL-bounced once.
    public static let openTimeout: TimeInterval = 6
    public static let handshakeTimeout: TimeInterval = 5
    public static let handshakeTimeoutError = "WH-1000XM6 accepted the connection but did not complete its handshake"
    /// Phase deadlines need their OWN one-shot timer: the main scheduler is a
    /// single shared slot, so arming it here cancelled the peek/backoff timers.
    private let acquisitionScheduler: RetryScheduling
    /// Kept independently because RetryScheduling deliberately exposes no inspection
    /// API. A reconnect may replace an acquisition only when neither phase deadline
    /// nor another recovery path can still make progress.
    private var acquisitionDeadlineArmed = false
    private var asleep = false
    private var screenLocked = false
    private var asleepOrLocked: Bool { asleep || screenLocked }
    private var yieldedUntil: Date?
    private var lastRelease = Date.distantPast
    /// Last time this agent asked its transport to tear down. Unlike lastRelease,
    /// this also covers a yield, which may have been prompted by a foreign holder.
    private var lastTeardown = Date.distantPast
    private var lastCommand = Date.distantPast
    private var lastAcquire = Date.distantPast
    private var fastRetryIndex = 0
    private var retryScheduled = false
    private var stateFlushPending = false
    private var lastDeviceMutation = Date.distantPast
    private var pendingDeviceMutationKeys: [DeviceMutationKey] = []
    private var pendingDeviceMutations: [DeviceMutationKey: DeviceMutation] = [:]
    private var deviceMutationTimerArmed = false
    private var lastACLBounce = Date.distantPast
    private var bouncedThisEpisode = false
    private var handshakeRecoveryAttempted = false
    private var handshakeRetryPending = false
    private var yieldStep = 0
    private var pendingActionKeys: [DeviceMutationKey] = []
    private var pendingActions: [DeviceMutationKey: DeviceMutation] = [:]
    /// Ambient is retained in `state` across connections for display, but an ambient
    /// write must only resolve from a report received during this RFCOMM session, or from
    /// this session's own recent write. The session's end clears both.
    private var sessionAmbient: AgentAmbient? {
        didSet { if sessionAmbient == nil { lastWrittenAmbient = nil; lastAmbientWriteAt = nil } }
    }
    /// This session's last ambient write and when it was sent. Reports do not clear it: the
    /// headset echoes each write up to 806 ms later, and an echo of an earlier write must not
    /// undo a newer one. Never published and never written to `state`.
    private var lastWrittenAmbient: AgentAmbient?
    private var lastAmbientWriteAt: Date?
    /// Within this window after a write, the agent's own latest write is the basis for the
    /// next ambient write; after it, the headset's report is. A headset button press inside
    /// the window is therefore overridden only by a further Mac write.
    public static let ambientEchoWindow: TimeInterval = 1.0
    private var refreshCompletions: [((AgentReply) -> Void)] = []
    private var refreshTimeoutWork: DispatchWorkItem?
    private var peekInFlight = false
    /// A real bridge reports disconnect on a later run-loop turn.  Absorb duplicate
    /// teardown reports only inside this fence; outside it they are genuine failures.
    private var intentionalReleaseUntil = Date.distantPast
    private var externalActionTimes: [Date] = []
    /// A prewarm is a bounded courtesy lease, never command activity. Its separate
    /// deadline keeps its state sweep from becoming a normal idle lease.
    private var prewarmReleaseDeadline: Date?
    private var prewarmRequested = false
    private var prewarmAcquireAttempts = 0
    /// Whether macOS reported no Bluetooth link when the current acquisition started.
    private var acquiringWithoutLink = false
    public static let unavailableRetry: TimeInterval = 60
    public static let prewarmHold: TimeInterval = 8
    public static let maximumPendingActions = 128
    public static let maximumRefreshCompletions = 128
    public static let maximumExternalActionsPerMinute = 30
    nonisolated public static let defaultJitter: (TimeInterval) -> TimeInterval = { $0 * Double.random(in: 0.8...1.2) }
    private let logger = Logger(subsystem: "io.github.mbieniooo.xm6connect", category: "ACLRecovery")

    public init(controller: AgentHeadphonesControlling, resolver: AgentDeviceResolving,
                scheduler: RetryScheduling, writer: StateWriting, configURL: URL,
                stateSnapshot: AgentStateSnapshot = AgentStateSnapshot(),
                now: @escaping () -> Date = Date.init,
                jitter: @escaping (TimeInterval) -> TimeInterval = XM6ConnectAgentCore.defaultJitter,
                stateReader: StateReading? = nil,
                acquisitionScheduler: RetryScheduling? = nil,
                deviceMutationScheduler: RetryScheduling? = nil,
                stateChanged: @escaping () -> Void = {
                    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(XM6ConnectDarwinNotification.stateChanged as CFString), nil, nil, true)
                }) {
        self.controller = controller; self.resolver = resolver; self.scheduler = scheduler
        self.writer = writer; self.configURL = configURL; self.stateSnapshot = stateSnapshot; self.stateChanged = stateChanged
        self.now = now; self.jitter = jitter
        self.acquisitionScheduler = acquisitionScheduler ?? DispatchRetryScheduler()
        self.deviceMutationScheduler = deviceMutationScheduler ?? DispatchRetryScheduler()
        holdEnabled = readConfig().hold ?? false
        // Seed from the last persisted snapshot so a restart keeps showing the device's
        // last known values (aged honestly via stateAsOf) instead of blanking every
        // surface. Connection fields are authority of the live lease, never the file.
        if let persisted = stateReader?.read() {
            state = persisted
            state.connectionStatus = "released"
            state.lastError = nil
        }
        stateSnapshot.store(state)
        controller.onStateChanged = { [weak self] in self?.controllerChanged() }
    }
    public func start() {
        activeDevice = resolver.resolve(cachedAddress: cachedAddress())
        state.connectionStatus = activeDevice == nil ? "failed" : "released"
        state.lastError = activeDevice == nil ? "No paired WH-1000XM6 found" : nil
        commit()
        // Absence at launch is the common case, not a five-minute/forever terminal
        // state. Route it through acquire so its resolver-miss retry is armed.
        if activeDevice == nil || holdEnabled { acquire() } else { schedulePeek() }
    }

    /// Kept for compatibility with the old IPC verb.  It is an explicit user intent,
    /// not an unconditional daemon reconnect loop.
    /// An explicit user reconnect must override a yield: otherwise, once the agent has
    /// stood down, the popover's Reconnect button and `xm6ctl reconnect` silently do
    /// nothing for up to ten minutes. Standing down is for
    /// automatic behaviour, never for a human asking directly.
    public func reconnect() {
        // An in-flight acquisition is not necessarily stuck: its open/handshake clock,
        // an ordinary retry, or an ACL-bounce retry already owns the way forward.
        let force = ownership == .acquiring
            && !retryScheduled
            && !handshakeRetryPending
            && !acquisitionDeadlineArmed
        if ownership == .yielded { ownership = .released; yieldedUntil = nil; yieldStep = 0; state.connectionStatus = "released"; commit() }
        acquire(force: force)
    }
    /// IPC's refresh path uses this completion to wait for a report, without making
    /// the main actor or the socket accept loop poll Bluetooth state.
    public func refresh(completion: @escaping (AgentReply) -> Void) { beginRefresh(completion) }
    public func setAsleep(_ value: Bool) {
        asleep = value
        updateSleepOrLockState()
    }
    public func setScreenLocked(_ value: Bool) {
        screenLocked = value
        updateSleepOrLockState()
    }
    private func updateSleepOrLockState() {
        if asleepOrLocked {
            release(schedulePeek: false)
            return
        }
        // Re-arming a peek only restores the timer consumed while asleep; unlike hold,
        // it does not take the headset session immediately on wake.
        if holdEnabled { acquire() } else { schedulePeek() }
    }
    // Deterministic harness visibility; production has no callers for these values.
    public var ownershipForTesting: AgentLeaseOwnership { ownership }
    public var timerArmedForTesting: Bool { retryScheduled }
    public var pendingActionCountForTesting: Int { pendingActions.count }
    public var pendingCycleForTesting: Bool { pendingActions[.ambient]?.isRelative == true || pendingDeviceMutations[.ambient]?.isRelative == true }
    public var refreshCompletionCountForTesting: Int { refreshCompletions.count }
    public var prewarmDeadlineForTesting: Date? { prewarmReleaseDeadline }
    public var lastCommandForTesting: Date { lastCommand }
    public var prewarmAcquireAttemptsForTesting: Int { prewarmAcquireAttempts }
    public var yieldStepForTesting: Int { yieldStep }
    public var bouncedThisEpisodeForTesting: Bool { bouncedThisEpisode }
    public var acquisitionDeadlineArmedForTesting: Bool { acquisitionDeadlineArmed }

    private func readConfig() -> AgentConfig {
        let resolvedURL = configURL.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 4 * 1024,
              let handle = try? FileHandle(forReadingFrom: resolvedURL),
              let data = try? handle.read(upToCount: 4 * 1024 + 1) else { return AgentConfig(address: nil, hold: nil) }
        try? handle.close()
        guard data.count <= 4 * 1024,
              let config = try? JSONDecoder().decode(AgentConfig.self, from: data) else { return AgentConfig(address: nil, hold: nil) }
        return config
    }
    private func cachedAddress() -> String? { readConfig().address }
    private func persistConfig() {
        if let data = try? JSONEncoder.xm6Connect.encode(AgentConfig(address: activeDevice?.id ?? cachedAddress(), hold: holdEnabled)) {
            try? AtomicStateWriter.writeData(data, to: configURL)
        }
    }
    private func acquire(force: Bool = false, retryingHandshake: Bool = false) {
        guard !asleepOrLocked, ownership != .yielded || force else { return }
        if ownership == .yielded, let until = yieldedUntil, until > now(), !force { return }
        // Commands arriving during an acquisition join its pending-action queue. They
        // must not create a second controller.connect or restart the phase clock.
        if ownership == .held || (ownership == .acquiring && !force) { return }
        sessionAmbient = nil
        let sinceTeardown = now().timeIntervalSince(lastTeardown)
        if !force && sinceTeardown < 2 {
            arm(after: 2 - sinceTeardown) { [weak self] in self?.acquire() }
            return
        }
        scheduler.cancel(); retryScheduled = false
        guard let device = resolver.resolve(cachedAddress: cachedAddress()) else {
            ownership = .unavailable; state.connectionStatus = "failed"; state.lastError = "No paired WH-1000XM6 found"; commit()
            arm(after: Self.unavailableRetry) { [weak self] in self?.acquire() }
            return
        }
        if !retryingHandshake { handshakeRecoveryAttempted = false }
        handshakeRetryPending = false
        lastAcquire = now(); ownership = .acquiring
        // Our ACL bounce deliberately puts the link down before the retry. That says
        // nothing about headset presence, so do not turn our own teardown into a
        // false “not connected to this Mac” diagnosis.
        acquiringWithoutLink = retryingHandshake ? false : !device.isConnected
        activeDevice = device; state.connectionStatus = "connecting"; state.deviceAddress = device.id; state.deviceName = device.name; state.lastError = nil; commit()
        controller.connect(address: device.id, name: device.name)
        armOpenDeadline()
    }
    private func armOpenDeadline() {
        cancelAcquisitionDeadline()
        acquisitionDeadlineArmed = true
        acquisitionScheduler.schedule(after: Self.openTimeout) { [weak self] in
            self?.acquisitionDeadlineArmed = false
            guard let self, self.ownership == .acquiring, self.state.connectionStatus == "connecting" else { return }
            // No RFCOMM channel opened, so it may be held by the phone. Bouncing in
            // this phase would risk tearing down a foreign holder's ACL.
            if self.acquiringWithoutLink { self.reportMissingHeadset(); return }
            self.logger.log("Channel open stalled — assuming another controller holds the session")
            self.controller.disconnect()
            self.enterYield()
        }
    }
    private func armHandshakeDeadline() {
        cancelAcquisitionDeadline()
        acquisitionDeadlineArmed = true
        acquisitionScheduler.schedule(after: Self.handshakeTimeout) { [weak self] in
            self?.acquisitionDeadlineArmed = false
            guard let self, self.ownership == .acquiring, self.state.connectionStatus == "initializing" else { return }
            self.handleHandshakeTimeout()
        }
    }
    private func cancelAcquisitionDeadline() {
        acquisitionScheduler.cancel()
        acquisitionDeadlineArmed = false
    }
    private func handleHandshakeTimeout() {
        cancelAcquisitionDeadline()
        guard !handshakeRecoveryAttempted,
              ACLBounceRecoveryPolicy.mayBounce(
                alreadyBouncedThisEpisode: bouncedThisEpisode,
                timeSinceLastBounce: now().timeIntervalSince(lastACLBounce)
              ) else {
            standDownAfterHandshakeTimeout()
            return
        }
        handshakeRecoveryAttempted = true
        handshakeRetryPending = true
        bouncedThisEpisode = true
        lastACLBounce = now()
        // bounceACL closes our RFCOMM/ACL session asynchronously; fence that
        // deliberate teardown before it can enter the generic failure ladder.
        intentionalReleaseUntil = now().addingTimeInterval(2)
        logger.log("Handshake stalled — bouncing our own ACL once")
        controller.bounceACL()
        // The agent's one scheduled reacquire is the only post-bounce reopen. Re-enter
        // only once so the next phase gets a fresh, agent-owned deadline.
        arm(after: 3) { [weak self] in
            guard let self, self.handshakeRetryPending else { return }
            self.acquire(force: true, retryingHandshake: true)
        }
    }
    private func standDownAfterHandshakeTimeout() {
        cancelAcquisitionDeadline()
        sessionAmbient = nil; returnThrottledWritesForNextLease(keepRelative: true)
        handshakeRetryPending = false; peekInFlight = false
        prewarmRequested = false; prewarmReleaseDeadline = nil; acquiringWithoutLink = false
        handshakeRecoveryAttempted = false
        lastRelease = now(); lastTeardown = now(); ownership = .released
        // This ends the recovery episode. Keep lastACLBounce for its minimum interval,
        // but allow a later, separate stale-session episode to use its own one bounce.
        bouncedThisEpisode = false
        intentionalReleaseUntil = now().addingTimeInterval(2)
        controller.disconnect()
        state.connectionStatus = "failed"; state.lastError = Self.handshakeTimeoutError
        commit()
        arm(after: Self.unavailableRetry) { [weak self] in self?.acquire() }
    }
    private func controllerChanged() {
        let previousStatus = state.connectionStatus
        let fresh = controller.snapshot(address: activeDevice?.id)
        let terminalTransition = fresh.connectionStatus == "disconnected" || fresh.connectionStatus == "failed"
        // A terminal transition while initializing belongs to the handshake phase,
        // not to handleFailure's generic retry/yield ladder.
        if ownership == .acquiring, previousStatus == "initializing", terminalTransition, !handshakeRetryPending {
            handleHandshakeTimeout()
            return
        }
        // A bounce-close inside the deliberate-teardown fence is expected. A late
        // terminal report while the retry is still pending remains handshake policy
        // too: it stands down rather than falling through to generic recovery.
        if handshakeRetryPending, terminalTransition {
            if now() <= intentionalReleaseUntil { return }
            handleHandshakeTimeout()
            return
        }
        if now() <= intentionalReleaseUntil && terminalTransition {
            switch ownership {
            case .yielded: state.connectionStatus = "yielded"
            case .unavailable: state.connectionStatus = "failed"
            case .released:
                if state.connectionStatus != "failed" { state.connectionStatus = "released" }
            case .acquiring, .held:
                // A bridge can deliver the same terminal snapshot twice when the kit
                // published more than one field for one transport event. Preserve the
                // snapshot, but never replace this fence's deliberate recovery timer.
                if previousStatus == "failed" || previousStatus == "disconnected" {
                    state = merged(previous: state, fresh: fresh)
                    commit()
                    return
                }
                // This is not one of our resting teardown states: an attempt started
                // inside the fence and needs the normal failure recovery path.
                state = merged(previous: state, fresh: fresh)
                commit()
                handleFailure(controller.consumeTransportFailure())
                return
            }
            commit()
            return
        }
        let isReport = fresh.connectionStatus == "connected" && hasDeviceReport(fresh)
        if fresh.connectionStatus == "connected", let ambient = fresh.ambient {
            sessionAmbient = ambient
        }
        state = merged(previous: state, fresh: fresh)
        if isReport { state.stateAsOf = now() }
        commit()
        if ownership == .acquiring, state.connectionStatus == "initializing", previousStatus != "initializing" {
            // This is the open -> handshake boundary, never a refresh of an already
            // armed handshake clock.
            armHandshakeDeadline()
        }
        if state.connectionStatus == "connected" && previousStatus != "connected" {
            cancelAcquisitionDeadline()
            ownership = .held; scheduler.cancel(); fastRetryIndex = 0; yieldStep = 0; bouncedThisEpisode = false
            handshakeRecoveryAttempted = false; handshakeRetryPending = false
            acquiringWithoutLink = false
            if prewarmRequested {
                prewarmRequested = false
                prewarmReleaseDeadline = now().addingTimeInterval(Self.prewarmHold)
            }
            if activeDevice != nil { persistConfig() }
            // The controller's full sweep is an outbound FIFO. A waiting user command
            // must enter it before that maintenance traffic, immediately after the
            // handshake declares the channel connected.
            runPendingActionsIfReady()
            controller.refreshState()
            // A failed or incomplete state sweep must not turn the guest lease into a
            // permanent hold.
            scheduleIdleRelease()
        }
        if ownership == .held, isReport {
            // A relative cycle without ambient remains pending at the connection
            // boundary; compute it only from the first real ambient report. Ordinary
            // queued commands have already flushed regardless of that missing value.
            runPendingActionsIfReady()
            finishRefresh(stale: false)
            if peekInFlight && !holdEnabled { release() } else { scheduleIdleRelease() }
        } else if terminalTransition {
            // This is a separate bridge turn, so coalescing cannot help. The live
            // snapshot has already been merged and committed above; a terminal state
            // followed by another terminal state is one transport loss, not two rungs.
            guard previousStatus != "disconnected", previousStatus != "failed" else { return }
            handleFailure(controller.consumeTransportFailure())
        }
    }
    private func hasDeviceReport(_ state: AgentState) -> Bool {
        state.ambient != nil || state.battery != nil || state.equalizer != nil || state.speakToChat != nil || state.speakToChatConfig != nil || state.automaticPowerOff != nil || state.pauseOnRemove != nil || state.multipoint != nil || state.listeningMode != nil || state.bgmRoomSize != nil
    }
    private func beginRefresh(_ completion: ((AgentReply) -> Void)?) {
        lastCommand = now()
        if let completion {
            if refreshCompletions.count >= Self.maximumRefreshCompletions {
                // Drop oldest rather than allow a client flood to retain closures forever.
                let dropped = refreshCompletions.removeFirst()
                dropped(AgentReply(state: state, error: "refresh queue full", ownership: ownership.rawValue, stale: true))
            }
            refreshCompletions.append(completion)
        }
        if ownership == .held { controller.refreshState(); scheduleIdleRelease() } else { acquire() }
        guard completion != nil else { return }
        refreshTimeoutWork?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.finishRefresh(stale: true) }
        refreshTimeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
    }
    private func finishRefresh(stale: Bool) {
        guard !refreshCompletions.isEmpty else { return }
        refreshTimeoutWork?.cancel(); refreshTimeoutWork = nil
        let completions = refreshCompletions; refreshCompletions.removeAll()
        let reply = AgentReply(state: state, ownership: ownership.rawValue, stale: stale)
        completions.forEach { $0(reply) }
    }
    /// The kit intentionally clears fields between RFCOMM sessions.  That is not a
    /// device report, so retain known values until a non-nil report supersedes them.
    private func merged(previous: AgentState, fresh: AgentState) -> AgentState {
        var value = fresh
        value.deviceName = fresh.deviceName ?? previous.deviceName
        value.deviceAddress = fresh.deviceAddress ?? previous.deviceAddress
        value.ambient = fresh.ambient ?? previous.ambient; value.battery = fresh.battery ?? previous.battery
        value.equalizer = fresh.equalizer ?? previous.equalizer; value.speakToChat = fresh.speakToChat ?? previous.speakToChat
        value.speakToChatConfig = fresh.speakToChatConfig ?? previous.speakToChatConfig
        value.automaticPowerOff = fresh.automaticPowerOff ?? previous.automaticPowerOff
        value.pauseOnRemove = fresh.pauseOnRemove ?? previous.pauseOnRemove; value.multipoint = fresh.multipoint ?? previous.multipoint
        value.listeningMode = fresh.listeningMode ?? previous.listeningMode
        value.bgmRoomSize = fresh.bgmRoomSize ?? previous.bgmRoomSize
        value.stateAsOf = previous.stateAsOf
        return value
    }
    private func handleFailure(_ failure: RFCOMMConnectionFailureContext?) {
        sessionAmbient = nil; returnThrottledWritesForNextLease(keepRelative: true)
        guard !asleepOrLocked, ownership != .yielded else { return }
        // A terminal controller transition ends whichever phase clock armed this
        // attempt. Without this, a stale phase deadline can bounce after its channel
        // has already closed or after generic recovery selected another policy.
        cancelAcquisitionDeadline()
        // A prewarm is one bounded attempt, not a background reconnect campaign.
        // Failed automatic acquisition returns to the resting/peek policy immediately.
        if prewarmRequested {
            prewarmRequested = false; prewarmReleaseDeadline = nil
            ownership = .released; state.connectionStatus = "released"; commit()
            schedulePeek()
            return
        }
        // A transport loss ends a held lease even if the controller did not emit an
        // explicit intermediate state.  Otherwise acquire() would see `.held` and
        // silently suppress the only recovery timer.
        if ownership == .held { ownership = .released }
        if let failure, failure.kind == .controlRefused, failure.isConnected {
            let ownStale = now().timeIntervalSince(lastRelease) <= 30
            if ownStale && ACLBounceRecoveryPolicy.mayBounce(alreadyBouncedThisEpisode: bouncedThisEpisode, timeSinceLastBounce: now().timeIntervalSince(lastACLBounce)) {
                bouncedThisEpisode = true; lastACLBounce = now()
                intentionalReleaseUntil = now().addingTimeInterval(2)
                logger.log("Bouncing only our recent stale RFCOMM session")
                controller.bounceACL()
                // The caller-owned reacquisition is the recovery path after this bounce.
                arm(after: 3) { [weak self] in self?.acquire(force: true) }
            } else {
                enterYield()
            }
            return
        }
        let delays: [TimeInterval] = [0.5, 1, 2]
        guard fastRetryIndex < delays.count else { enterYield(); return }
        let delay = delays[fastRetryIndex]; fastRetryIndex += 1
        arm(after: delay) { [weak self] in self?.acquire(force: true) }
    }
    /// Ends an acquisition that never had a Bluetooth link to stall against. Unlike a
    /// yield this keeps the retry cadence short and the yield ladder untouched: nobody is
    /// competing for the control session, the headset simply is not here.
    public static let missingHeadsetError = "WH-1000XM6 is not connected to this Mac"
    private func reportMissingHeadset() {
        logger.log("Acquisition stalled with no Bluetooth link — reporting the headset as not connected")
        sessionAmbient = nil
        acquiringWithoutLink = false
        cancelAcquisitionDeadline()
        prewarmRequested = false; prewarmReleaseDeadline = nil
        // A relative cycle cannot be computed without a device report, so absence
        // ends it; ordinary queued actions remain available for a later lease.
        returnThrottledWritesForNextLease(keepRelative: false); peekInFlight = false
        lastRelease = now(); lastTeardown = now(); ownership = .unavailable
        intentionalReleaseUntil = now().addingTimeInterval(2)
        controller.disconnect()
        state.connectionStatus = "failed"; state.lastError = Self.missingHeadsetError
        commit()
        arm(after: Self.unavailableRetry) { [weak self] in self?.acquire() }
    }
    private func enterYield(seconds: TimeInterval? = nil) {
        let base = seconds ?? [60, 180, 600][min(yieldStep, 2)]
        if seconds == nil { yieldStep = min(yieldStep + 1, 2) }
        cancelAcquisitionDeadline(); sessionAmbient = nil; prewarmRequested = false; prewarmReleaseDeadline = nil; peekInFlight = false
        returnThrottledWritesForNextLease(keepRelative: true)
        ownership = .yielded; yieldedUntil = now().addingTimeInterval(max(1, seconds == nil ? jitter(base) : base))
        lastTeardown = now()
        intentionalReleaseUntil = now().addingTimeInterval(2)
        controller.disconnect(); state.connectionStatus = "yielded"; commit()
        let delay = max(0, yieldedUntil!.timeIntervalSince(now()))
        arm(after: delay) { [weak self] in
            guard let self, self.ownership == .yielded else { return }
            self.ownership = .released; self.yieldedUntil = nil; self.state.connectionStatus = "released"; self.commit()
            if self.asleepOrLocked { self.schedulePeek() }
            else { self.acquire() } // one probe after the suppression window, never a loop
        }
    }
    private func release(schedulePeek shouldSchedulePeek: Bool = true) {
        // Acquiring includes the initializing/handshake phase. Sleep, lock, and
        // hold-off must cancel it too, or a sleeping Mac can ACL-bounce later.
        guard ownership == .held || ownership == .acquiring else { return }
        scheduler.cancel(); retryScheduled = false; sessionAmbient = nil; peekInFlight = false
        returnThrottledWritesForNextLease(keepRelative: false)
        // Do not silently discard queued user commands. They remain queued for the
        // next successful lease; the caller sees the released state rather than a lie.
        prewarmRequested = false; prewarmReleaseDeadline = nil; acquiringWithoutLink = false
        handshakeRetryPending = false; handshakeRecoveryAttempted = false
        lastRelease = now(); lastTeardown = now(); ownership = .released; state.connectionStatus = "released"; intentionalReleaseUntil = now().addingTimeInterval(2); cancelAcquisitionDeadline(); controller.disconnect(); commit()
        if shouldSchedulePeek { schedulePeek() }
    }
    private func scheduleIdleRelease() {
        guard !holdEnabled, ownership == .held else { return }
        if let prewarmReleaseDeadline {
            arm(after: max(0, prewarmReleaseDeadline.timeIntervalSince(now()))) { [weak self] in self?.release() }
            return
        }
        let activity = max(lastAcquire, lastCommand)
        arm(after: max(0, activity.addingTimeInterval(20).timeIntervalSince(now()))) { [weak self] in
            // Re-check hold when the timer fires because hold may have been enabled
            // after this idle release was armed.
            guard let self, !self.holdEnabled else { return }
            self.release()
        }
    }
    private func schedulePeek() {
        // An acquisition always ends in a release (which arms the peek) or in its own
        // recovery timer. A peek armed meanwhile, e.g. by an unmatched unlock or wake,
        // would replace that recovery in the shared slot and strand the attempt.
        guard ownership != .yielded, ownership != .acquiring else { return }
        // Hold means "keep the channel", so a release under hold must re-acquire rather
        // than arm nothing. Kept as defence: with the idle-release guard and the cancel
        // on hold-enable in place no caller currently reaches here under hold, so this
        // branch is deliberately NOT covered by a test rather than covered by a
        // decorative one.
        if holdEnabled { arm(after: 2) { [weak self] in self?.acquire() }; return }
        arm(after: 5 * 60) { [weak self] in
            guard let self, !self.holdEnabled, self.ownership != .yielded else { return }
            // A one-shot that fires during sleep must replace itself; otherwise the
            // sleep consumes the only peek forever. It still never acquires asleep.
            if self.asleepOrLocked { self.schedulePeek(); return }
            self.peekInFlight = true; self.lastCommand = self.now(); self.acquire()
        }
    }
    private func arm(after seconds: TimeInterval, _ action: @escaping () -> Void) {
        retryScheduled = true
        scheduler.schedule(after: max(0, seconds)) { [weak self] in self?.retryScheduled = false; action() }
    }
    private func commit() {
        state.timestamp = now()
        stateSnapshot.store(state)
        if !stateFlushPending {
            stateFlushPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                guard let self else { return }
                self.stateFlushPending = false
                try? self.writer.write(self.state)
                self.stateChanged()
            }
        }
    }

    public func handle(_ request: IPCRequest, updatesIdleActivity: Bool = true) -> AgentReply {
        var error: String?
        func enqueueCommand(_ key: DeviceMutationKey, _ action: @escaping () -> Void) {
            markCommandActivity(updatesIdleActivity)
            enqueueOrSend(key: key, action)
            acquire()
        }
        switch request {
        case .status: break
        case .prewarm: prewarm()
        case .reconnect: markCommandActivity(updatesIdleActivity); reconnect()
        case .refresh: beginRefresh(nil)
        case .yield(let seconds): enterYield(seconds: seconds ?? 600)
        case .hold(let enabled):
            holdEnabled = enabled; persistConfig(); markCommandActivity(updatesIdleActivity)
            // acquire() returns early when the lease is already held, so a pending idle
            // release would survive the switch and strand the agent.
            if enabled {
                if ownership == .held { scheduler.cancel(); retryScheduled = false }
                acquire()
            }
            else { release(); schedulePeek() }
        case .cycle:
            // Resolve the next mode only from this session's ambient state.
            markCommandActivity(updatesIdleActivity)
            enqueueAmbient { $0.cycles += 1 }
            acquire()
        case .setAmbient(let mode, let level, let focus):
            markCommandActivity(updatesIdleActivity)
            enqueueAmbient { $0 = AmbientIntent(mode: mode, level: level, focus: focus) }
            acquire()
        case .setMode(let mode):
            // Only the mode is the caller's intent. Level and focus come from this
            // session's report, so a widget or CLI mode change never replays values the
            // phone may have changed while the Mac was released.
            markCommandActivity(updatesIdleActivity)
            enqueueAmbient { $0.mode = mode; $0.cycles = 0 }
            acquire()
        case .setFocus(let enabled):
            // Only focus is the caller's intent; mode and level come from this session.
            markCommandActivity(updatesIdleActivity)
            enqueueAmbient { $0.focus = enabled }
            acquire()
        case .setAmbientLevel(let level):
            // Ambient at that level; focus stays whatever this session's headset reports.
            markCommandActivity(updatesIdleActivity)
            enqueueAmbient { $0.mode = "ambient"; $0.level = level; $0.cycles = 0 }
            acquire()
        case .setEQPreset(let code):
            enqueueCommand(.equalizer) { [weak self] in self?.controller.sendEqualizerPreset(code: code) }
        case .setEQBands(let bands):
            enqueueCommand(.equalizer) { [weak self] in self?.controller.sendEqualizerBands(bands) }
        case .setSTC(let enabled): enqueueCommand(.speakToChat) { [weak self] in self?.controller.sendSpeakToChat(enabled) }
        case .setListeningMode(let mode):
            enqueueCommand(.listeningMode) { [weak self] in self?.controller.setListeningMode(mode) }
        case .setBGMRoomSize(let rawValue):
            enqueueCommand(.bgmRoomSize) { [weak self] in self?.controller.setBGMRoomSize(rawValue) }
        case .switchPlayback(let macAddress):
            // The socket is an untrusted boundary.  A syntactically valid address is
            // still not sufficient: only an address in the device-reported list may
            // ever reach the RFCOMM write path.
            guard IPCRequest.isCanonicalMAC(macAddress) else {
                error = "switch_playback requires canonical uppercase MAC XX:XX:XX:XX:XX:XX"
                break
            }
            guard let device = state.multipoint?.first(where: { $0.macAddress == macAddress }) else {
                error = "playback device is not in the current multipoint list"
                break
            }
            guard device.connected else {
                error = "playback device is not connected"
                break
            }
            guard allowExternalAction() else {
                error = "external action rate limited"
                break
            }
            enqueueCommand(.playback) { [weak self] in self?.controller.switchPlayback(to: device) }
            // The headset's new list arrives after the switch, and no report re-arms the idle
            // release before it does. Re-arm it from this command so a switch accepted late in
            // the idle window is not cut off before the list arrives.
            if ownership == .held { scheduleIdleRelease() }
        }
        // The state in this reply predates any accepted write or reconnect it started.
        let stale = error == nil && request.isDeviceWrite
        return AgentReply(state: state, error: error, ownership: ownership.rawValue, stale: stale)
    }
    /// Darwin actions intentionally re-enter `handle(_:)`; widget taps therefore
    /// inherit the IPC command path's lease acquisition and mutation rate limit.
    @discardableResult public func handle(widgetAction action: XM6ConnectDarwinNotification.Action) -> AgentReply {
        // Do eligibility before consuming the shared external-action allowance. A
        // reload while the phone owns the lease is a no-op, not rate-budget pressure.
        let request: IPCRequest
        switch action {
        case .prewarm:
            prewarm()
            return AgentReply(state: state, ownership: ownership.rawValue)
        case .cycle: request = .cycle
        case .noiseCancelling: request = .setMode(mode: "nc")
        case .ambient: request = .setMode(mode: "ambient")
        case .off: request = .setMode(mode: "off")
        case .equalizer(let preset): request = .setEQPreset(code: preset.rawValue)
        }
        guard allowExternalAction() else {
            return AgentReply(state: state, error: "external action rate limited", ownership: ownership.rawValue)
        }
        return handle(request, updatesIdleActivity: false)
    }
    private func sendAmbient(mode: String, level: Int, focus: Bool) {
        let soundMode: AmbientSoundMode = mode == "nc" ? .noiseCancelling : (mode == "ambient" ? .ambientSound : .off)
        controller.sendAmbient(AmbientSoundState(mode: soundMode, focusOnVoice: focus, level: level, subtype: 0x17, hasWindNoiseByte: false))
    }
    /// Every ambient command edits the intent of the `.ambient` mutation still pending (the
    /// cold queue's first, else the throttle's), so commands made before a write is sent
    /// compose into that one write instead of replacing each other.
    private func enqueueAmbient(_ change: (inout AmbientIntent) -> Void) {
        var intent = pendingActions[.ambient]?.ambientIntent ?? pendingDeviceMutations[.ambient]?.ambientIntent ?? AmbientIntent()
        change(&intent)
        enqueueOrSend(ambientMutation(intent))
    }
    /// The one place an `.ambient` mutation is built, so its requirement, relativity and
    /// action always follow the intent it carries.
    private func ambientMutation(_ intent: AmbientIntent) -> DeviceMutation {
        DeviceMutation(key: .ambient, requirement: intent.requirement, isRelative: intent.isRelative, ambientIntent: intent) { [weak self] in
            self?.writeAmbient(intent)
        }
    }
    /// Resolves what the intent leaves open from this session's own write of the last
    /// `ambientEchoWindow`, else this session's report. Retained display state is never a
    /// source for a device write.
    private func writeAmbient(_ intent: AmbientIntent) {
        let basis = recentOwnAmbientWrite() ?? sessionAmbient
        guard var mode = intent.mode ?? basis?.mode, let level = intent.level ?? basis?.level,
              let focus = intent.focus ?? basis?.focus else { return }
        for _ in 0..<(intent.cycles % 3) { mode = mode == "nc" ? "ambient" : (mode == "ambient" ? "off" : "nc") }
        sendAmbient(mode: mode, level: level, focus: focus)
        if let session = sessionAmbient {
            lastWrittenAmbient = AgentAmbient(mode: mode, level: level, focus: focus, subtype: session.subtype, hasWindNoiseByte: session.hasWindNoiseByte)
            lastAmbientWriteAt = now()
        }
    }
    private func recentOwnAmbientWrite() -> AgentAmbient? {
        guard let written = lastWrittenAmbient, let at = lastAmbientWriteAt,
              now().timeIntervalSince(at) < Self.ambientEchoWindow else { return nil }
        return written
    }
    private func replaceOrAppend(_ mutation: DeviceMutation, keys: inout [DeviceMutationKey], values: inout [DeviceMutationKey: DeviceMutation]) {
        if values[mutation.key] == nil {
            if keys.count >= Self.maximumPendingActions {
                values.removeValue(forKey: keys.removeFirst())
            }
            keys.append(mutation.key)
        }
        values[mutation.key] = mutation
    }
    private func scheduleDeviceMutation(_ mutation: DeviceMutation) {
        if !pendingDeviceMutationKeys.isEmpty || deviceMutationTimerArmed {
            replaceOrAppend(mutation, keys: &pendingDeviceMutationKeys, values: &pendingDeviceMutations)
            return
        }
        // Clamped so a wall clock that steps backwards cannot stall every later write.
        let remaining = min(0.2, 0.2 - now().timeIntervalSince(lastDeviceMutation))
        guard remaining > 0 else {
            lastDeviceMutation = now()
            mutation.action()
            return
        }
        replaceOrAppend(mutation, keys: &pendingDeviceMutationKeys, values: &pendingDeviceMutations)
        armDeviceMutationTimer(after: remaining)
    }
    private func armDeviceMutationTimer(after delay: TimeInterval) {
        guard !pendingDeviceMutationKeys.isEmpty else { return }
        deviceMutationTimerArmed = true
        deviceMutationScheduler.schedule(after: max(0, delay)) { [weak self] in
            guard let self else { return }
            self.deviceMutationTimerArmed = false
            guard self.ownership == .held else { self.returnThrottledWritesForNextLease(keepRelative: true); return }
            guard let key = self.pendingDeviceMutationKeys.first,
                  let mutation = self.pendingDeviceMutations.removeValue(forKey: key) else { return }
            self.pendingDeviceMutationKeys.removeFirst()
            self.lastDeviceMutation = self.now()
            mutation.action()
            if !self.pendingDeviceMutationKeys.isEmpty {
                self.armDeviceMutationTimer(after: 0.2)
            }
        }
    }
    /// A lease ended: writes still waiting in the throttle go back to the front of the
    /// cold queue for the next lease, unless a newer write for that setting is already
    /// waiting there. `keepRelative: false` also ends a queued cycle.
    private func returnThrottledWritesForNextLease(keepRelative: Bool) {
        deviceMutationScheduler.cancel(); deviceMutationTimerArmed = false
        var returning: [DeviceMutationKey] = []
        for key in pendingDeviceMutationKeys {
            guard let mutation = pendingDeviceMutations.removeValue(forKey: key), pendingActions[key] == nil else { continue }
            pendingActions[key] = mutation; returning.append(key)
        }
        pendingDeviceMutationKeys.removeAll()
        pendingActionKeys = returning + pendingActionKeys
        if !keepRelative {
            // A cycle ends with the lease; an explicit level or focus composed with it does not.
            for key in pendingActionKeys where pendingActions[key]?.isRelative == true {
                if let kept = pendingActions[key]?.ambientIntent?.withoutCycles {
                    pendingActions[key] = ambientMutation(kept)
                } else {
                    pendingActions.removeValue(forKey: key)
                }
            }
            pendingActionKeys.removeAll { pendingActions[$0] == nil }
        }
    }
    private func enqueueOrSend(key: DeviceMutationKey, _ action: @escaping () -> Void) {
        enqueueOrSend(DeviceMutation(key: key, requirement: .none, isRelative: false, ambientIntent: nil, action: action))
    }
    private func enqueueOrSend(_ mutation: DeviceMutation) {
        let key = mutation.key
        if ownership == .held, mutation.requirement != .sessionAmbient || sessionAmbient != nil {
            // Latest wins per setting across both queues: an older write for this setting
            // that is still waiting for this session's report must not run after this one.
            if pendingActions.removeValue(forKey: key) != nil { pendingActionKeys.removeAll { $0 == key } }
            scheduleDeviceMutation(mutation)
        } else {
            replaceOrAppend(mutation, keys: &pendingActionKeys, values: &pendingActions)
        }
    }
    private func runPendingActionsIfReady() {
        // Ambient actions that need this session's state wait for a report received in this
        // session; retained display state is never a source for a device write.
        let keys = pendingActionKeys
        for key in keys {
            guard let mutation = pendingActions[key] else { continue }
            guard mutation.requirement != .sessionAmbient || sessionAmbient != nil else { continue }
            pendingActions.removeValue(forKey: key)
            pendingActionKeys.removeAll { $0 == key }
            // A queued user write turns a probe into a real lease, so a peek cannot
            // release the channel under the writes it just flushed.
            peekInFlight = false
            scheduleDeviceMutation(mutation)
        }
    }
    private func markCommandActivity(_ enabled: Bool) {
        peekInFlight = false
        if enabled {
            lastCommand = now()
            // A direct command may take over a prewarmed lease, at which point the
            // ordinary idle window is appropriate. External actions intentionally do
            // not receive that privilege.
            prewarmRequested = false
            prewarmReleaseDeadline = nil
        }
        // A command the user actually issued must outrank an automatic stand-down.
        // Otherwise it is accepted, reported without error, and silently dropped —
        // exactly what happens to a playback switch (and to Reconnect before it) while
        // the agent sits in a yield. Standing down protects the
        // phone from our AUTOMATIC traffic, never from the person at the keyboard; the
        // external-action rate limit still caps abuse.
        if ownership == .yielded {
            ownership = .released; yieldedUntil = nil; yieldStep = 0
            state.connectionStatus = "released"; commit()
        }
    }
    private func allowExternalAction() -> Bool {
        let cutoff = now().addingTimeInterval(-60)
        externalActionTimes.removeAll { $0 < cutoff }
        guard externalActionTimes.count < Self.maximumExternalActionsPerMinute else { return false }
        externalActionTimes.append(now())
        return true
    }

    /// Starts a short, non-command lease only from the true resting state. It is
    /// deliberately narrower than `acquire`: prewarming never defeats yield, hold,
    /// or sleep/lock protections, and it shares the external-origin rate cap.
    private func prewarm() {
        guard ownership == .released, !holdEnabled, !asleepOrLocked else { return }
        guard allowExternalAction() else { return }
        prewarmAcquireAttempts += 1
        prewarmRequested = true
        acquire()
    }
}

public enum IPCRequest: Equatable {
    public static let maximumLineBytes = 16 * 1024
    case status, cycle, reconnect, refresh, prewarm
    case yield(seconds: TimeInterval?), hold(Bool)
    case setAmbient(mode: String, level: Int, focus: Bool)
    case setMode(mode: String)
    case setFocus(enabled: Bool)
    case setAmbientLevel(level: Int)
    case setEQPreset(code: UInt8), setEQBands([Int]), setSTC(Bool)
    case setListeningMode(mode: String)
    case setBGMRoomSize(rawValue: UInt8)
    case switchPlayback(macAddress: String)

    /// An accepted request whose effect reaches the headset only after its reply is built:
    /// a setting write, a source switch or a reconnect.
    public var isDeviceWrite: Bool {
        switch self {
        case .reconnect, .cycle, .setAmbient, .setMode, .setFocus, .setAmbientLevel, .setEQPreset, .setEQBands,
             .setSTC, .setListeningMode, .setBGMRoomSize, .switchPlayback:
            return true
        case .status, .prewarm, .refresh, .yield, .hold:
            return false
        }
    }

    /// This is deliberately narrower than a generic MAC parser.  Source switching
    /// accepts protocol-ready, canonical uppercase addresses only.
    public static func isCanonicalMAC(_ value: String) -> Bool {
        guard value.utf8.count == 17 else { return false }
        let bytes = Array(value.utf8)
        for index in bytes.indices {
            if index % 3 == 2 {
                guard bytes[index] == 0x3a else { return false }
            } else {
                let byte = bytes[index]
                guard (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) else { return false }
            }
        }
        return true
    }

    public struct ParseError: Error, Equatable, CustomStringConvertible { public let description: String; init(_ description: String) { self.description = description } }
    public static func parse(_ data: Data) -> Result<IPCRequest, ParseError> {
        guard data.count <= maximumLineBytes else { return .failure(ParseError("request line too long")) }
        guard let object = try? JSONSerialization.jsonObject(with: data), let json = object as? [String: Any], let command = json["cmd"] as? String else { return .failure(ParseError("malformed JSON request")) }
        func only(_ keys: Set<String>) -> Bool { Set(json.keys).isSubset(of: keys) }
        switch command {
        case "status": return only(["cmd"]) ? .success(.status) : .failure(ParseError("unexpected field"))
        case "cycle": return only(["cmd"]) ? .success(.cycle) : .failure(ParseError("unexpected field"))
        case "reconnect": return only(["cmd"]) ? .success(.reconnect) : .failure(ParseError("unexpected field"))
        case "refresh": return only(["cmd"]) ? .success(.refresh) : .failure(ParseError("unexpected field"))
        case "prewarm": return only(["cmd"]) ? .success(.prewarm) : .failure(ParseError("unexpected field"))
        case "yield":
            guard only(["cmd", "seconds"]) else { return .failure(ParseError("unexpected field")) }
            if json["seconds"] == nil { return .success(.yield(seconds: nil)) }
            guard let seconds = json["seconds"] as? Double, seconds >= 1, seconds <= 86_400 else { return .failure(ParseError("yield seconds must be 1...86400")) }
            return .success(.yield(seconds: seconds))
        case "hold":
            guard only(["cmd", "enabled"]), let enabled = json["enabled"] as? Bool else { return .failure(ParseError("hold requires boolean enabled")) }
            return .success(.hold(enabled))
        case "set_ambient":
            guard only(["cmd", "mode", "level", "focus"]), let mode = json["mode"] as? String, ["nc", "ambient", "off"].contains(mode), let level = json["level"] as? Int, (1...20).contains(level), let focus = json["focus"] as? Bool else { return .failure(ParseError("set_ambient requires mode nc|ambient|off, level 1...20, and boolean focus")) }
            return .success(.setAmbient(mode: mode, level: level, focus: focus))
        case "set_mode":
            guard only(["cmd", "mode"]), let mode = json["mode"] as? String, ["nc", "ambient", "off"].contains(mode) else { return .failure(ParseError("set_mode requires mode nc|ambient|off")) }
            return .success(.setMode(mode: mode))
        case "set_focus":
            // JSONSerialization bridges the numbers 1 and 1.0 to true through `as? Bool`;
            // only a JSON boolean has the CFBoolean type.
            guard only(["cmd", "enabled"]), let enabled = json["enabled"] as? Bool,
                  let raw = json["enabled"] as? NSNumber, CFGetTypeID(raw) == CFBooleanGetTypeID() else {
                return .failure(ParseError("set_focus requires boolean enabled"))
            }
            return .success(.setFocus(enabled: enabled))
        case "set_ambient_level":
            // A JSON boolean also bridges to the Int 1; reject it by CF type, as
            // set_bgm_room_size does.
            guard only(["cmd", "level"]), let number = json["level"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let level = Int(exactly: number.doubleValue), (1...20).contains(level) else {
                return .failure(ParseError("set_ambient_level requires level 1...20"))
            }
            return .success(.setAmbientLevel(level: level))
        case "set_eq_preset":
            guard only(["cmd", "code"]), let code = json["code"] as? Int, (0...255).contains(code) else { return .failure(ParseError("set_eq_preset requires byte code")) }
            return .success(.setEQPreset(code: UInt8(code)))
        case "set_eq_bands":
            guard only(["cmd", "bands"]), let bands = json["bands"] as? [Int], bands.count == SonyCommands.defaultBandCount, bands.allSatisfy({ SonyCommands.bandGainRange.contains($0) }) else { return .failure(ParseError("set_eq_bands requires ten integers in -6...6")) }
            return .success(.setEQBands(bands))
        case "set_listening_mode":
            guard only(["cmd", "mode"]), let mode = json["mode"] as? String,
                  ["standard", "backgroundMusic", "cinema"].contains(mode) else {
                return .failure(ParseError("set_listening_mode requires mode standard|backgroundMusic|cinema"))
            }
            return .success(.setListeningMode(mode: mode))
        case "set_bgm_room_size":
            // JSONSerialization bridges JSON booleans to NSNumber, which can also
            // bridge to Int.  Reject it by CF type rather than accidentally treating
            // `true` as the valid raw value 1 (Living Room).
            guard only(["cmd", "roomSize"]), let number = json["roomSize"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue,
                  number.doubleValue >= 0, number.doubleValue <= 255,
                  let value = Int(exactly: number.int64Value),
                  BGMRoomSize(rawValue: UInt8(value)) != nil else {
                return .failure(ParseError("set_bgm_room_size requires BGM room size 0|1|2"))
            }
            return .success(.setBGMRoomSize(rawValue: UInt8(value)))
        case "set_stc":
            guard only(["cmd", "enabled"]), let enabled = json["enabled"] as? Bool else { return .failure(ParseError("set_stc requires boolean enabled")) }
            return .success(.setSTC(enabled))
        case "switch_playback":
            guard only(["cmd", "mac"]), let macAddress = json["mac"] as? String, isCanonicalMAC(macAddress) else {
                return .failure(ParseError("switch_playback requires canonical uppercase MAC XX:XX:XX:XX:XX:XX"))
            }
            return .success(.switchPlayback(macAddress: macAddress))
        default: return .failure(ParseError("unknown command: \(command)"))
        }
    }
}
