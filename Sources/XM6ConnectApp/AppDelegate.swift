import SwiftUI
import OSLog
import AppKit
import CoreFoundation
#if canImport(SonyHeadphonesKit)
import SonyHeadphonesKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

// This file contains the application delegate so it can live in
// XM6ConnectAppLogic and be reachable from the test target. Only the @main
// entry point has to stay outside a library, and it is the one thing with no
// behaviour worth testing.
public final class XM6ConnectApplicationDelegate: NSObject, NSApplicationDelegate {
    /// The SwiftUI scene installs this after the menu extra is ready.  URL events
    /// received during launch are retained rather than opening a window or focusing
    /// the LSUIElement app.
    public var actionHandler: ((XM6ConnectDarwinNotification.Action) -> Void)? {
        didSet { deliverPendingActions() }
    }

    /// Widget taps must work whether or not the popover has ever been opened. The
    /// scene's `.onAppear` only runs on first open, so relying on it left every
    /// widget action queued and inert. Wire a self-contained
    /// handler at launch; the scene may replace it later with its model-bound one.
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI does not deliver `application(_:open:)` to an app whose only scene is
        // a MenuBarExtra — the URL reaches the process and is dropped. The Apple Event handler is the reliable
        // route and bypasses SwiftUI's scene plumbing entirely.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        // Widget and Control Center reloads must happen whether or not the popover has
        // ever been opened — they were wired in the scene's .onAppear, the same defect
        // just fixed for the action handler.
        if stateObserver == nil {
            stateObserver = DarwinObserver(names: [XM6ConnectDarwinNotification.stateChanged]) { _ in
                #if canImport(WidgetKit)
                WidgetCenter.shared.reloadTimelines(ofKind: "io.github.mbieniooo.xm6connect.widget")
                #endif
            }
        }
        guard actionHandler == nil else { return }
        let client = SocketClient()
        let log = Logger(subsystem: "io.github.mbieniooo.xm6connect", category: "url")
        actionHandler = { action in
            Task {
                do {
                    // A mode tap carries only the mode; the agent takes level and focus from
                    // the headset's report in the session that sends it.
                    let reply = try await client.request(AppCommand.command(for: action))
                    if let error = reply.error {
                        log.error("action was rejected by the agent: \(error, privacy: .public)")
                    }
                } catch {
                    // A widget/URL action that never reached the agent is invisible to the
                    // user otherwise: the button simply appears to do nothing.
                    log.error("action could not reach the agent: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text) else { return }
        application(NSApplication.shared, open: [url])
    }
    private var pendingActions: [XM6ConnectDarwinNotification.Action] = []
    private static let actionLog = Logger(subsystem: "io.github.mbieniooo.xm6connect", category: "url")
    private var stateObserver: DarwinObserver?

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let action = XM6ConnectDarwinNotification.action(for: url) else { continue }
            Self.actionLog.notice("received action \(url.lastPathComponent, privacy: .public)")
            if let actionHandler { actionHandler(action) }
            else { pendingActions.append(action) }
        }
    }

    private func deliverPendingActions() {
        guard let actionHandler else { return }
        let actions = pendingActions
        pendingActions.removeAll()
        actions.forEach(actionHandler)
    }
}
