import Foundation
import Darwin
import XM6ConnectAppLogic

func testLaunchAgentPlistShape() -> Bool {
    let dict = LaunchAgentPlist.dictionary(programArguments: [LaunchAgentPlist.relativeAgentPath])
    let expectedKeys: Set<String> = ["Label", "KeepAlive", "RunAtLoad", "ProgramArguments", "AssociatedBundleIdentifiers"]
    guard Set(dict.keys) == expectedKeys else { return false }
    guard dict["Label"] as? String == "io.github.mbieniooo.xm6connect.agent",
          dict["KeepAlive"] as? Bool == true,
          dict["RunAtLoad"] as? Bool == true,
          dict["AssociatedBundleIdentifiers"] as? [String] == ["io.github.mbieniooo.xm6connect.app"],
          (dict["ProgramArguments"] as? [String]) == [LaunchAgentPlist.relativeAgentPath] else { return false }
    guard let data = try? LaunchAgentPlist.serialized(programArguments: [LaunchAgentPlist.relativeAgentPath]),
          let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
    return Set(decoded.keys) == expectedKeys
        && decoded["Label"] as? String == "io.github.mbieniooo.xm6connect.agent"
}

/// Records the delays passed to an injected `sleep`, which runs synchronously in the caller.
private final class SleepRecorder: @unchecked Sendable { var delays: [TimeInterval] = [] }

private final class LockedLaunchctlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let result: ([String]) -> Bool
    private(set) var calls: [([String], Bool)] = []
    private(set) var runner: LaunchctlRunner = { _ in false }

    init(result: @escaping ([String]) -> Bool = { _ in true }) {
        self.result = result
        runner = { [self] arguments in
            let isMain = Thread.isMainThread
            lock.lock()
            calls.append((arguments, isMain))
            lock.unlock()
            return result(arguments)
        }
    }

    var recordedArguments: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls.map(\.0)
    }

    var allCallsWereOffMain: Bool {
        lock.lock(); defer { lock.unlock() }
        return calls.allSatisfy { !$0.1 }
    }
}

private final class GateLaunchctlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let gate: DispatchSemaphore
    private var isFirstCall = true
    private(set) var calls: [([String], Bool)] = []
    private(set) var runner: LaunchctlRunner = { _ in false }

    init(gate: DispatchSemaphore) {
        self.gate = gate
        runner = { [self] arguments in
            let isMain = Thread.isMainThread
            lock.lock()
            calls.append((arguments, isMain))
            let wait = isFirstCall
            isFirstCall = false
            lock.unlock()
            if wait { _ = gate.wait(timeout: .now() + 2) }
            return true
        }
    }

    var recordedArguments: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return calls.map(\.0)
    }

    var allCallsWereOffMain: Bool {
        lock.lock(); defer { lock.unlock() }
        return calls.allSatisfy { !$0.1 }
    }
}

private func loginPlistURL(home: URL, label: String) -> URL {
    home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
}

private func writeLoginTestPlist(_ dictionary: [String: Any], to url: URL) -> Bool {
    guard let data = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0) else { return false }
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return true
    } catch { return false }
}

private func validLoginTestPlist(bundleURL: URL) -> [String: Any] {
    ["Label": "io.github.mbieniooo.xm6connect.login", "ProgramArguments": ["/usr/bin/open", "-g", bundleURL.path], "RunAtLoad": true, "AssociatedBundleIdentifiers": ["io.github.mbieniooo.xm6connect.app"]]
}

@MainActor func testLoginToggleNeverRunsLaunchctlOnMain() async -> Bool {
    let home = loginTestHome()
    guard let bundle = loginTestBundle(in: home) else {
        try? FileManager.default.removeItem(at: home); print("    could not create test bundle"); return false
    }
    let gate = DispatchSemaphore(value: 0)
    let recorder = GateLaunchctlRecorder(gate: gate)
    let login = LoginItemCoordinator(homeDirectory: home.path, bundleURL: bundle, launchctl: recorder.runner, sleep: { _ in })
    let passed = await loginToggleOffMainChecks(login: login, recorder: recorder, gate: gate, home: home)
    // Every exit lets the job finish before the home goes, so a red run cannot leave the job
    // writing plists into a deleted directory.
    gate.signal()
    let deadline = Date().addingTimeInterval(2)
    while login.isBusy && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    try? FileManager.default.removeItem(at: home)
    return passed
}

@MainActor private func loginToggleOffMainChecks(login: LoginItemCoordinator, recorder: GateLaunchctlRecorder, gate: DispatchSemaphore, home: URL) async -> Bool {
    let began = Date()
    login.set(true)
    let elapsed = Date().timeIntervalSince(began)
    guard elapsed < 0.05, login.isBusy else {
        print("    set returned in \(String(format: "%.3f", elapsed))s; isBusy=\(login.isBusy)")
        return false
    }
    login.refresh()
    // Wait for set's first launchctl call (it is held at the gate), then give a refresh that
    // was not queued behind it time to show up as a second call.
    let firstCall = Date().addingTimeInterval(2)
    while recorder.recordedArguments.isEmpty && Date() < firstCall { try? await Task.sleep(nanoseconds: 10_000_000) }
    try? await Task.sleep(nanoseconds: 50_000_000)
    guard recorder.recordedArguments.count == 1 else {
        print("    refresh was not serialised behind set: \(recorder.recordedArguments)")
        return false
    }
    gate.signal()
    let deadline = Date().addingTimeInterval(2)
    while login.isBusy && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    guard !login.isBusy else { print("    coordinator remained busy after 2s"); return false }
    let service = "gui/\(getuid())/\(LaunchAgentPlist.label)"
    let calls = recorder.recordedArguments
    guard recorder.allCallsWereOffMain,
          calls.first == ["bootstrap", "gui/\(getuid())", LaunchAgentController.plistURL(homeDirectory: home.path).path],
          calls.contains(["print", service]),
          login.status == .enabled,
          login.agentJob == .loaded else {
        print("    calls=\(calls), offMain=\(recorder.allCallsWereOffMain), status=\(login.status), job=\(login.agentJob)")
        return false
    }
    return true
}

@MainActor func testPlaceholderActionMapping() -> Bool {
    let states: [AgentJobState] = [.unknown, .loaded, .plistOnly, .absent, .stale]
    guard states.allSatisfy({ PlaceholderAction.for(socketUnreachable: false, agentJob: $0) == .reconnect }),
          PlaceholderAction.for(socketUnreachable: true, agentJob: .unknown) == .reconnect,
          PlaceholderAction.for(socketUnreachable: true, agentJob: .stale) == .enableLoginItem,
          PlaceholderAction.for(socketUnreachable: true, agentJob: .absent) == .enableLoginItem,
          PlaceholderAction.for(socketUnreachable: true, agentJob: .loaded) == .startAgent,
          PlaceholderAction.for(socketUnreachable: true, agentJob: .plistOnly) == .startAgent,
          PlaceholderAction.reconnect.title == "Reconnect",
          PlaceholderAction.startAgent.title == "Start agent",
          PlaceholderAction.enableLoginItem.title == "Turn on" else {
        print("    T7: placeholder action mapping or titles were wrong")
        return false
    }
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home) else { print("    T7: could not create test bundle"); return false }
    let plist = LaunchAgentController.plistURL(homeDirectory: home.path)
    guard writeLoginTestPlist(LaunchAgentPlist.dictionary(programArguments: ["/not/executable"]), to: plist),
          LaunchAgentController.agentJobState(homeDirectory: home.path, serviceLoaded: true) == .stale else {
        print("    T7: stale job state was not detected")
        return false
    }
    try? FileManager.default.removeItem(at: plist)
    guard LaunchAgentController.agentJobState(homeDirectory: home.path, serviceLoaded: true) == .loaded,
          writeLoginTestPlist(LaunchAgentPlist.dictionary(programArguments: [bundle.appendingPathComponent(LaunchAgentPlist.relativeAgentPath).path]), to: plist),
          LaunchAgentController.agentJobState(homeDirectory: home.path, serviceLoaded: false) == .plistOnly else {
        print("    T7: loaded or plist-only job state was not detected")
        return false
    }
    try? FileManager.default.removeItem(at: plist)
    guard LaunchAgentController.agentJobState(homeDirectory: home.path, serviceLoaded: false) == .absent else {
        print("    T7: absent job state was not detected")
        return false
    }
    let model = PopoverModel()
    model.apply(error: SocketClientError.unavailable)
    guard model.socketUnreachable else { print("    T7: unavailable did not set socketUnreachable"); return false }
    model.apply(error: SocketClientError.timeout)
    guard !model.socketUnreachable else { print("    T7: timeout left socketUnreachable set"); return false }
    model.apply(error: SocketClientError.unavailable)
    guard model.socketUnreachable else { print("    T7: second unavailable did not set socketUnreachable"); return false }
    model.apply(error: SocketClientError.malformedReply)
    guard !model.socketUnreachable else { print("    T7: malformed reply left socketUnreachable set"); return false }
    model.apply(error: SocketClientError.unavailable)
    model.apply(AppReply(state: AppState(connectionStatus: "connected")))
    guard !model.socketUnreachable else { print("    T7: reply did not clear socketUnreachable"); return false }
    return true
}

@MainActor func testStartAgentTrustsTheLoadedStateNotTheBootstrapExit() -> Bool {
    // launchctl bootstrap can exit non-zero (error 5) yet load the job, or fail once right
    // after a bootout; start() decides by whether the job is loaded and retries once.
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home) else { print("    could not create test bundle"); return false }
    let service = "gui/\(getuid())/\(LaunchAgentPlist.label)"
    let plist = LaunchAgentController.plistURL(homeDirectory: home.path).path
    guard writeLoginTestPlist(LaunchAgentPlist.dictionary(programArguments: [bundle.appendingPathComponent(LaunchAgentPlist.relativeAgentPath).path]), to: URL(fileURLWithPath: plist)) else {
        print("    could not write plist"); return false
    }
    var prints = 0
    let loadedAnyway = LaunchctlRecorder(result: { arguments in
        if arguments.first == "print" { prints += 1; return prints > 1 }
        return arguments.first != "bootstrap"
    })
    guard case .enabled = LaunchAgentController.start(homeDirectory: home.path, launchctl: loadedAnyway.runner, sleep: { _ in }),
          loadedAnyway.calls == [["print", service], ["bootstrap", "gui/\(getuid())", plist], ["print", service]] else {
        print("    a bootstrap that loaded the job despite its exit code was reported as failed: \(loadedAnyway.calls)"); return false
    }
    var retryPrints = 0, bootstraps = 0
    let sleeps = SleepRecorder()
    let failsOnce = LaunchctlRecorder(result: { arguments in
        switch arguments.first {
        case "print": retryPrints += 1; return retryPrints > 2
        case "bootstrap": bootstraps += 1; return bootstraps > 1
        default: return true
        }
    })
    guard case .enabled = LaunchAgentController.start(homeDirectory: home.path, launchctl: failsOnce.runner, sleep: { sleeps.delays.append($0) }),
          bootstraps == 2, sleeps.delays == [2.0] else {
        print("    a bootstrap that fails once was not retried: \(failsOnce.calls), sleeps \(sleeps.delays)"); return false
    }
    return true
}

@MainActor func testStartAgentKickstartsWithoutKill() async -> Bool {
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home) else { print("    T12: could not create test bundle"); return false }
    let service = "gui/\(getuid())/\(LaunchAgentPlist.label)"
    let plist = LaunchAgentController.plistURL(homeDirectory: home.path).path

    let loaded = LaunchctlRecorder(result: { _ in true })
    guard case .enabled = LaunchAgentController.start(homeDirectory: home.path, launchctl: loaded.runner),
          loaded.calls == [["print", service], ["kickstart", service]] else {
        print("    T12: loaded job calls were \(loaded.calls)")
        return false
    }

    guard writeLoginTestPlist(LaunchAgentPlist.dictionary(programArguments: [bundle.appendingPathComponent(LaunchAgentPlist.relativeAgentPath).path]), to: URL(fileURLWithPath: plist)) else {
        print("    T12: could not arrange plist-only job")
        return false
    }
    var printCount = 0
    let plistOnly = LaunchctlRecorder(result: { arguments in
        if arguments.first == "print" { printCount += 1; return printCount > 1 }
        return true
    })
    guard case .enabled = LaunchAgentController.start(homeDirectory: home.path, launchctl: plistOnly.runner),
          plistOnly.calls == [["print", service], ["bootstrap", "gui/\(getuid())", plist], ["print", service]] else {
        print("    T12: plist-only job calls were \(plistOnly.calls)")
        return false
    }

    try? FileManager.default.removeItem(atPath: plist)
    let absent = LaunchctlRecorder(result: { arguments in arguments.first != "print" })
    guard case .failed = LaunchAgentController.start(homeDirectory: home.path, launchctl: absent.runner),
          absent.calls == [["print", service]] else {
        print("    T12: absent job calls were \(absent.calls)")
        return false
    }

    guard writeLoginTestPlist(LaunchAgentPlist.dictionary(programArguments: ["/not/executable"]), to: URL(fileURLWithPath: plist)) else {
        print("    T12: could not arrange stale job")
        return false
    }
    let stale = LaunchctlRecorder()
    guard case .failed = LaunchAgentController.start(homeDirectory: home.path, launchctl: stale.runner),
          stale.calls == [["print", service]],
          !stale.calls.contains(where: { $0.first == "kickstart" || $0.first == "bootstrap" }) else {
        print("    T12: stale job was started: \(stale.calls)")
        return false
    }

    try? FileManager.default.removeItem(atPath: plist)
    let coordinatorRecorder = LockedLaunchctlRecorder()
    let login = LoginItemCoordinator(homeDirectory: home.path, bundleURL: bundle, launchctl: coordinatorRecorder.runner, sleep: { _ in }, followUpDelay: 0.2)
    var followUps = 0, followUpsAtPublish = -1, thenOnMain = false
    var publishedAt: Date?, firedAt: Date?
    login.startAgent { followUps += 1; thenOnMain = Thread.isMainThread; firedAt = Date() }
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if publishedAt == nil, !login.isBusy { publishedAt = Date(); followUpsAtPublish = followUps }
        if followUps > 0 { break }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    // Three times the delay, so a second call would have landed.
    try? await Task.sleep(nanoseconds: 600_000_000)
    let delay = publishedAt.flatMap { published in firedAt.map { $0.timeIntervalSince(published) } } ?? -1
    guard !login.isBusy, followUpsAtPublish == 0, followUps == 1, thenOnMain, delay >= 0.15,
          coordinatorRecorder.allCallsWereOffMain,
          coordinatorRecorder.recordedArguments == [["print", service], ["kickstart", service], ["print", service]] else {
        print("    T12: coordinator busy=\(login.isBusy), followUps=\(followUps) (at publish \(followUpsAtPublish)), onMain=\(thenOnMain), delay=\(delay), calls=\(coordinatorRecorder.recordedArguments)")
        return false
    }
    return true
}

@MainActor func testCoordinatorRefreshPublishesOneRead() async -> Bool {
    // refresh() is the only reader on first open and after the socket goes unreachable: one
    // print, published as both the status and the job state, with isBusy left alone.
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home) else { print("    could not create test bundle"); return false }
    _ = LaunchAgentController.enable(bundleURL: bundle, homeDirectory: home.path, launchctl: LaunchctlRecorder().runner, sleep: { _ in })
    let recorder = LockedLaunchctlRecorder()
    let login = LoginItemCoordinator(homeDirectory: home.path, bundleURL: bundle, launchctl: recorder.runner, sleep: { _ in }, followUpDelay: 0)
    login.refresh()
    guard !login.isBusy else { print("    refresh raised isBusy"); return false }
    let deadline = Date().addingTimeInterval(2)
    while login.agentJob == .unknown && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    let service = "gui/\(getuid())/\(LaunchAgentPlist.label)"
    guard login.status == .enabled, login.agentJob == .loaded, !login.isBusy, login.failure == nil,
          recorder.recordedArguments == [["print", service]], recorder.allCallsWereOffMain else {
        print("    status=\(login.status) job=\(login.agentJob) busy=\(login.isBusy) calls=\(recorder.recordedArguments)")
        return false
    }
    return true
}

@MainActor func testCoordinatorPublishesAFailedStartsReason() async -> Bool {
    // The popover caption shows `failure`: a start that fails must say why, and turning
    // Start at login off clears it.
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home) else { print("    could not create test bundle"); return false }
    let recorder = LockedLaunchctlRecorder(result: { arguments in arguments.first != "print" })
    let login = LoginItemCoordinator(homeDirectory: home.path, bundleURL: bundle, launchctl: recorder.runner, sleep: { _ in }, followUpDelay: 0)
    func settle() async { let deadline = Date().addingTimeInterval(2); while login.isBusy && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) } }
    login.startAgent()
    await settle()
    guard !login.isBusy, login.failure == "The agent is not installed" else {
        print("    after a failed start: busy=\(login.isBusy) failure=\(String(describing: login.failure))"); return false
    }
    login.set(false)
    await settle()
    guard !login.isBusy, login.failure == nil else {
        print("    after turning login off: busy=\(login.isBusy) failure=\(String(describing: login.failure))"); return false
    }
    return true
}

func testLoginEnableWritesBothJobs() -> Bool {
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home) else { print("    T1: could not create test bundle"); return false }
    let recorder = LaunchctlRecorder()
    let outcome = LaunchAgentController.enable(bundleURL: bundle, homeDirectory: home.path, launchctl: recorder.runner, sleep: { _ in })
    let agentURL = LaunchAgentController.plistURL(homeDirectory: home.path)
    let loginURL = loginPlistURL(home: home, label: "io.github.mbieniooo.xm6connect.login")
    guard case .enabled = outcome,
          let login = (try? Data(contentsOf: loginURL)).flatMap({ try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }),
          login["ProgramArguments"] as? [String] == ["/usr/bin/open", "-g", bundle.path],
          login["RunAtLoad"] as? Bool == true,
          login["KeepAlive"] == nil,
          login["AssociatedBundleIdentifiers"] as? [String] == ["io.github.mbieniooo.xm6connect.app"],
          let agent = (try? Data(contentsOf: agentURL)).flatMap({ try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }),
          agent["AssociatedBundleIdentifiers"] as? [String] == ["io.github.mbieniooo.xm6connect.app"],
          recorder.calls.filter({ $0.first == "bootstrap" }) == [["bootstrap", "gui/\(getuid())", agentURL.path]] else {
        print("    T1: expected both plists and one agent bootstrap, got \(recorder.calls)")
        return false
    }
    return true
}

func testPrintedPlistsAreWhatEnableWrites() -> Bool {
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home) else { print("    T8: could not create test bundle"); return false }
    let recorder = LaunchctlRecorder()
    guard case .enabled = LaunchAgentController.enable(bundleURL: bundle, homeDirectory: home.path, launchctl: recorder.runner, sleep: { _ in }),
          case .success(let agentData)? = LaunchAgentPlist.printedPlist(arguments: ["XM6Connect", "--print-agent-plist", bundle.path], defaultBundlePath: "/nonexistent/Default.app"),
          case .success(let loginData)? = LaunchAgentPlist.printedPlist(arguments: ["XM6Connect", "--print-login-plist", bundle.path], defaultBundlePath: "/nonexistent/Default.app"),
          agentData == (try? Data(contentsOf: LaunchAgentController.plistURL(homeDirectory: home.path))),
          loginData == (try? Data(contentsOf: loginPlistURL(home: home, label: "io.github.mbieniooo.xm6connect.login"))),
          let agent = try? PropertyListSerialization.propertyList(from: agentData, format: nil) as? [String: Any],
          agent["ProgramArguments"] as? [String] == [bundle.path + "/Contents/MacOS/XM6ConnectAgent"],
          LaunchAgentPlist.printedPlist(arguments: ["XM6Connect"], defaultBundlePath: "/nonexistent/Default.app") == nil,
          case .failure? = LaunchAgentPlist.printedPlist(arguments: ["XM6Connect", "--print-agent-plist", "relative.app"], defaultBundlePath: "/nonexistent/Default.app") else {
        print("    T8: printed plist bytes or argument handling did not match enable")
        return false
    }
    guard let install = repositorySource("scripts/install.sh"),
          install.contains("--print-agent-plist \"$DEST\""),
          install.contains("--print-login-plist \"$DEST\""),
          !install.contains("<key>Label</key>"),
          let agentFlag = install.range(of: "--print-agent-plist \"$DEST\""),
          let loginFlag = install.range(of: "--print-login-plist \"$DEST\""),
          let pkill = install.range(of: "pkill -x XM6Connect "),
          let remove = install.range(of: "rm -rf \"$DEST\"") else {
        print("    T8: install.sh still hand-writes the plist or lacks candidate generation")
        return false
    }
    guard agentFlag.lowerBound < pkill.lowerBound
        && loginFlag.lowerBound < pkill.lowerBound
        && agentFlag.lowerBound < remove.lowerBound
        && loginFlag.lowerBound < remove.lowerBound else {
        print("    T8: candidate plist generation occurs after an installed-state change")
        return false
    }
    return true
}

func testLoginDisableKeepsRunningAgent() -> Bool {
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home),
          writeLoginTestPlist(LaunchAgentPlist.dictionary(programArguments: [bundle.appendingPathComponent(LaunchAgentPlist.relativeAgentPath).path]), to: LaunchAgentController.plistURL(homeDirectory: home.path)),
          writeLoginTestPlist(validLoginTestPlist(bundleURL: bundle), to: loginPlistURL(home: home, label: "io.github.mbieniooo.xm6connect.login")) else { print("    T2: could not arrange plists"); return false }
    let recorder = LaunchctlRecorder()
    LaunchAgentController.disable(homeDirectory: home.path, launchctl: recorder.runner)
    guard !FileManager.default.fileExists(atPath: LaunchAgentController.plistURL(homeDirectory: home.path).path),
          !FileManager.default.fileExists(atPath: loginPlistURL(home: home, label: "io.github.mbieniooo.xm6connect.login").path),
          !recorder.calls.contains(where: { $0.first == "bootout" }) else {
        print("    T2: disable removed jobs or booted out a running agent: \(recorder.calls)")
        return false
    }
    return true
}

func testLoginUnregisterBootsOutBothLabelsOnce() -> Bool {
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home),
          writeLoginTestPlist(LaunchAgentPlist.dictionary(programArguments: [bundle.appendingPathComponent(LaunchAgentPlist.relativeAgentPath).path]), to: LaunchAgentController.plistURL(homeDirectory: home.path)),
          writeLoginTestPlist(validLoginTestPlist(bundleURL: bundle), to: loginPlistURL(home: home, label: "io.github.mbieniooo.xm6connect.login")) else { print("    T3: could not arrange plists"); return false }
    let recorder = LaunchctlRecorder()
    LaunchAgentController.unregister(homeDirectory: home.path, launchctl: recorder.runner)
    let agentBootout = ["bootout", "gui/\(getuid())/io.github.mbieniooo.xm6connect.agent"]
    let loginBootout = ["bootout", "gui/\(getuid())/io.github.mbieniooo.xm6connect.login"]
    guard recorder.calls.filter({ $0 == agentBootout }).count == 1,
          recorder.calls.filter({ $0 == loginBootout }).count == 1,
          !FileManager.default.fileExists(atPath: LaunchAgentController.plistURL(homeDirectory: home.path).path),
          !FileManager.default.fileExists(atPath: loginPlistURL(home: home, label: "io.github.mbieniooo.xm6connect.login").path) else {
        print("    T3: expected exactly both bootouts and both removals, got \(recorder.calls)")
        return false
    }
    return true
}

func testLoginEnableFailureIsNotReportedEnabled() -> Bool {
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home) else { print("    T4: could not create test bundle"); return false }
    let recorder = LaunchctlRecorder(result: { arguments in arguments.first != "bootstrap" && arguments.first != "print" })
    let outcome = LaunchAgentController.enable(bundleURL: bundle, homeDirectory: home.path, launchctl: recorder.runner, sleep: { _ in })
    guard case .failed = outcome,
          !FileManager.default.fileExists(atPath: LaunchAgentController.plistURL(homeDirectory: home.path).path),
          !FileManager.default.fileExists(atPath: loginPlistURL(home: home, label: "io.github.mbieniooo.xm6connect.login").path),
          LaunchAgentController.status(homeDirectory: home.path, serviceLoaded: false, launchctl: recorder.runner) == .disabled else {
        print("    T4: failure was reported as \(outcome), or left a plist behind")
        return false
    }
    return true
}

func testLoginStatusReportsAStaleAgentPath() -> Bool {
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home),
          writeLoginTestPlist(LaunchAgentPlist.dictionary(programArguments: ["/nonexistent/XM6ConnectAgent"]), to: LaunchAgentController.plistURL(homeDirectory: home.path)),
          writeLoginTestPlist(validLoginTestPlist(bundleURL: bundle), to: loginPlistURL(home: home, label: "io.github.mbieniooo.xm6connect.login")) else { print("    T6: could not arrange stale agent plist"); return false }
    let recorder = LaunchctlRecorder()
    guard LaunchAgentController.status(homeDirectory: home.path, serviceLoaded: true, launchctl: recorder.runner) == .stalePath else {
        print("    T6: stale agent path was not reported")
        return false
    }
    return true
}

func testLoginReEnableWithLoadedJobNeverBootsOut() -> Bool {
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home) else { print("    T9: could not create test bundle"); return false }
    let recorder = LaunchctlRecorder(result: { arguments in arguments.first != "bootstrap" })
    let outcome = LaunchAgentController.enable(bundleURL: bundle, homeDirectory: home.path, launchctl: recorder.runner, sleep: { _ in })
    let bootstrap = ["bootstrap", "gui/\(getuid())", LaunchAgentController.plistURL(homeDirectory: home.path).path]
    guard case .enabled = outcome,
          FileManager.default.fileExists(atPath: LaunchAgentController.plistURL(homeDirectory: home.path).path),
          FileManager.default.fileExists(atPath: loginPlistURL(home: home, label: "io.github.mbieniooo.xm6connect.login").path),
          recorder.calls.filter({ $0 == bootstrap }).count == 1,
          !recorder.calls.contains(where: { $0.first == "bootout" }) else {
        print("    T9: loaded job was retried or login plist missing: \(recorder.calls)")
        return false
    }
    return true
}

func testLoginEnableReplacesAStaleLoadedJob() -> Bool {
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home),
          writeLoginTestPlist(LaunchAgentPlist.dictionary(programArguments: ["/nonexistent/XM6ConnectAgent"]), to: LaunchAgentController.plistURL(homeDirectory: home.path)) else { print("    T10: could not arrange stale agent plist"); return false }
    let recorder = LaunchctlRecorder()
    let outcome = LaunchAgentController.enable(bundleURL: bundle, homeDirectory: home.path, launchctl: recorder.runner, sleep: { _ in })
    let expectedBootout = ["bootout", "gui/\(getuid())/io.github.mbieniooo.xm6connect.agent"]
    let expectedBootstrap = ["bootstrap", "gui/\(getuid())", LaunchAgentController.plistURL(homeDirectory: home.path).path]
    let agent = (try? Data(contentsOf: LaunchAgentController.plistURL(homeDirectory: home.path))).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    guard case .enabled = outcome,
          recorder.calls.contains(expectedBootout), recorder.calls.contains(expectedBootstrap),
          agent?["ProgramArguments"] as? [String] == [bundle.appendingPathComponent(LaunchAgentPlist.relativeAgentPath).path] else {
        print("    T10: stale loaded job was not replaced: \(recorder.calls)")
        return false
    }
    return true
}

func testLoginStatusAgentOnlyIsPartial() -> Bool {
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home),
          writeLoginTestPlist(LaunchAgentPlist.dictionary(programArguments: [bundle.appendingPathComponent(LaunchAgentPlist.relativeAgentPath).path]), to: LaunchAgentController.plistURL(homeDirectory: home.path)) else { print("    T11: could not arrange agent plist"); return false }
    let recorder = LaunchctlRecorder()
    let status = LaunchAgentController.status(homeDirectory: home.path, serviceLoaded: true, launchctl: recorder.runner)
    guard status == .partial, !status.isEnabled else { print("    T11: agent-only status was \(status)"); return false }
    return true
}

func testLoginEnableRefusesTranslocatedBundle() -> Bool {
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    let bundle = URL(fileURLWithPath: "/private/var/folders/test/AppTranslocation/XM6-Connect.app", isDirectory: true)
    let recorder = LaunchctlRecorder()
    let outcome = LaunchAgentController.enable(bundleURL: bundle, homeDirectory: home.path, launchctl: recorder.runner, sleep: { _ in })
    guard case .failed = outcome,
          !FileManager.default.fileExists(atPath: LaunchAgentController.plistURL(homeDirectory: home.path).path),
          !FileManager.default.fileExists(atPath: loginPlistURL(home: home, label: "io.github.mbieniooo.xm6connect.login").path),
          recorder.calls.isEmpty else { print("    T13: translocated bundle wrote or ran \(recorder.calls)"); return false }
    return true
}
