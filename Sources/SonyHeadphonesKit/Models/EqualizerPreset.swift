import Foundation
import Darwin
import CoreFoundation

public func withUnixSocketAddress<R>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

public final class DarwinObserver {
    private let callback: (String) -> Void
    public init(names: [String], callback: @escaping (String) -> Void) {
        self.callback = callback
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        for name in names {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), pointer, { _, observer, notification, _, _ in
                guard let observer, let notification else { return }
                let target = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                let receivedName = notification.rawValue as String
                DispatchQueue.main.async { target.callback(receivedName) }
            }, name as CFString, nil, .deliverImmediately)
        }
    }
    deinit { CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), nil, nil) }
}

/// Equalizer presets accepted by WH-1000XM6 firmware (3.0.0+).
///
/// The XM6 generation dropped the classic preset table: firmware only accepts the new
/// codes 0x30-0x33 plus Custom (0xA0) and Off. These names match Sony's Sound Connect app.
public enum EqualizerPreset: UInt8, CaseIterable, Sendable, Identifiable {
    case off = 0x00
    // Captured live from a WH-1000XM6 (fw 3.1.5) after setting "Game" in Sony's app:
    // the headset reports preset 0x20 (bands observed: -6,-2,2,3,1,-1,1,3,0,-2).
    case game = 0x20
    case heavy = 0x30
    case clear = 0x31
    case hard = 0x32
    case soft = 0x33
    case custom = 0xa0

    public var id: UInt8 { rawValue }

    public var label: String {
        switch self {
        case .off: return "Off"
        case .game: return "Game"
        case .heavy: return "Heavy"
        case .clear: return "Clear"
        case .hard: return "Hard"
        case .soft: return "Soft"
        case .custom: return "Custom"
        }
    }
}

/// Locations the agent, the app, the widget and `xm6ctl` share under the real user home.
public enum XM6ConnectPaths {
    /// The agent-owned application-support directory, relative to the real user home.
    public static let agentSupportDirectoryRelativePath = "Library/Application Support/XM6Connect"

    /// The agent's Unix-domain socket under `homeDirectory`. The default is the current user's
    /// home; the sandboxed widget resolves the real home itself and never uses the default.
    public static func agentSocketPath(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        homeDirectory
            .appendingPathComponent(agentSupportDirectoryRelativePath, isDirectory: true)
            .appendingPathComponent("agent.sock")
            .path
    }
}

/// The finite Darwin-notification command surface shared by the sandboxed widget
/// extension and the resident agent.  It lives beside `EqualizerPreset` so a newly
/// added preset automatically acquires a notification name everywhere it is used.
/// Neither the widget nor the agent needs a socket/file-write entitlement for these
/// actions.
public enum XM6ConnectDarwinNotification {
    /// The agent's observer: every agent action name in `namespace`, decoded and handed on.
    public static func agentActionObserver(namespace: String = productionNamespace, _ handler: @escaping (Action) -> Void) -> DarwinObserver {
        DarwinObserver(names: agentActions.map { name(for: $0, namespace: namespace) }) { name in
            guard let action = agentAction(for: name, namespace: namespace) else { return }
            handler(action)
        }
    }
    public enum Action: Hashable, Sendable {
        case prewarm
        case cycle
        case noiseCancelling
        case ambient
        case off
        case equalizer(EqualizerPreset)
    }

    public static let actionURLScheme = "xm6connect"
    public static let actionURLHost = "action"
    /// Darwin permits any process with this effective UID to use this namespace,
    /// while preventing processes owned by other users from doing so.
    public static let productionNamespace = "user.uid.\(getuid()).io.github.mbieniooo.xm6connect."

    private static func notificationName(_ suffix: String, namespace: String = productionNamespace) -> String {
        namespace + suffix
    }

    private static func actionID(for action: Action?) -> String {
        switch action {
        case nil: return "statechanged"
        case .prewarm: return "prewarm"
        case .cycle: return "cycle"
        case .noiseCancelling: return "mode.nc"
        case .ambient: return "mode.ambient"
        case .off: return "mode.off"
        case .equalizer(let preset): return "eq.\(preset.label.lowercased())"
        }
    }

    public static let stateChanged = notificationName(actionID(for: nil))

    /// All command actions that the agent subscribes to.  The EQ portion is derived
    /// from `EqualizerPreset.allCases`, rather than maintaining a second code table.
    public static var commandActions: [Action] {
        [.cycle, .noiseCancelling, .ambient, .off] + EqualizerPreset.allCases.map(Action.equalizer)
    }

    /// Prewarm is intentionally not an URL-command action: it is an advisory intent
    /// signal from local UI surfaces, not a headset command. The resident agent is
    /// the only process that subscribes to this wider notification set.
    public static var agentActions: [Action] { [.prewarm] + commandActions }

    public static func name(for action: Action, namespace: String = productionNamespace) -> String {
        notificationName(actionID(for: action), namespace: namespace)
    }

    /// Decodes every notification the resident agent subscribes to, including prewarm.
    public static func agentAction(for name: String, namespace: String = productionNamespace) -> Action? {
        agentActions.first { self.name(for: $0, namespace: namespace) == name }
    }

    public static func url(for action: Action) -> URL {
        URL(string: "\(actionURLScheme)://\(actionURLHost)/\(actionID(for: action))")!
    }

    /// Strictly parse only URLs emitted by `url(for:)`.  This is an input boundary:
    /// raw URL text never becomes an action or a device command.
    public static func action(for url: URL) -> Action? {
        commandActions.first { self.url(for: $0).absoluteString == url.absoluteString }
    }
}

/// Decoded equalizer state.
public struct EqualizerState: Equatable, Sendable {
    /// Raw preset code as reported by the device. May be a value outside
    /// `EqualizerPreset` (e.g. a personalized/user preset id).
    public var presetCode: UInt8
    /// Raw band values as reported (10 bands on XM6, offset already removed).
    public var bands: [Int]
    /// The EQEBB inquired-type byte the device used (XM6: 0x04). Echoed on writes.
    public var subtype: UInt8

    public var preset: EqualizerPreset? { EqualizerPreset(rawValue: presetCode) }

    public init(presetCode: UInt8, bands: [Int] = [], subtype: UInt8 = 0x04) {
        self.presetCode = presetCode
        self.bands = bands
        self.subtype = subtype
    }
}
