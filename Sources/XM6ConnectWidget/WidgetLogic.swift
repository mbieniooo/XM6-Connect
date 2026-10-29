import Foundation
#if canImport(SonyHeadphonesKit)
import SonyHeadphonesKit
#endif

public enum XM6ConnectWidgetMode: String, Equatable, Sendable {
    case noiseCancelling = "nc"
    case ambient
    case off
}

public enum XM6ConnectWidgetLogic {
    /// The app's own symbol, used whenever no mode is known. The gallery renders a
    /// control with no state, so a mode glyph there would be misleading.

    public static func timelineDates(for model: XM6ConnectWidgetViewModel, now: Date) -> [Date] {
        guard let staleAt = model.staleAt, staleAt > now else { return [now] }
        return [now, staleAt]
    }
}

private struct Snapshot: Decodable {
    struct Ambient: Decodable { let mode: String }
    struct Battery: Decodable { let level: Int; let charging: Bool }
    struct Equalizer: Decodable { let presetCode: Int }
    let ambient: Ambient?
    let battery: Battery?
    let equalizer: Equalizer?
    let connectionStatus: String?
    let timestamp: Date?
    let stateAsOf: Date?
}

public enum XM6ConnectWidgetFreshness: Equatable, Sendable {
    case fresh
    case stale
    case unavailable
}

/// Pure representation used by the WidgetKit timeline and deterministic tests.
/// A stale snapshot retains its reported values so the UI can dim them honestly;
/// absent, corrupt, oversized, or implausibly-future data stays neutral.
public struct XM6ConnectWidgetViewModel: Equatable, Sendable {
    public var selectedMode: XM6ConnectWidgetMode?
    public var selectedPreset: EqualizerPreset?
    public var batteryLevel: Int?
    public var charging: Bool
    public var freshness: XM6ConnectWidgetFreshness
    public var staleAt: Date?

    public init(selectedMode: XM6ConnectWidgetMode? = nil, selectedPreset: EqualizerPreset? = nil, batteryLevel: Int? = nil, charging: Bool = false, freshness: XM6ConnectWidgetFreshness = .unavailable, staleAt: Date? = nil) {
        self.selectedMode = selectedMode; self.selectedPreset = selectedPreset
        self.batteryLevel = batteryLevel; self.charging = charging; self.freshness = freshness; self.staleAt = staleAt
    }

    public static let unavailable = XM6ConnectWidgetViewModel()
}

public enum XM6ConnectStateReader {
    public static let maximumStateFileBytes = 64 * 1024
    /// A state is stale when it is older than this or the agent reports a failed
    /// connection. Other connection statuses retain this age-based rule.
    public static let maximumAge: TimeInterval = 20 * 60

    public static func readViewModel(from url: URL, now: Date = Date()) -> XM6ConnectWidgetViewModel {
        let resolvedURL = url.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumStateFileBytes,
              let handle = try? FileHandle(forReadingFrom: resolvedURL) else { return .unavailable }
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? handle.read(upToCount: maximumStateFileBytes + 1),
              data.count <= maximumStateFileBytes,
              let snapshot = try? decoder.decode(Snapshot.self, from: data),
              let stateAsOf = snapshot.stateAsOf,
              now.timeIntervalSince(stateAsOf) >= -30 else { return .unavailable }
        let freshness: XM6ConnectWidgetFreshness = snapshot.connectionStatus == "failed" || now.timeIntervalSince(stateAsOf) > maximumAge ? .stale : .fresh
        let battery = snapshot.battery.flatMap { (0...100).contains($0.level) ? $0 : nil }
        let preset = snapshot.equalizer.flatMap { EqualizerPreset(rawValue: UInt8(exactly: $0.presetCode) ?? 0xff) }
        return XM6ConnectWidgetViewModel(
            selectedMode: snapshot.ambient.flatMap { XM6ConnectWidgetMode(rawValue: $0.mode) },
            selectedPreset: preset,
            batteryLevel: battery?.level,
            charging: battery?.charging ?? false,
            freshness: freshness,
            staleAt: freshness == .fresh ? stateAsOf.addingTimeInterval(maximumAge + 1) : nil
        )
    }

    public static func agentStateURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(XM6ConnectPaths.agentSupportDirectoryRelativePath, isDirectory: true)
            .appendingPathComponent("state.json")
    }

    public static func agentStateURL() -> URL? {
        guard let account = getpwuid(getuid()) else { return nil }
        return agentStateURL(homeDirectory: URL(fileURLWithPath: String(cString: account.pointee.pw_dir), isDirectory: true))
    }
}
