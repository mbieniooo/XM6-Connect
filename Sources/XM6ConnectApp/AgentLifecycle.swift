import Foundation
import Combine
#if canImport(Darwin)
import Darwin
#endif

public typealias LaunchctlRunner = @Sendable ([String]) -> Bool

public let systemLaunchctlRunner: LaunchctlRunner = { arguments in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

public enum LoginItemOutcome: Equatable, Sendable {
    case enabled
    case failed(reason: String)

    public var reason: String? {
        guard case .failed(let reason) = self else { return nil }
        return reason
    }
}

public enum LoginItemStatus: Equatable, Sendable {
    case disabled
    case stalePath
    case partial
    case enabled
    case enabledPendingLoad

    public var isEnabled: Bool {
        switch self {
        case .enabled, .enabledPendingLoad: return true
        case .disabled, .stalePath, .partial: return false
        }
    }

    public var caption: String {
        switch self {
        case .disabled: return "Off"
        case .stalePath: return "The app moved: turn this on to update it"
        case .partial: return "Only the agent starts at login: turn this on to start the app too"
        case .enabled: return "Starts XM6-Connect and its agent at login"
        case .enabledPendingLoad: return "Starts at next login"
        }
    }
}

public enum AgentJobState: Equatable, Sendable {
    case unknown
    case loaded
    case plistOnly
    case absent
    case stale
}

public enum LaunchAgentPlist {
    public static let label = "io.github.mbieniooo.xm6connect.agent"
    public static let plistName = "io.github.mbieniooo.xm6connect.agent.plist"
    public static let loginLabel = "io.github.mbieniooo.xm6connect.login"
    public static let loginPlistName = "io.github.mbieniooo.xm6connect.login.plist"
    public static let relativeAgentPath = "Contents/MacOS/XM6ConnectAgent"
    public static let associatedBundleIdentifiers = ["io.github.mbieniooo.xm6connect.app"]

    public static func dictionary(programArguments: [String]) -> [String: Any] {
        [
            "Label": label,
            "KeepAlive": true,
            "RunAtLoad": true,
            "ProgramArguments": programArguments,
            "AssociatedBundleIdentifiers": associatedBundleIdentifiers
        ]
    }

    public static func loginDictionary(bundleURL: URL) -> [String: Any] {
        [
            "Label": loginLabel,
            "RunAtLoad": true,
            "ProgramArguments": ["/usr/bin/open", "-g", bundleURL.path],
            "AssociatedBundleIdentifiers": associatedBundleIdentifiers
        ]
    }

    public static func serialized(programArguments: [String]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dictionary(programArguments: programArguments), format: .xml, options: 0)
    }

    public static func agentProgramArguments(bundleURL: URL) -> [String] {
        [bundleURL.appendingPathComponent(relativeAgentPath).path]
    }

    public static func agentPlistData(bundleURL: URL) throws -> Data {
        try serialized(programArguments: agentProgramArguments(bundleURL: bundleURL))
    }

    public static func serializedLogin(bundleURL: URL) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: loginDictionary(bundleURL: bundleURL), format: .xml, options: 0)
    }

    public static func printedPlist(arguments: [String], defaultBundlePath: String) -> Result<Data, Error>? {
        let flags = [("--print-agent-plist", { try agentPlistData(bundleURL: $0) }), ("--print-login-plist", { try serializedLogin(bundleURL: $0) })]
        guard let (index, serializer) = flags.compactMap({ flag, serializer in
            arguments.firstIndex(of: flag).map { ($0, serializer) }
        }).min(by: { $0.0 < $1.0 }) else { return nil }
        let path = arguments.indices.contains(index + 1) ? arguments[index + 1] : defaultBundlePath
        guard path.hasPrefix("/") else { return .failure(PrintedPlistError.relativeBundlePath) }
        return Result { try serializer(URL(fileURLWithPath: path)) }
    }

    private enum PrintedPlistError: Error {
        case relativeBundlePath
    }
}

public enum LaunchAgentController {
    public static func plistURL(homeDirectory: String = NSHomeDirectory()) -> URL {
        launchAgentsDirectory(homeDirectory: homeDirectory).appendingPathComponent(LaunchAgentPlist.plistName)
    }

    public static func loginPlistURL(homeDirectory: String = NSHomeDirectory()) -> URL {
        launchAgentsDirectory(homeDirectory: homeDirectory).appendingPathComponent(LaunchAgentPlist.loginPlistName)
    }

    public static func status(homeDirectory: String = NSHomeDirectory(), serviceLoaded: Bool? = nil, launchctl: LaunchctlRunner = systemLaunchctlRunner) -> LoginItemStatus {
        let agentURL = plistURL(homeDirectory: homeDirectory)
        let loginURL = loginPlistURL(homeDirectory: homeDirectory)
        let agentExists = FileManager.default.fileExists(atPath: agentURL.path)
        let loginExists = FileManager.default.fileExists(atPath: loginURL.path)
        guard agentExists || loginExists else { return .disabled }
        if (agentExists && !hasValidAgentTarget(at: agentURL)) || (loginExists && !hasValidLoginTarget(at: loginURL)) {
            return .stalePath
        }
        guard agentExists && loginExists else { return .partial }
        return (serviceLoaded ?? isServiceLoaded(launchctl: launchctl)) ? .enabled : .enabledPendingLoad
    }

    public static func agentJobState(homeDirectory: String, serviceLoaded: Bool) -> AgentJobState {
        let agentURL = plistURL(homeDirectory: homeDirectory)
        if FileManager.default.fileExists(atPath: agentURL.path), !hasValidAgentTarget(at: agentURL) { return .stale }
        if serviceLoaded { return .loaded }
        if FileManager.default.fileExists(atPath: agentURL.path) { return .plistOnly }
        return .absent
    }

    public static func start(homeDirectory: String = NSHomeDirectory(), launchctl: LaunchctlRunner = systemLaunchctlRunner, sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> LoginItemOutcome {
        let serviceLoaded = isServiceLoaded(launchctl: launchctl)
        switch agentJobState(homeDirectory: homeDirectory, serviceLoaded: serviceLoaded) {
        case .loaded:
            return launchctl(["kickstart", "gui/\(uid)/\(LaunchAgentPlist.label)"])
                ? .enabled : .failed(reason: "Could not start the agent")
        case .plistOnly:
            // launchctl bootstrap can exit non-zero yet load the job, and can fail once right
            // after a bootout while launchd is still removing the old instance. Whether the
            // job is loaded decides; a failed first attempt is retried once, as enable() does.
            let bootstrap = ["bootstrap", "gui/\(uid)", plistURL(homeDirectory: homeDirectory).path]
            _ = launchctl(bootstrap)
            if isServiceLoaded(launchctl: launchctl) { return .enabled }
            sleep(2.0)
            _ = launchctl(bootstrap)
            return isServiceLoaded(launchctl: launchctl)
                ? .enabled : .failed(reason: "Could not start the agent (launchctl bootstrap failed)")
        case .stale:
            return .failed(reason: "The agent path is stale")
        case .absent:
            return .failed(reason: "The agent is not installed")
        case .unknown:
            return .failed(reason: "The agent state is unknown")
        }
    }

    @discardableResult
    public static func enable(bundleURL: URL = Bundle.main.bundleURL, homeDirectory: String = NSHomeDirectory(), launchctl: LaunchctlRunner = systemLaunchctlRunner, sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> LoginItemOutcome {
        guard !bundleURL.path.contains("/AppTranslocation/") else {
            return .failed(reason: "Move XM6-Connect to Applications first")
        }
        let agentURL = plistURL(homeDirectory: homeDirectory)
        let loginURL = loginPlistURL(homeDirectory: homeDirectory)
        let agentArguments = LaunchAgentPlist.agentProgramArguments(bundleURL: bundleURL)
        if FileManager.default.fileExists(atPath: agentURL.path), programArguments(at: agentURL) != agentArguments {
            _ = launchctl(["bootout", "gui/\(uid)/\(LaunchAgentPlist.label)"])
        }
        do {
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LaunchAgentPlist.agentPlistData(bundleURL: bundleURL).write(to: agentURL, options: .atomic)
            try LaunchAgentPlist.serializedLogin(bundleURL: bundleURL).write(to: loginURL, options: .atomic)
        } catch {
            removePlists(agentURL: agentURL, loginURL: loginURL)
            return .failed(reason: "Could not write the login items")
        }
        let bootstrap = ["bootstrap", "gui/\(uid)", agentURL.path]
        if !launchctl(bootstrap) {
            if isServiceLoaded(launchctl: launchctl) { return .enabled }
            sleep(2.0)
            _ = launchctl(["bootout", "gui/\(uid)/\(LaunchAgentPlist.label)"])
            _ = launchctl(bootstrap)
        }
        guard isServiceLoaded(launchctl: launchctl) else {
            removePlists(agentURL: agentURL, loginURL: loginURL)
            return .failed(reason: "Could not start the agent (launchctl bootstrap failed)")
        }
        return .enabled
    }

    public static func disable(homeDirectory: String = NSHomeDirectory(), launchctl: LaunchctlRunner = systemLaunchctlRunner) {
        _ = launchctl
        removePlists(agentURL: plistURL(homeDirectory: homeDirectory), loginURL: loginPlistURL(homeDirectory: homeDirectory))
    }

    public static func unregister(homeDirectory: String = NSHomeDirectory(), launchctl: LaunchctlRunner = systemLaunchctlRunner) {
        _ = launchctl(["bootout", "gui/\(uid)/\(LaunchAgentPlist.label)"])
        _ = launchctl(["bootout", "gui/\(uid)/\(LaunchAgentPlist.loginLabel)"])
        removePlists(agentURL: plistURL(homeDirectory: homeDirectory), loginURL: loginPlistURL(homeDirectory: homeDirectory))
    }

    private static var uid: uid_t { getuid() }

    private static func launchAgentsDirectory(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library", isDirectory: true).appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    private static func programArguments(at url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["ProgramArguments"] as? [String]
    }

    private static func hasValidAgentTarget(at url: URL) -> Bool {
        guard let target = programArguments(at: url)?.first else { return false }
        return FileManager.default.isExecutableFile(atPath: target)
    }

    private static func hasValidLoginTarget(at url: URL) -> Bool {
        guard let arguments = programArguments(at: url), arguments.count >= 3, arguments[0] == "/usr/bin/open", arguments[1] == "-g" else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: arguments[2], isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func removePlists(agentURL: URL, loginURL: URL) {
        try? FileManager.default.removeItem(at: agentURL)
        try? FileManager.default.removeItem(at: loginURL)
    }

    static func isServiceLoaded(launchctl: LaunchctlRunner) -> Bool {
        launchctl(["print", "gui/\(uid)/\(LaunchAgentPlist.label)"])
    }
}

@MainActor public final class LoginItemCoordinator: ObservableObject {
    @Published public private(set) var status: LoginItemStatus = .disabled
    @Published public private(set) var isBusy = false
    @Published public private(set) var failure: String?
    @Published public private(set) var agentJob: AgentJobState = .unknown

    private let homeDirectory: String
    private let bundleURL: URL
    private let launchctl: LaunchctlRunner
    private let sleep: @Sendable (TimeInterval) -> Void
    private let followUpDelay: TimeInterval
    private let queue = DispatchQueue(label: "io.github.mbieniooo.xm6connect.login-item", qos: .userInitiated)
    private var pendingJobs = 0

    public init(homeDirectory: String = NSHomeDirectory(), bundleURL: URL = Bundle.main.bundleURL, launchctl: @escaping LaunchctlRunner = systemLaunchctlRunner, sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }, followUpDelay: TimeInterval = 1) {
        self.homeDirectory = homeDirectory
        self.bundleURL = bundleURL
        self.launchctl = launchctl
        self.sleep = sleep
        self.followUpDelay = followUpDelay
    }

    public func set(_ enabled: Bool, then: (() -> Void)? = nil) {
        pendingJobs += 1
        isBusy = true
        let homeDirectory = homeDirectory
        let bundleURL = bundleURL
        let launchctl = launchctl
        let sleep = sleep
        dispatch {
            let outcome: LoginItemOutcome
            if enabled {
                outcome = LaunchAgentController.enable(bundleURL: bundleURL, homeDirectory: homeDirectory, launchctl: launchctl, sleep: sleep)
            } else {
                LaunchAgentController.disable(homeDirectory: homeDirectory, launchctl: launchctl)
                outcome = .enabled
            }
            let loaded = LaunchAgentController.isServiceLoaded(launchctl: launchctl)
            let status = LaunchAgentController.status(homeDirectory: homeDirectory, serviceLoaded: loaded, launchctl: launchctl)
            let agentJob = LaunchAgentController.agentJobState(homeDirectory: homeDirectory, serviceLoaded: loaded)
            DispatchQueue.main.async {
                self.publish(outcome: outcome, status: status, agentJob: agentJob, publishesFailure: enabled, then: then)
            }
        }
    }

    public func startAgent(then: (() -> Void)? = nil) {
        pendingJobs += 1
        isBusy = true
        let homeDirectory = homeDirectory
        let launchctl = launchctl
        let sleep = sleep
        dispatch {
            let outcome = LaunchAgentController.start(homeDirectory: homeDirectory, launchctl: launchctl, sleep: sleep)
            let loaded = LaunchAgentController.isServiceLoaded(launchctl: launchctl)
            let status = LaunchAgentController.status(homeDirectory: homeDirectory, serviceLoaded: loaded, launchctl: launchctl)
            let agentJob = LaunchAgentController.agentJobState(homeDirectory: homeDirectory, serviceLoaded: loaded)
            DispatchQueue.main.async {
                self.publish(outcome: outcome, status: status, agentJob: agentJob, publishesFailure: true, then: then)
            }
        }
    }

    public func refresh() {
        let homeDirectory = homeDirectory
        let launchctl = launchctl
        dispatch {
            let loaded = LaunchAgentController.isServiceLoaded(launchctl: launchctl)
            let status = LaunchAgentController.status(homeDirectory: homeDirectory, serviceLoaded: loaded, launchctl: launchctl)
            let agentJob = LaunchAgentController.agentJobState(homeDirectory: homeDirectory, serviceLoaded: loaded)
            DispatchQueue.main.async {
                self.status = status
                self.agentJob = agentJob
            }
        }
    }

    private func publish(outcome: LoginItemOutcome, status: LoginItemStatus, agentJob: AgentJobState, publishesFailure: Bool, then: (() -> Void)?) {
        self.status = status
        self.agentJob = agentJob
        failure = publishesFailure ? outcome.reason : nil
        pendingJobs -= 1
        isBusy = pendingJobs > 0
        if let then {
            DispatchQueue.main.asyncAfter(deadline: .now() + followUpDelay, execute: DispatchWorkItem(block: then))
        }
    }

    private func dispatch(_ block: @escaping @Sendable () -> Void) {
        queue.async(execute: block)
    }
}
