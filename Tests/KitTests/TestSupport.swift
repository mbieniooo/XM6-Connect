import Foundation
import SonyHeadphonesKit
import XM6ConnectAgentCore
import XM6ConnectAppLogic

let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func repositorySource(_ path: String) -> String? { try? String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8) }

final class FakeConnection: RFCOMMConnectionProviding {
    var onEvent: ((RFCOMMConnectionEvent) -> Void)?
    private(set) var writes: [[UInt8]] = []
    func clearWrites() { writes.removeAll() }

    func connect(toDeviceAddress address: String) {}
    func disconnect() {}
    func write(_ bytes: [UInt8]) { writes.append(bytes) }
    func emit(_ event: RFCOMMConnectionEvent) { onEvent?(event) }
}

@MainActor
final class FakeAgentController: AgentHeadphonesControlling {
    var onStateChanged: (() -> Void)?
    var value = AgentState()
    private(set) var connects: [(String, String?)] = []
    private(set) var disconnects = 0
    private(set) var refreshes = 0
    private(set) var ambientWrites: [AmbientSoundState] = []
    private(set) var equalizerPresetWrites: [(UInt8, UInt8)] = []
    private(set) var bandWrites: [([Int], UInt8)] = []
    private(set) var stcWrites: [Bool] = []
    private(set) var bgmRoomSizeWrites: [UInt8] = []
    private(set) var playbackWrites: [AgentMultipointDevice] = []
    private(set) var outboundEvents: [String] = []
    var pendingTransportFailure: RFCOMMConnectionFailureContext?
    private(set) var aclBounceCalls = 0
    func snapshot(address: String?) -> AgentState { var copy = value; copy.deviceAddress = address ?? copy.deviceAddress; return copy }
    func connect(address: String, name: String?) { connects.append((address, name)) }
    // SonyControllerBridge publishes its disconnect on the next main-loop turn.
    // Keep the fake deferred too; a synchronous fake hid intentional-release races.
    func disconnect() { disconnects += 1; value.connectionStatus = "disconnected" }
    func emitDeferredDisconnect() { onStateChanged?() }
    func refreshState() { refreshes += 1; outboundEvents.append("refresh") }
    func sendAmbient(_ state: AmbientSoundState) { ambientWrites.append(state); outboundEvents.append("ambient") }
    func sendEqualizerPreset(code: UInt8) { equalizerPresetWrites.append((code, 0x04)); outboundEvents.append("equalizer") }
    func sendEqualizerBands(_ bands: [Int]) { bandWrites.append((bands, 0x04)) }
    func sendSpeakToChat(_ enabled: Bool) { stcWrites.append(enabled); outboundEvents.append("stc") }
    private(set) var listeningModeWrites: [String] = []
    func setListeningMode(_ mode: String) { listeningModeWrites.append(mode); outboundEvents.append("listening") }
    func setBGMRoomSize(_ rawValue: UInt8) { bgmRoomSizeWrites.append(rawValue); outboundEvents.append("bgm-room") }
    func switchPlayback(to device: AgentMultipointDevice) { playbackWrites.append(device) }
    func consumeTransportFailure() -> RFCOMMConnectionFailureContext? {
        defer { pendingTransportFailure = nil }
        return pendingTransportFailure
    }
    func bounceACL() { aclBounceCalls += 1 }
    func emit(_ status: String? = nil) { if let status { value.connectionStatus = status }; onStateChanged?() }
}

@MainActor
final class FakeResolver: AgentDeviceResolving {
    var device: PairedDeviceInfo? = PairedDeviceInfo(id: "AA:BB", name: "WH-1000XM6", isConnected: true)
    func resolve(cachedAddress: String?) -> PairedDeviceInfo? { device }
}

@MainActor
final class FakeRetryScheduler: RetryScheduling {
    private(set) var delays: [TimeInterval] = []
    private var action: (() -> Void)?
    var isArmed: Bool { action != nil }
    var armedDelay: TimeInterval? { action == nil ? nil : delays.last }
    func schedule(after seconds: TimeInterval, action: @escaping () -> Void) { delays.append(seconds); self.action = action }
    func cancel() { action = nil }
    func fire() { let pending = action; action = nil; pending?() }
}

final class FakeStateWriter: StateWriting {
    private(set) var values: [AgentState] = []
    func write(_ state: AgentState) throws { values.append(state) }
}

@MainActor
func makeAgent(
    _ controller: FakeAgentController,
    _ scheduler: FakeRetryScheduler,
    _ writer: FakeStateWriter = FakeStateWriter(),
    now: @escaping () -> Date = Date.init,
    jitter: @escaping (TimeInterval) -> TimeInterval = { $0 },
    acquisitionScheduler: RetryScheduling? = nil,
    deviceMutationScheduler: RetryScheduling? = nil,
    resolver: FakeResolver? = nil,
    stateSnapshot: AgentStateSnapshot = AgentStateSnapshot(),
    stateReader: StateReading? = nil,
    configURL: URL? = nil
) -> XM6ConnectAgentCore {
    XM6ConnectAgentCore(
        controller: controller,
        resolver: resolver ?? FakeResolver(),
        scheduler: scheduler,
        writer: writer,
        configURL: configURL ?? URL(fileURLWithPath: "/tmp/xm6connect-kit-tests-config-\(UUID().uuidString).json"),
        stateSnapshot: stateSnapshot,
        now: now,
        jitter: jitter,
        stateReader: stateReader,
        acquisitionScheduler: acquisitionScheduler,
        deviceMutationScheduler: deviceMutationScheduler,
        stateChanged: {}
    )
}

final class LaunchctlRecorder: @unchecked Sendable {
    private let result: ([String]) -> Bool
    var calls: [[String]] = []
    init(result: @escaping ([String]) -> Bool = { _ in true }) { self.result = result }
    lazy var runner: LaunchctlRunner = { [self] arguments in run(arguments) }
    func run(_ arguments: [String]) -> Bool { calls.append(arguments); return result(arguments) }
}

func loginTestHome() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xm6connect-login-\(UUID().uuidString)", isDirectory: true)
}

func loginTestBundle(in home: URL) -> URL? {
    let bundle = home.appendingPathComponent("XM6-Connect.app", isDirectory: true)
    let agent = bundle.appendingPathComponent("Contents/MacOS/XM6ConnectAgent")
    do {
        try FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: agent)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)
        return bundle
    } catch { return nil }
}

func hexBytes(_ bytes: [UInt8]?) -> String {
    bytes.map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "nil"
}
