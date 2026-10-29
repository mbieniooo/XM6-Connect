import Foundation
import Combine

public enum PopoverLayout {
    public static let popoverWidth: CGFloat = 350
    public static let topInset: CGFloat = 10
    public static let outerPadding: CGFloat = 14
    public static let cardPadding: CGFloat = 12
    public static let eqBandCount = 10
    public static let eqBandColumnWidth: CGFloat = 25
    public static let eqBandSpacing: CGFloat = 3
    public static let eqSliderHeight: CGFloat = 100

    public static func eqRowWidth(
        columnWidth: CGFloat = eqBandColumnWidth,
        spacing: CGFloat = eqBandSpacing,
        count: Int = eqBandCount
    ) -> CGFloat {
        CGFloat(count) * columnWidth + CGFloat(max(0, count - 1)) * spacing
    }

    public static var eqCardTotalWidth: CGFloat {
        eqRowWidth() + (2 * cardPadding) + (2 * outerPadding)
    }
}
import CoreFoundation
#if canImport(SonyHeadphonesKit)
import SonyHeadphonesKit
#endif
#if canImport(Darwin)
import Darwin
#endif

public struct AppAmbient: Codable, Equatable, Sendable {
    public var mode: String; public var level: Int; public var focus: Bool; public var subtype: Int
    public init(mode: String, level: Int, focus: Bool, subtype: Int) { self.mode = mode; self.level = level; self.focus = focus; self.subtype = subtype }
}
public struct AppBattery: Codable, Equatable, Sendable { public var level: Int; public var charging: Bool; public init(level: Int, charging: Bool) { self.level = level; self.charging = charging } }
public struct AppEqualizer: Codable, Equatable, Sendable { public var presetCode: Int; public var bands: [Int]; public var subtype: Int; public init(presetCode: Int, bands: [Int], subtype: Int) { self.presetCode = presetCode; self.bands = bands; self.subtype = subtype } }
public struct AppDevice: Codable, Equatable, Sendable {
    public var macAddress: String
    public var name: String
    public var connected: Bool
    public var playback: Bool
    public init(macAddress: String = "", name: String, connected: Bool, playback: Bool) {
        self.macAddress = macAddress; self.name = name; self.connected = connected; self.playback = playback
    }
}

/// Presentation-only rows derived from the agent's authoritative multipoint list.
/// `isActionable` makes disconnected devices visibly unavailable without letting
/// SwiftUI's button state become an implicit authorization policy.
public struct PopoverMultipointRow: Equatable, Sendable, Identifiable {
    public var macAddress: String
    public var name: String
    public var connected: Bool
    public var isPlayback: Bool
    public var id: String { macAddress }
    public var isActionable: Bool { connected && !isPlayback }
}
public struct AppState: Codable, Equatable, Sendable {
    public var connectionStatus: String; public var deviceName: String?; public var ambient: AppAmbient?
    public var battery: AppBattery?; public var equalizer: AppEqualizer?; public var speakToChat: Bool?
    public var multipoint: [AppDevice]?; public var listeningMode: String?; public var bgmRoomSize: Int?
    /// The headset-report time lets a locally-pending picker ignore the synchronous
    /// command reply, which is necessarily a snapshot from before the write.
    public var stateAsOf: Date?; public var lastError: String?
    public init(connectionStatus: String = "disconnected", deviceName: String? = nil, ambient: AppAmbient? = nil,
                battery: AppBattery? = nil, equalizer: AppEqualizer? = nil, speakToChat: Bool? = nil,
                multipoint: [AppDevice]? = nil, listeningMode: String? = nil, bgmRoomSize: Int? = nil,
                stateAsOf: Date? = nil, lastError: String? = nil) {
        self.connectionStatus = connectionStatus; self.deviceName = deviceName; self.ambient = ambient
        self.battery = battery; self.equalizer = equalizer; self.speakToChat = speakToChat
        self.multipoint = multipoint; self.listeningMode = listeningMode; self.bgmRoomSize = bgmRoomSize
        self.stateAsOf = stateAsOf; self.lastError = lastError
    }
}
public struct AppReply: Codable, Equatable, Sendable {
    public var state: AppState
    public var error: String?
    public var stale: Bool
    public init(state: AppState, error: String? = nil, stale: Bool = false) { self.state = state; self.error = error; self.stale = stale }
    private enum CodingKeys: String, CodingKey { case state, error, stale }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(AppState.self, forKey: .state)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        stale = try values.decodeIfPresent(Bool.self, forKey: .stale) ?? false
    }
}

public enum AppMode: String, CaseIterable, Sendable { case nc, ambient, off }
public enum AppCommand: Equatable, Sendable {
    case status, reconnect, cycle, setMode(AppMode), setFocus(Bool), setAmbientLevel(Int)
    case setEQPreset(Int), setEQBands([Int]), setSTC(Bool), switchPlayback(macAddress: String)
    case setListeningMode(ListeningMode), setBGMRoomSize(UInt8)

    /// Shared command construction for popover controls and validated widget URLs.
    /// The URL receiver passes only a known finite action; it never derives a command
    /// from a raw URL component. A mode change carries only the mode: the agent takes
    /// level and focus from the headset's report in the session that sends it.
    public static func command(for action: XM6ConnectDarwinNotification.Action) -> AppCommand {
        switch action {
        // Prewarm is agent-only advisory traffic and is deliberately absent from the
        // URL action surface. Keep this total switch defensive if another caller
        // passes it directly.
        case .prewarm:
            return .status
        case .cycle:
            return .cycle
        case .noiseCancelling:
            return .setMode(.nc)
        case .ambient:
            return .setMode(.ambient)
        case .off:
            return .setMode(.off)
        case .equalizer(let preset):
            return .setEQPreset(Int(preset.rawValue))
        }
    }
}

public enum AppRequestEncoder {
    public static func data(for command: AppCommand) throws -> Data {
        var object: [String: Any] = [:]
        switch command {
        case .status: object = ["cmd":"status"]
        case .reconnect: object = ["cmd":"reconnect"]
        case .cycle: object = ["cmd":"cycle"]
        case let .setMode(mode): object = ["cmd":"set_mode", "mode":mode.rawValue]
        case let .setFocus(enabled): object = ["cmd":"set_focus", "enabled":enabled]
        case let .setAmbientLevel(level): object = ["cmd":"set_ambient_level", "level":max(1, min(20, level))]
        case let .setEQPreset(code): object = ["cmd":"set_eq_preset", "code":max(0, min(255, code))]
        case let .setEQBands(bands): object = ["cmd":"set_eq_bands", "bands":bands.map { max(-6, min(6, $0)) }]
        case let .setSTC(enabled): object = ["cmd":"set_stc", "enabled":enabled]
        case let .switchPlayback(macAddress): object = ["cmd":"switch_playback", "mac":macAddress]
        case let .setListeningMode(mode): object = ["cmd":"set_listening_mode", "mode":mode.rawValue]
        case let .setBGMRoomSize(rawValue): object = ["cmd":"set_bgm_room_size", "roomSize":Int(rawValue)]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

public enum SocketClientError: Error, Equatable { case timeout, unavailable, malformedReply }

public enum PlaceholderAction: Equatable, Sendable {
    case reconnect
    case startAgent
    case enableLoginItem

    public var title: String {
        switch self {
        case .reconnect: return "Reconnect"
        case .startAgent: return "Start agent"
        case .enableLoginItem: return "Turn on"
        }
    }

    public static func `for`(socketUnreachable: Bool, agentJob: AgentJobState) -> PlaceholderAction {
        guard socketUnreachable else { return .reconnect }
        switch agentJob {
        case .stale, .absent: return .enableLoginItem
        case .loaded, .plistOnly: return .startAgent
        case .unknown: return .reconnect
        }
    }
}

public protocol AppSocketTransport: Sendable { func request(_ request: Data) async throws -> Data }

public struct UnixAppSocketTransport: AppSocketTransport {
    public let path: String
    private let afterInstallForTesting: (@Sendable (Int32) -> Void)?
    private static let ioQueue = DispatchQueue(label: "io.github.mbieniooo.xm6connect.app-socket", qos: .utility)
    public init(path: String = XM6ConnectPaths.agentSocketPath(), afterInstallForTesting: (@Sendable (Int32) -> Void)? = nil) {
        self.path = path
        self.afterInstallForTesting = afterInstallForTesting
    }
    public func request(_ request: Data) async throws -> Data {
        let operation = SocketOperation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                Self.ioQueue.async {
                    do { continuation.resume(returning: try Self.blockingRequest(request, path: self.path, operation: operation, afterInstallForTesting: self.afterInstallForTesting)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { operation.cancel() })
    }
    private static func blockingRequest(_ request: Data, path: String, operation: SocketOperation, afterInstallForTesting: (@Sendable (Int32) -> Void)?) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { throw SocketClientError.unavailable }
        let installed = operation.install(fd)
        afterInstallForTesting?(fd)
        guard installed else { throw SocketClientError.timeout }
        defer { operation.finish() }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)); _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard let connected = withUnixSocketAddress(path, { connect(fd, $0, $1) }) else { throw SocketClientError.unavailable }
        guard connected == 0 else { throw SocketClientError.unavailable }
        guard !operation.isCancelled else { throw SocketClientError.timeout }
        guard Self.writeLine(request, to: fd) else { throw SocketClientError.unavailable }
        var reply = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        while reply.count <= 64 * 1024 { let count = Darwin.read(fd, &chunk, chunk.count); if count <= 0 { break }; reply.append(chunk, count: count); if reply.contains(0x0a) { break } }
        guard let end = reply.firstIndex(of: 0x0a), end > 0 else { throw SocketClientError.timeout }
        return Data(reply[..<end])
    }
    /// One write preserves IPC line atomicity and returns failure rather than SIGPIPE.
    @discardableResult public static func writeLine(_ request: Data, to fd: Int32) -> Bool {
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var line = request; line.append(0x0a)
        return line.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            return Darwin.send(fd, base, bytes.count, Int32(MSG_NOSIGNAL)) == bytes.count
        }
    }
}

private final class SocketOperation: @unchecked Sendable {
    private let lock = NSLock(); private var fd: Int32 = -1; private var cancelled = false
    func install(_ fd: Int32) -> Bool {
        lock.lock()
        if cancelled { lock.unlock(); _ = Darwin.close(fd); return false }
        self.fd = fd; lock.unlock(); return true
    }
    func cancel() {
        lock.lock(); cancelled = true
        if fd >= 0 { _ = shutdown(fd, SHUT_RDWR) }
        lock.unlock()
    }
    func finish() {
        lock.lock(); let value = fd; fd = -1; lock.unlock()
        if value >= 0 { _ = Darwin.close(value) }
    }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public actor SocketClient {
    private let transport: any AppSocketTransport
    public init(transport: any AppSocketTransport = UnixAppSocketTransport()) { self.transport = transport }
    public func request(_ command: AppCommand) async throws -> AppReply {
        let data = try AppRequestEncoder.data(for: command)
        let replyData = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.transport.request(data) }
            group.addTask { try await Task.sleep(nanoseconds: 5_000_000_000); throw SocketClientError.timeout }
            defer { group.cancelAll() }; return try await group.next()!
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let reply = try? decoder.decode(AppReply.self, from: replyData) else { throw SocketClientError.malformedReply }
        return reply
    }
}

public enum PopoverConnection: Equatable, Sendable { case connected, disconnected(message: String) }
public struct PopoverViewState: Equatable, Sendable {
    public var connection: PopoverConnection; public var mode: AppMode?; public var ambientLevel: Int; public var focusOnVoice: Bool
    public var batteryLevel: Int?; public var charging: Bool; public var preset: EqualizerPreset?; public var bands: [Int]
    public var speakToChat: Bool?; public var devices: [AppDevice]; public var multipointRows: [PopoverMultipointRow]
    public var listeningMode: ListeningMode?; public var pendingListeningMode: ListeningMode?; public var bgmRoomSize: BGMRoomSize?
    public var commandError: String?; public var agentReachable: Bool
    public init(state: AppState = AppState()) { connection = .disconnected(message: "Connecting to agent…"); mode = nil; ambientLevel = 1; focusOnVoice = false; batteryLevel = nil; charging = false; preset = nil; bands = Array(repeating: 0, count: 10); speakToChat = nil; devices = []; multipointRows = []; listeningMode = nil; pendingListeningMode = nil; bgmRoomSize = nil; commandError = nil; agentReachable = false }
    /// The placeholder names the disconnected reason the agent gave, or the app's own
    /// reason when the agent cannot be reached.
    public var placeholderTitle: String {
        if case .disconnected(let message) = connection { return message }
        return "Waiting for the headset's report"
    }
    public var placeholderDetail: String? { agentReachable ? nil : "XM6-Connect will show controls when the agent is reachable." }
    /// True once the headset has reported anything. The lease means "released" is the
    /// RESTING state, not an error: rendering the placeholder for it left the popover
    /// empty nearly all the time.
    public var hasDeviceState: Bool { mode != nil || batteryLevel != nil || preset != nil || listeningMode != nil }
    public var ambientSliderEnabled: Bool { mode == .ambient }
    public var eqBandsEnabled: Bool { preset == .custom }
    /// The headset applies focus on voice only in Ambient; elsewhere it reports it off.
    public var focusToggleEnabled: Bool { mode == .ambient }
    public var stcToggleEnabled: Bool { speakToChat != nil }
    /// The visible selection may be locally pending for the approximately one-second
    /// headset round trip; `listeningMode` itself remains report-only.
    public var selectedListeningMode: ListeningMode? { pendingListeningMode ?? listeningMode }
    public var bgmRoomSizeEnabled: Bool { listeningMode == .backgroundMusic }
}

@MainActor public final class PopoverModel: ObservableObject {
    @Published public private(set) var viewState = PopoverViewState()
    @Published public private(set) var actionIsTakingTime = false
    @Published public private(set) var socketUnreachable = false
    public private(set) var lastSnapshot = AppState()
    public var onCommand: ((AppCommand) -> Void)?
    private var ambientWork: DispatchWorkItem?; private var bandWork: DispatchWorkItem?; private var actionWaitWork: DispatchWorkItem?; private var pendingWriteWork: DispatchWorkItem?
    private var pendingListeningModeStateAsOf: Date?
    private var pendingMode: AppMode?; private var pendingFocus: Bool?; private var pendingAmbientLevel: Int?; private var pendingPreset: EqualizerPreset?
    private var pendingBands: [Int]?; private var pendingSpeakToChat: Bool?; private var pendingPlaybackMAC: String?
    private var commandIsPending = false; private var commandBaseline: Date?
    private let pendingWriteCap: TimeInterval
    public init(pendingWriteCap: TimeInterval = 10) { self.pendingWriteCap = pendingWriteCap }
    /// Command replies and status replies take the same path: a stale command reply
    /// (the agent's state from before the device write) never ends a pending edit or
    /// the action wait, so `command` does not change how the reply is applied.
    public func handle(_ reply: AppReply, for command: AppCommand) {
        apply(reply)
    }
    public func apply(_ reply: AppReply) {
        socketUnreachable = false
        let previousStateAsOf = lastSnapshot.stateAsOf
        let previousCommandError = viewState.commandError
        let pendingListeningMode = viewState.pendingListeningMode
        let isNewerReport: Bool
        if let previousStateAsOf { isNewerReport = reply.state.stateAsOf.map { $0 > previousStateAsOf } ?? false }
        else { isNewerReport = reply.state.stateAsOf != nil }
        lastSnapshot = reply.state
        var mapped = Self.map(reply.state, error: reply.error)
        // An error stays until a newer headset report or the next write command.
        mapped.commandError = reply.error ?? (isNewerReport ? nil : previousCommandError)
        // A rejected command ends every pending edit. A "failed" or "disconnected" status
        // does not: the agent keeps queued writes across a failed acquisition and retries
        // them, so the edits wait for a matching report, an error, a socket error or the cap.
        // The listening-mode selection keeps its own rule and is dropped on such a status.
        let cannotHaveLanded = ["failed", "disconnected"].contains(reply.state.connectionStatus)
        if reply.error != nil {
            clearPendingEdits()
            cancelPendingWriteCap()
            viewState = mapped
            finishActionWait()
            return
        }
        if let pendingListeningMode {
            let baseline = pendingListeningModeStateAsOf
            let listeningReportIsNew: Bool
            if let baseline { listeningReportIsNew = !reply.stale && (reply.state.stateAsOf.map { $0 > baseline } ?? false) }
            else { listeningReportIsNew = !reply.stale && reply.state.stateAsOf != nil }
            if listeningReportIsNew || cannotHaveLanded { pendingListeningModeStateAsOf = nil }
            else { mapped.pendingListeningMode = pendingListeningMode }
        }
        if !reply.stale { resolvePendingEdits(with: mapped) }
        // A command that edits no field ends with the first headset report newer than the
        // snapshot it was sent against.
        if commandIsPending, !reply.stale, let asOf = reply.state.stateAsOf, commandBaseline.map({ asOf > $0 }) ?? true {
            commandIsPending = false; commandBaseline = nil
        }
        preservePendingEdits(in: &mapped)
        viewState = mapped
        if !reply.stale && !hasPendingWrites {
            cancelPendingWriteCap()
            finishActionWait()
        }
    }
    public func apply(error: Error) {
        socketUnreachable = (error as? SocketClientError) == .unavailable
        clearPendingEdits()
        cancelPendingWriteCap()
        finishActionWait()
        viewState = PopoverViewState()
        viewState.connection = .disconnected(message: error is SocketClientError ? "Agent not running" : "Unable to read agent state")
    }
    public static func map(_ state: AppState, error: String? = nil) -> PopoverViewState {
        var result = PopoverViewState()
        result.agentReachable = true
        switch state.connectionStatus {
        case "connected": result.connection = .connected
        case "released": result.connection = .disconnected(message: "Controls released to your phone")
        case "yielded": result.connection = .disconnected(message: "Controls yielded to another app")
        case "connecting", "searching", "initializing": result.connection = .disconnected(message: "Connecting to headphones")
        case "failed": result.connection = .disconnected(message: error ?? state.lastError ?? "Unable to connect to headphones")
        default: result.connection = .disconnected(message: error ?? state.lastError ?? "Headphones not connected")
        }
        if let a = state.ambient { result.mode = AppMode(rawValue: a.mode); result.ambientLevel = max(1, min(20, a.level)); result.focusOnVoice = a.focus }
        if let b = state.battery { result.batteryLevel = b.level; result.charging = b.charging }
        if let eq = state.equalizer { result.preset = UInt8(exactly: eq.presetCode).flatMap(EqualizerPreset.init(rawValue:)) ?? .custom; result.bands = eq.bands.count == 10 ? eq.bands : Array(repeating: 0, count: 10) }
        // An unknown wire string or room code stays unselected rather than defaulting.
        result.listeningMode = state.listeningMode.flatMap(ListeningMode.init(rawValue:))
        result.bgmRoomSize = state.bgmRoomSize.flatMap { UInt8(exactly: $0).flatMap(BGMRoomSize.init(rawValue:)) }
        result.speakToChat = state.speakToChat
        result.devices = state.multipoint ?? []
        // A device report should have one source.  If malformed data claims more
        // than one, present only the first as current rather than misleadingly
        // marking several rows; the next authoritative report reconciles it.
        var foundPlayback = false
        result.multipointRows = result.devices.map { device in
            let isPlayback = device.playback && !foundPlayback
            foundPlayback = foundPlayback || device.playback
            return PopoverMultipointRow(macAddress: device.macAddress, name: device.name, connected: device.connected, isPlayback: isPlayback)
        }
        return result
    }
    public func send(_ command: AppCommand) {
        if command != .status {
            viewState.commandError = nil
            if !Self.recordsFieldEdit(command) { commandIsPending = true; commandBaseline = lastSnapshot.stateAsOf; armPendingWriteCap() }
            beginActionWait()
        }
        onCommand?(command)
    }
    /// Deliberately delayed so normal 0.1–0.4 second warm actions do not flicker;
    /// after that threshold the existing lease-status line can honestly say work is
    /// in flight rather than leaving the popover silently inert.
    public func beginActionWait() {
        actionWaitWork?.cancel(); actionIsTakingTime = false
        let work = DispatchWorkItem { [weak self] in self?.actionIsTakingTime = true }
        actionWaitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400), execute: work)
    }
    public func finishActionWait() {
        actionWaitWork?.cancel(); actionWaitWork = nil; actionIsTakingTime = false
    }
    /// The commands whose model method records a pending field edit; every other write is
    /// bounded by its own newer report or the cap.
    private static func recordsFieldEdit(_ command: AppCommand) -> Bool {
        switch command {
        case .setMode, .setFocus, .setAmbientLevel, .setEQPreset, .setEQBands, .setSTC, .switchPlayback: return true
        case .status, .reconnect, .cycle, .setListeningMode, .setBGMRoomSize: return false
        }
    }
    private var hasPendingWrites: Bool {
        commandIsPending || viewState.pendingListeningMode != nil || pendingMode != nil || pendingFocus != nil || pendingAmbientLevel != nil || pendingPreset != nil || pendingBands != nil || pendingSpeakToChat != nil || pendingPlaybackMAC != nil
    }
    private func resolvePendingEdits(with mapped: PopoverViewState) {
        if let pendingMode, mapped.mode == pendingMode { self.pendingMode = nil }
        if let pendingFocus, mapped.focusOnVoice == pendingFocus { self.pendingFocus = nil }
        if let pendingAmbientLevel, mapped.ambientLevel == pendingAmbientLevel { self.pendingAmbientLevel = nil }
        if let pendingPreset, mapped.preset == pendingPreset { self.pendingPreset = nil }
        if let pendingBands, mapped.bands == pendingBands { self.pendingBands = nil }
        if let pendingSpeakToChat, mapped.speakToChat == pendingSpeakToChat { self.pendingSpeakToChat = nil }
        if let pendingPlaybackMAC, mapped.multipointRows.contains(where: { $0.macAddress == pendingPlaybackMAC && $0.isPlayback }) { self.pendingPlaybackMAC = nil }
    }
    private func preservePendingEdits(in mapped: inout PopoverViewState) {
        if let pendingMode { mapped.mode = pendingMode }
        if let pendingFocus { mapped.focusOnVoice = pendingFocus }
        if let pendingAmbientLevel { mapped.ambientLevel = pendingAmbientLevel }
        if let pendingPreset { mapped.preset = pendingPreset }
        if let pendingBands { mapped.bands = pendingBands }
        if let pendingSpeakToChat { mapped.speakToChat = pendingSpeakToChat }
        if let pendingPlaybackMAC {
            mapped.multipointRows = mapped.multipointRows.map { row in
                var row = row; row.isPlayback = row.macAddress == pendingPlaybackMAC; return row
            }
        }
    }
    private func clearPendingEdits() {
        pendingMode = nil; pendingFocus = nil; pendingAmbientLevel = nil; pendingPreset = nil; pendingBands = nil; pendingSpeakToChat = nil; pendingPlaybackMAC = nil
        pendingListeningModeStateAsOf = nil; commandIsPending = false; commandBaseline = nil
    }
    private func cancelPendingWriteCap() {
        pendingWriteWork?.cancel(); pendingWriteWork = nil
    }
    private func armPendingWriteCap() {
        cancelPendingWriteCap()
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard !work.isCancelled, let self else { return }
            let commandError = self.viewState.commandError
            self.clearPendingEdits()
            self.viewState = Self.map(self.lastSnapshot)
            self.viewState.commandError = commandError
            self.pendingWriteWork = nil
            self.finishActionWait()
        }
        pendingWriteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingWriteCap, execute: work)
    }
    public func switchPlayback(to row: PopoverMultipointRow) {
        guard row.isActionable else { return }
        // Optimistic UI is intentionally local.  `apply(_:)` always replaces these
        // rows with the headset-reported list, so it cannot become a second source
        // of truth if the headset declines or changes the request.
        viewState.multipointRows = viewState.multipointRows.map { value in
            var value = value; value.isPlayback = value.macAddress == row.macAddress; return value
        }
        pendingPlaybackMAC = row.macAddress
        armPendingWriteCap()
        send(.switchPlayback(macAddress: row.macAddress))
    }
    public func selectListeningMode(_ mode: ListeningMode) {
        guard viewState.selectedListeningMode != mode else { return }
        viewState.pendingListeningMode = mode
        pendingListeningModeStateAsOf = lastSnapshot.stateAsOf
        send(.setListeningMode(mode))
    }
    public func selectBGMRoomSize(_ roomSize: BGMRoomSize) {
        guard viewState.bgmRoomSizeEnabled, viewState.bgmRoomSize != roomSize else { return }
        send(.setBGMRoomSize(roomSize.rawValue))
    }
    public func selectMode(_ mode: AppMode) { viewState.mode = mode; pendingMode = mode; armPendingWriteCap(); send(.setMode(mode)) }
    public func setFocus(_ enabled: Bool) { viewState.focusOnVoice = enabled; pendingFocus = enabled; armPendingWriteCap(); send(.setFocus(enabled)) }
    public func settleAmbientLevel(_ level: Int) { let level = max(1, min(20, level)); viewState.ambientLevel = level; pendingAmbientLevel = level; armPendingWriteCap(); ambientWork?.cancel(); var work: DispatchWorkItem!; work = DispatchWorkItem { [weak self] in guard !work.isCancelled else { return }; self?.send(.setAmbientLevel(level)) }; ambientWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work) }
    /// A preset write replaces a pending band edit: the agent keeps only the newest
    /// equalizer write, and a late band send would switch the headset back to Custom.
    public func selectPreset(_ preset: EqualizerPreset) { bandWork?.cancel(); pendingBands = nil; viewState.preset = preset; pendingPreset = preset; armPendingWriteCap(); send(.setEQPreset(Int(preset.rawValue))) }
    public func setSpeakToChat(_ enabled: Bool) { viewState.speakToChat = enabled; pendingSpeakToChat = enabled; armPendingWriteCap(); send(.setSTC(enabled)) }
    public func settleBands(_ bands: [Int]) { bandWork?.cancel(); var values = bands; values = Array(values.prefix(10)); while values.count < 10 { values.append(0) }; let work = DispatchWorkItem { [weak self] in self?.send(.setEQBands(values)) }; bandWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work) }
    public func editBand(_ index: Int, value: Int) { var bands = viewState.bands; guard bands.indices.contains(index) else { return }; bands[index] = max(-6, min(6, value)); viewState.bands = bands; viewState.preset = .custom; pendingBands = bands; pendingPreset = .custom; armPendingWriteCap(); settleBands(bands) }
}
