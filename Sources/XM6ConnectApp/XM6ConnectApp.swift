import SwiftUI
import OSLog
import AppKit
import CoreFoundation

@main struct XM6ConnectApp: App {
    @NSApplicationDelegateAdaptor(XM6ConnectApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = PopoverModel()
    @StateObject private var login = LoginItemCoordinator()
    private let client = SocketClient()
    @State private var contentHasOpened = false
    @State private var stateObserver: DarwinObserver?

    init() {
        _ = signal(SIGPIPE, SIG_IGN)
        if let printed = LaunchAgentPlist.printedPlist(arguments: CommandLine.arguments, defaultBundlePath: Bundle.main.bundleURL.path) { guard case .success(let data) = printed, (try? FileHandle.standardOutput.write(contentsOf: data)) != nil else { exit(1) }; exit(0) }
        if CommandLine.arguments.contains("--unregister-agent") {
            LaunchAgentController.unregister()
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Group {
                if contentHasOpened {
                    PopoverView(model: model, login: login).frame(width: PopoverLayout.popoverWidth)
                } else {
                    Color.clear.frame(width: PopoverLayout.popoverWidth, height: 1)
                }
            }
            .onAppear {
                // This is the earliest MenuBarExtra lifecycle hook available after a
                // menu-bar click. Post before constructing/showing real popover content
                // so a released lease can begin acquiring while the UI appears.
                requestPrewarm()
                contentHasOpened = true
                model.onCommand = { command in Task { await perform(command) } }
                applicationDelegate.actionHandler = { action in
                    let command = AppCommand.command(for: action)
                    Task { await perform(command) }
                }
                refresh()
                if stateObserver == nil { stateObserver = DarwinObserver(names: [XM6ConnectDarwinNotification.stateChanged]) { _ in refresh() } }
                login.refresh()
            }
        } label: { Image(systemName: iconName).symbolRenderingMode(.hierarchical) }
        .menuBarExtraStyle(.window)
    }
    // The menu bar always shows the app identity (headphones); mode lives in the
    // popover and the Control Center control. A mode-glyph here read as a broken icon.
    private var iconName: String { "headphones" }
    private func requestPrewarm() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(XM6ConnectDarwinNotification.name(for: .prewarm) as CFString),
            nil, nil, true
        )
    }
    private func refresh() { Task { await perform(.status) } }
    private func perform(_ command: AppCommand) async {
        do {
            let reply = try await client.request(command)
            await MainActor.run { model.handle(reply, for: command) }
        } catch {
            await MainActor.run {
                let wasSocketUnreachable = model.socketUnreachable
                model.apply(error: error)
                if !wasSocketUnreachable && model.socketUnreachable { login.refresh() }
            }
        }
    }

}
