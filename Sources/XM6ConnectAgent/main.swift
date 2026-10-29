import Foundation
import OSLog
import Darwin
import AppKit
import SonyHeadphonesKit
import XM6ConnectAgentCore

@MainActor private final class AgentRuntime {
    let server: UnixIPCServer
    let core: XM6ConnectAgentCore
    let actionObserver: DarwinObserver
    init() {
        let verbose = CommandLine.arguments.contains("--verbose")
        let logger = Logger(subsystem: "io.github.mbieniooo.xm6connect", category: "agent")
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            XM6ConnectPaths.agentSupportDirectoryRelativePath,
            isDirectory: true
        )
        let bridge = SonyControllerBridge()
        let snapshot = AgentStateSnapshot()
        let writer = AtomicStateWriter(url: base.appendingPathComponent("state.json"))
        let createdCore = XM6ConnectAgentCore(controller: bridge, resolver: PairedXM6Resolver(), scheduler: DispatchRetryScheduler(), writer: writer, configURL: base.appendingPathComponent("config.json"), stateSnapshot: snapshot, stateReader: AtomicStateReader(url: base.appendingPathComponent("state.json")))
        core = createdCore
        server = UnixIPCServer(path: XM6ConnectPaths.agentSocketPath(), snapshot: snapshot) { request in
            createdCore.handle(request)
        } refreshHandler: { completion in
            DispatchQueue.main.async { createdCore.refresh(completion: completion) }
        }
        do { try server.start() } catch let error as POSIXError where error.code == .EWOULDBLOCK { exit(0) }
        catch { logger.error("IPC server failed: \(error.localizedDescription, privacy: .public)"); exit(1) }
        actionObserver = XM6ConnectDarwinNotification.agentActionObserver { action in
            _ = createdCore.handle(widgetAction: action)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        _ = workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in Task { @MainActor in createdCore.setAsleep(true) } }
        _ = workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in Task { @MainActor in createdCore.setAsleep(false) } }
        let distributed = DistributedNotificationCenter.default()
        _ = distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in Task { @MainActor in createdCore.setScreenLocked(true) } }
        _ = distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in Task { @MainActor in createdCore.setScreenLocked(false) } }
        if verbose { logger.debug("XM6ConnectAgent started") }
        // Do NOT call start() here. It performs the process's first IOBluetooth call, and
        // `+[IOBluetoothDevice pairedDevices]` lazily builds IOBluetoothCoreBluetoothCoordinator,
        // whose init waits on a semaphore that needs the main run loop to be servicing.
        // This initializer runs on the main thread BEFORE `RunLoop.main.run()` below, so
        // calling it here deadlocks the agent: the IPC socket keeps answering from the
        // persisted snapshot and launchd reports the service healthy, while every command
        // is silently dropped and no log line is ever emitted. Sampling the process showed
        // the whole main thread sat in
        // semaphore_wait_trap under start(). Deferring to a queued main-queue turn
        // guarantees the run loop is already running when IOBluetooth is first touched.
        DispatchQueue.main.async { MainActor.assumeIsolated { createdCore.start() } }
    }
}

@MainActor private var runtime: AgentRuntime?
_ = signal(SIGPIPE, SIG_IGN)
Task { @MainActor in runtime = AgentRuntime() }
// Do not replace this with dispatchMain(): IOBluetooth delivers RFCOMM callbacks via
// CFRunLoop, and dispatchMain drops inbound headset data.
RunLoop.main.run()
