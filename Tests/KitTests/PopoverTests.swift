import Foundation
import SonyHeadphonesKit
import XM6ConnectAgentCore
import XM6ConnectAppLogic
import AppKit
import SwiftUI

private struct ImmediateTransport: AppSocketTransport {
    let result: Result<Data, Error>
    func request(_ request: Data) async throws -> Data { try result.get() }
}

@MainActor func testPopoverReplyMappingAllCards() -> Bool {
    let state = AppState(connectionStatus: "connected", deviceName: "WH-1000XM6",
        ambient: AppAmbient(mode: "ambient", level: 14, focus: true, subtype: 0x19),
        battery: AppBattery(level: 87, charging: true),
        equalizer: AppEqualizer(presetCode: 0xa0, bands: [-6,-4,-2,0,1,2,3,4,5,6], subtype: 4),
        speakToChat: true, multipoint: [AppDevice(name: "Laptop", connected: true, playback: true), AppDevice(name: "Phone", connected: true, playback: false)])
    let view = PopoverModel.map(state)
    return view.connection == .connected && view.mode == .ambient && view.ambientLevel == 14 && view.focusOnVoice
        && view.batteryLevel == 87 && view.charging && view.preset == .custom && view.bands.count == 10
        && view.speakToChat == true && view.devices.count == 2 && view.ambientSliderEnabled && view.eqBandsEnabled
}

@MainActor func testPopoverDisconnectedAndAgentMissingMapping() -> Bool {
    let missing = PopoverModel.map(AppState(connectionStatus: "disconnected"), error: nil)
    let model = PopoverModel(); model.apply(error: SocketClientError.timeout)
    return missing.connection == .disconnected(message: "Headphones not connected") && model.viewState.connection == .disconnected(message: "Agent not running")
}

func testPopoverWidthBudget() -> Bool {
    let rowWidth = PopoverLayout.eqRowWidth()
    let expectedRowWidth = CGFloat(10 * 25 + 9 * 3)
    let expectedTotalWidth = expectedRowWidth + (2 * 12) + (2 * 14)
    return rowWidth == expectedRowWidth
        && PopoverLayout.eqCardTotalWidth == expectedTotalWidth
        && PopoverLayout.eqCardTotalWidth < PopoverLayout.popoverWidth
}

func testSocketRequestEncodingEveryCommand() -> Bool {
    func json(_ command: AppCommand) -> [String: Any]? { try? JSONSerialization.jsonObject(with: (try? AppRequestEncoder.data(for: command)) ?? Data()) as? [String: Any] }
    guard (json(.status)?["cmd"] as? String) == "status", (json(.reconnect)?["cmd"] as? String) == "reconnect",
          (json(.cycle)?["cmd"] as? String) == "cycle",
          (json(.setAmbientLevel(20))?["level"] as? Int) == 20,
          (json(.setEQPreset(0xa0))?["code"] as? Int) == 160, (json(.setEQBands(Array(repeating: 0, count: 10)))?["bands"] as? [Int])?.count == 10,
          (json(.setSTC(true))?["enabled"] as? Bool) == true,
          (json(.switchPlayback(macAddress: "AA:BB:CC:DD:EE:FF"))?["mac"] as? String) == "AA:BB:CC:DD:EE:FF",
          (json(.setListeningMode(.cinema))?["mode"] as? String) == "cinema",
          (json(.setBGMRoomSize(0x02))?["roomSize"] as? Int) == 2 else { return false }
    return true
}

@MainActor func testPopoverSliderCoalescingAndEditRules() async -> Bool {
    let model = PopoverModel(); var commands: [AppCommand] = []; model.onCommand = { commands.append($0) }
    model.settleAmbientLevel(4); model.settleAmbientLevel(8)
    try? await Task.sleep(nanoseconds: 220_000_000)
    guard commands == [.setAmbientLevel(8)] else { return false }
    model.apply(AppReply(state: AppState(connectionStatus: "connected", ambient: AppAmbient(mode: "nc", level: 10, focus: false, subtype: 0x19), equalizer: AppEqualizer(presetCode: 0x31, bands: Array(repeating: 0, count: 10), subtype: 4))))
    guard !model.viewState.ambientSliderEnabled else { return false }
    model.editBand(3, value: 5)
    return model.viewState.preset == .custom && model.viewState.bands[3] == 5
}

@MainActor func testPopoverListeningModeMappingHasNoInventedDefault() -> Bool {
    // The picker offers exactly the kit's modes; there is no app-side copy of the table.
    guard let pickerSource = repositorySource("Sources/XM6ConnectApp/PopoverView.swift"),
          pickerSource.contains("ForEach(ListeningMode.allCases)") else { print("    the listening-mode picker does not iterate ListeningMode.allCases"); return false }
    for mode in ListeningMode.allCases {
        let view = PopoverModel.map(AppState(connectionStatus: "released", listeningMode: mode.rawValue))
        guard view.listeningMode?.rawValue == mode.rawValue, view.selectedListeningMode?.rawValue == mode.rawValue, view.hasDeviceState else { return false }
    }
    let unknown = PopoverModel.map(AppState(connectionStatus: "connected", listeningMode: "spatial"))
    let surround = PopoverModel.map(AppState(connectionStatus: "connected", listeningMode: "surround"))
    let absent = PopoverModel.map(AppState(connectionStatus: "connected"))
    return unknown.listeningMode == nil && unknown.selectedListeningMode == nil && !unknown.hasDeviceState
        && surround.listeningMode == nil && surround.selectedListeningMode == nil && !surround.hasDeviceState
        && absent.listeningMode == nil && absent.selectedListeningMode == nil && !absent.hasDeviceState
}

@MainActor func testPopoverListeningModeSelectionIssuesOneExactCommand() -> Bool {
    let model = PopoverModel(); var commands: [AppCommand] = []
    model.onCommand = { commands.append($0) }
    model.apply(AppReply(state: AppState(connectionStatus: "connected", listeningMode: "standard", stateAsOf: Date(timeIntervalSince1970: 10))))
    model.selectListeningMode(.cinema)
    model.selectListeningMode(.cinema)
    return commands == [.setListeningMode(.cinema)] && model.viewState.listeningMode == .standard
        && model.viewState.selectedListeningMode == .cinema
}

@MainActor func testPopoverBGMRoomSizeAvailabilityAndCommand() -> Bool {
    let model = PopoverModel(); var commands: [AppCommand] = []
    model.onCommand = { commands.append($0) }
    model.apply(AppReply(state: AppState(connectionStatus: "connected", listeningMode: "backgroundMusic", bgmRoomSize: 1, stateAsOf: Date(timeIntervalSince1970: 10))))
    guard model.viewState.bgmRoomSizeEnabled, model.viewState.bgmRoomSize == .middle else { return false }
    model.selectBGMRoomSize(.large)
    guard commands == [.setBGMRoomSize(0x02)] else { return false }
    model.apply(AppReply(state: AppState(connectionStatus: "connected", listeningMode: "cinema", bgmRoomSize: 2, stateAsOf: Date(timeIntervalSince1970: 11))))
    model.selectBGMRoomSize(.small)
    return !model.viewState.bgmRoomSizeEnabled && commands == [.setBGMRoomSize(0x02)]
}

@MainActor func testPopoverListeningModeReconcilesToNewDeviceReport() -> Bool {
    let model = PopoverModel()
    model.apply(AppReply(state: AppState(connectionStatus: "connected", listeningMode: "standard", stateAsOf: Date(timeIntervalSince1970: 10))))
    model.selectListeningMode(.cinema)
    guard model.viewState.selectedListeningMode == .cinema && model.viewState.listeningMode == .standard else { return false }
    // A later headset report declines the requested mode. Its timestamp, not the
    // command reply, is the authority that removes the popover-local optimism.
    model.apply(AppReply(state: AppState(connectionStatus: "connected", listeningMode: "standard", stateAsOf: Date(timeIntervalSince1970: 11))))
    return model.viewState.listeningMode == .standard && model.viewState.selectedListeningMode == .standard
        && model.viewState.pendingListeningMode == nil
}

func testSocketTimeoutMapsToAgentMissing() async -> Bool {
    let client = SocketClient(transport: ImmediateTransport(result: .failure(SocketClientError.timeout)))
    do { _ = try await client.request(.status); return false } catch { return (error as? SocketClientError) == .timeout }
}

@MainActor func testPopoverLeaseStatusesAreNotAgentMissing() -> Bool {
    let released = PopoverModel.map(AppState(connectionStatus: "released"))
    let yielded = PopoverModel.map(AppState(connectionStatus: "yielded"))
    let connecting = PopoverModel.map(AppState(connectionStatus: "connecting"))
    return released.connection == .disconnected(message: "Controls released to your phone")
        && yielded.connection == .disconnected(message: "Controls yielded to another app")
        && connecting.connection == .disconnected(message: "Connecting to headphones")
}

@MainActor
func testPopoverMultipointRowsMarkOnePlaybackAndDisableDisconnected() -> Bool {
    let state = AppState(connectionStatus: "connected", multipoint: [
        AppDevice(macAddress: "AA:BB:CC:DD:EE:FF", name: "Laptop", connected: true, playback: false),
        AppDevice(macAddress: "11:22:33:44:55:66", name: "Phone", connected: true, playback: true),
        AppDevice(macAddress: "77:88:99:AA:BB:CC", name: "iPad", connected: false, playback: true)
    ])
    let mapped = PopoverModel.map(state)
    guard mapped.multipointRows.count == 3,
          mapped.multipointRows.filter(\.isPlayback).count == 1,
          mapped.multipointRows[1].isPlayback,
          !mapped.multipointRows[2].isActionable else { return false }
    let model = PopoverModel(); var sent: [AppCommand] = []; model.onCommand = { sent.append($0) }; model.apply(AppReply(state: state))
    model.switchPlayback(to: model.viewState.multipointRows[0])
    guard model.viewState.multipointRows[0].isPlayback,
          sent == [.switchPlayback(macAddress: "AA:BB:CC:DD:EE:FF")] else { return false }
    // A pre-write reply does not replace the temporary local highlight.
    model.handle(AppReply(state: state, stale: true), for: .switchPlayback(macAddress: "AA:BB:CC:DD:EE:FF"))
    return model.viewState.multipointRows[0].isPlayback && !model.viewState.multipointRows[1].isPlayback
}

@MainActor func testPendingSelectionSurvivesTheRestingReleasedState() -> Bool {
    // "released" is the lease's RESTING state, not a failure: a queued command legitimately
    // waits for the lease, which under this design is the common case. Treating it like a
    // failure would snap the picker back to the old mode while the command is still in
    // flight. The pending selection must remain visible until the device reports it.
    let model = PopoverModel()
    let asOf = Date(timeIntervalSince1970: 2_000)
    model.apply(AppReply(state: AppState(connectionStatus: "connected",
                                         battery: AppBattery(level: 70, charging: false),
                                         listeningMode: "standard", stateAsOf: asOf)))
    model.selectListeningMode(.cinema)
    guard model.viewState.selectedListeningMode == .cinema else { return false }
    // The lease returns to rest, same stateAsOf: nothing has reached the headset yet.
    model.apply(AppReply(state: AppState(connectionStatus: "released",
                                         battery: AppBattery(level: 70, charging: false),
                                         listeningMode: "standard", stateAsOf: asOf)))
    return model.viewState.selectedListeningMode == .cinema
}

@MainActor func testPendingListeningSelectionDoesNotSurviveAnAbsentHeadset() -> Bool {
    // The pending highlight is dropped only when stateAsOf advances. If the headset is
    // absent, the write cannot have landed and no device report will ever arrive, so the
    // popover goes on claiming a mode the headset is not in, with no bound at all. This is
    // a missing reconciliation rule: it required reconciliation by a
    // device report but never said what bounds the pending state when none can come.
    let model = PopoverModel()
    let asOf = Date(timeIntervalSince1970: 1_000)
    model.apply(AppReply(state: AppState(connectionStatus: "connected",
                                         battery: AppBattery(level: 80, charging: false),
                                         listeningMode: "standard", stateAsOf: asOf)))
    guard model.viewState.selectedListeningMode == .standard else { return false }
    model.selectListeningMode(.cinema)
    guard model.viewState.selectedListeningMode == .cinema else { return false }
    // The agent now reports the headset as absent, with the same stateAsOf: no report can
    // follow, and the mode it last knew is still standard.
    model.apply(AppReply(state: AppState(connectionStatus: "failed",
                                         battery: AppBattery(level: 80, charging: false),
                                         listeningMode: "standard", stateAsOf: asOf,
                                         lastError: XM6ConnectAgentCore.missingHeadsetError)))
    return model.viewState.selectedListeningMode != .cinema
}

@MainActor func testDelegateQueuesURLActionsUntilAHandlerExists() -> Bool {
    // Newly reachable: XM6ConnectApplicationDelegate used to live in the excluded file.
    // A widget tap can arrive before the popover has ever been opened, so the URL must be
    // held and delivered when the scene installs its handler, and anything that is not a
    // known action must be dropped rather than guessed at.
    let delegate = XM6ConnectApplicationDelegate()
    var received: [XM6ConnectDarwinNotification.Action] = []
    delegate.application(NSApplication.shared, open: [
        XM6ConnectDarwinNotification.url(for: .cycle),
        XM6ConnectDarwinNotification.url(for: .noiseCancelling),
        URL(string: "xm6connect://action/not-a-real-action")!,
        URL(string: "https://example.com/action/cycle")!,
    ])
    guard received.isEmpty else { return false }          // nothing fires before a handler
    delegate.actionHandler = { received.append($0) }      // installing one flushes the queue
    guard received == [.cycle, .noiseCancelling] else { return false }
    // A later URL goes straight through.
    delegate.application(NSApplication.shared, open: [XM6ConnectDarwinNotification.url(for: .off)])
    guard received == [.cycle, .noiseCancelling, .off] else { return false }
    // The scene replaces the launch handler with its model-bound one (see the comment on
    // actionHandler). If the queue were not cleared on the first flush, that replacement
    // would replay it and fire real headset commands a second time.
    delegate.actionHandler = { received.append($0) }
    return received == [.cycle, .noiseCancelling, .off]
}

@MainActor func testPopoverKeepsItsHeightWhenTheWindowOffersAlmostNothing() -> Bool {
    // The menu-bar window sizes itself to its content and offers the content its own
    // current height. A bare ScrollView accepts whatever height it is offered, so a window
    // that first opened with device state collapsed to the 10 pt top inset and stayed a
    // sliver for the life of the app. Offered 10 pt, the view must still ask for its
    // full content height.
    let model = PopoverModel()
    model.apply(AppReply(state: AppState(
        connectionStatus: "connected",
        ambient: AppAmbient(mode: "nc", level: 10, focus: false, subtype: 0x17),
        battery: AppBattery(level: 93, charging: false),
        equalizer: AppEqualizer(presetCode: 0x33, bands: Array(repeating: 0, count: 10), subtype: 0),
        listeningMode: "standard", bgmRoomSize: 1,
        stateAsOf: Date(timeIntervalSince1970: 3_000))))
    guard model.viewState.hasDeviceState else { return false }
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home) else { return false }
    let login = LoginItemCoordinator(homeDirectory: home.path, bundleURL: bundle, launchctl: LaunchctlRecorder().runner)
    let host = NSHostingController(rootView: PopoverView(model: model, login: login)
        .frame(width: PopoverLayout.popoverWidth))
    let unconstrained = host.sizeThatFits(in: CGSize(width: PopoverLayout.popoverWidth, height: CGFloat.greatestFiniteMagnitude))
    let offeredAlmostNothing = host.sizeThatFits(in: CGSize(width: PopoverLayout.popoverWidth, height: 10))
    print("    popover height: unconstrained \(unconstrained.height), offered 10 pt -> \(offeredAlmostNothing.height)")
    return unconstrained.height > 100 && offeredAlmostNothing.height >= unconstrained.height - 1
}

@MainActor func testPopoverViewRendersOffscreenAtTheDeclaredWidth() -> Bool {
    // Newly reachable: PopoverView was in no test target, so nothing compiled or exercised
    // it. This lays the REAL view out offscreen with a realistic device state and asserts
    // it builds and respects the popover width. It would not have caught the picker-label
    // wrap (that changed height, not width) — see the lint below for that.
    let model = PopoverModel()
    model.apply(AppReply(state: AppState(
        connectionStatus: "connected",
        ambient: AppAmbient(mode: "nc", level: 10, focus: false, subtype: 0x17),
        battery: AppBattery(level: 93, charging: false),
        equalizer: AppEqualizer(presetCode: 0x33, bands: Array(repeating: 0, count: 10), subtype: 0),
        listeningMode: "standard", bgmRoomSize: 1,
        stateAsOf: Date(timeIntervalSince1970: 3_000))))
    guard model.viewState.hasDeviceState else { return false }
    let home = loginTestHome(); defer { try? FileManager.default.removeItem(at: home) }
    guard let bundle = loginTestBundle(in: home) else { return false }
    let login = LoginItemCoordinator(homeDirectory: home.path, bundleURL: bundle, launchctl: LaunchctlRecorder().runner)
    let host = NSHostingView(rootView: PopoverView(model: model, login: login)
        .frame(width: PopoverLayout.popoverWidth))
    host.layoutSubtreeIfNeeded()
    let size = host.fittingSize
    return size.width == PopoverLayout.popoverWidth && size.height > 100
}

@MainActor func testPresetCodesMapLikeTheKit() -> Bool {
    let expected: [(Int, EqualizerPreset)] = [(0x20, .game), (0x31, .clear), (-1, .custom), (300, .custom), (0x99, .custom)]
    for (code, preset) in expected {
        let view = PopoverModel.map(AppState(connectionStatus: "connected", equalizer: AppEqualizer(presetCode: code, bands: Array(repeating: 0, count: 10), subtype: 4)))
        guard view.preset == preset else { print("    code \(code) mapped to \(String(describing: view.preset)), expected \(preset)"); return false }
    }
    // `xm6ctl eq preset` accepts every kit label in any case, or a numeric code 0...255.
    for preset in EqualizerPreset.allCases {
        for spelling in [preset.label, preset.label.lowercased(), preset.label.uppercased()] {
            guard EqualizerPresetResolver.code(for: spelling) == Int(preset.rawValue) else { print("    \(spelling) did not resolve to \(preset.rawValue)"); return false }
        }
    }
    return EqualizerPresetResolver.code(for: "49") == 0x31 && EqualizerPresetResolver.code(for: "0") == 0
        && EqualizerPresetResolver.code(for: "255") == 255 && EqualizerPresetResolver.code(for: "256") == nil
        && EqualizerPresetResolver.code(for: "-1") == nil && EqualizerPresetResolver.code(for: "rock") == nil
}

@MainActor func testFocusToggleOnlyInAmbient() -> Bool {
    // The headset applies focus on voice only in Ambient; elsewhere it reports focus off.
    let modes: [(String, Bool)] = [("nc", false), ("ambient", true), ("off", false)]
    for (mode, expected) in modes {
        let view = PopoverModel.map(AppState(connectionStatus: "connected", ambient: AppAmbient(mode: mode, level: 5, focus: false, subtype: 0x19)))
        guard view.focusToggleEnabled == expected else { print("    focus toggle enabled=\(view.focusToggleEnabled) in \(mode)"); return false }
    }
    return true
}

@MainActor func testPopoverWaitIndicatorAppearsOnlyAfterThreshold() async -> Bool {
    let model = PopoverModel()
    model.beginActionWait()
    guard !model.actionIsTakingTime else { return false }
    try? await Task.sleep(nanoseconds: 450_000_000)
    guard model.actionIsTakingTime else { return false }
    model.finishActionWait()
    return !model.actionIsTakingTime
}

@MainActor func testPendingEditsHoldUntilTheHeadsetReportsThem() async -> Bool {
    let t0 = Date(timeIntervalSince1970: 1_000), t1 = Date(timeIntervalSince1970: 1_001), t2 = Date(timeIntervalSince1970: 1_002)
    func state(_ date: Date) -> AppState {
        AppState(connectionStatus: "connected", ambient: AppAmbient(mode: "ambient", level: 5, focus: false, subtype: 0x19), equalizer: AppEqualizer(presetCode: Int(EqualizerPreset.off.rawValue), bands: Array(repeating: 0, count: 10), subtype: 4), speakToChat: false, multipoint: [AppDevice(macAddress: "A", name: "A", connected: true, playback: true), AppDevice(macAddress: "B", name: "B", connected: true, playback: false)], stateAsOf: date)
    }
    let cases: [(String, (PopoverModel) -> Void, (PopoverViewState) -> Bool, (inout AppState) -> Void)] = [
        ("playback", { $0.switchPlayback(to: $0.viewState.multipointRows[1]) }, { $0.multipointRows[1].isPlayback }, { $0.multipoint![0].playback = false; $0.multipoint![1].playback = true }),
        ("mode", { $0.selectMode(.nc) }, { $0.mode == .nc }, { $0.ambient!.mode = "nc" }),
        ("focus", { $0.setFocus(true) }, { $0.focusOnVoice }, { $0.ambient!.focus = true }),
        ("ambient level", { $0.settleAmbientLevel(9) }, { $0.ambientLevel == 9 }, { $0.ambient!.level = 9 }),
        ("preset", { $0.selectPreset(.heavy) }, { $0.preset == .heavy }, { $0.equalizer!.presetCode = Int(EqualizerPreset.heavy.rawValue) }),
        ("band", { $0.editBand(0, value: 3) }, { $0.preset == .custom && $0.bands[0] == 3 }, { $0.equalizer!.presetCode = Int(EqualizerPreset.custom.rawValue); $0.equalizer!.bands[0] = 3 }),
        ("speak to chat", { $0.setSpeakToChat(true) }, { $0.speakToChat == true }, { $0.speakToChat = true })
    ]
    for (name, edit, holds, report) in cases {
        let model = PopoverModel(); let initial = state(t0); model.apply(AppReply(state: initial))
        edit(model)
        model.handle(AppReply(state: initial, stale: true), for: .setMode(.ambient))
        guard holds(model.viewState) else { print("    P1 \(name): stale reply replaced the local value"); return false }
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard model.actionIsTakingTime else { print("    P1 \(name): stale reply ended the action wait"); return false }
        model.handle(AppReply(state: state(t1)), for: .status)
        guard holds(model.viewState) else { print("    P1 \(name): old headset report replaced the local value"); return false }
        var resolved = state(t2); report(&resolved)
        model.handle(AppReply(state: resolved), for: .status)
        guard holds(model.viewState), !model.actionIsTakingTime else { print("    P1 \(name): matching headset report did not resolve the edit"); return false }
    }
    return true
}

@MainActor func testPendingEditsEndOnFailureErrorSocketLossOrCap() async -> Bool {
    let state = AppState(connectionStatus: "connected", ambient: AppAmbient(mode: "ambient", level: 5, focus: false, subtype: 0x19), stateAsOf: Date(timeIntervalSince1970: 2_000))
    let failed = PopoverModel(pendingWriteCap: 0.3); failed.apply(AppReply(state: state)); failed.selectMode(.nc)
    failed.handle(AppReply(state: AppState(connectionStatus: "failed", ambient: state.ambient, stateAsOf: Date(timeIntervalSince1970: 2_001))), for: .setMode(.nc))
    guard failed.viewState.mode == .nc, failed.viewState.connection != .connected else { print("    P2: failed reply dropped the pending edit"); return false }
    try? await Task.sleep(nanoseconds: 500_000_000)
    guard failed.viewState.mode == .ambient, !failed.actionIsTakingTime else { print("    P2: cap did not end the edit kept across a failed reply"); return false }
    let rejected = PopoverModel(pendingWriteCap: 0.3); rejected.apply(AppReply(state: state)); rejected.selectMode(.nc)
    rejected.handle(AppReply(state: state, error: "rejected command"), for: .setMode(.nc))
    guard rejected.viewState.mode == .ambient, rejected.viewState.commandError == "rejected command", !rejected.actionIsTakingTime else { print("    P2: error reply did not end pending edits"); return false }
    let lost = PopoverModel(pendingWriteCap: 0.3); lost.apply(AppReply(state: state)); lost.selectMode(.nc); lost.apply(error: SocketClientError.unavailable)
    try? await Task.sleep(nanoseconds: 500_000_000)
    guard lost.viewState.placeholderTitle == "Agent not running", !lost.actionIsTakingTime else { print("    P2: socket loss cap changed the error view"); return false }
    let capped = PopoverModel(pendingWriteCap: 0.3); capped.apply(AppReply(state: state)); capped.selectMode(.nc)
    try? await Task.sleep(nanoseconds: 500_000_000)
    guard capped.viewState.mode == .ambient, !capped.actionIsTakingTime else { print("    P2: pending-write cap did not restore the last snapshot"); return false }
    return true
}

@MainActor func testPresetReplacesAPendingBandEdit() async -> Bool {
    let t0 = Date(timeIntervalSince1970: 4_000), t1 = Date(timeIntervalSince1970: 4_001), t2 = Date(timeIntervalSince1970: 4_002)
    let heavyBands = [3, 2, 0, 0, -1, 0, 1, 2, 3, 4]
    let model = PopoverModel(); var commands: [AppCommand] = []; model.onCommand = { commands.append($0) }
    model.apply(AppReply(state: AppState(connectionStatus: "connected", equalizer: AppEqualizer(presetCode: Int(EqualizerPreset.custom.rawValue), bands: Array(repeating: 0, count: 10), subtype: 4), stateAsOf: t0)))
    model.editBand(0, value: 5); model.selectPreset(.heavy)
    try? await Task.sleep(nanoseconds: 600_000_000)
    guard commands == [.setEQPreset(Int(EqualizerPreset.heavy.rawValue))] else { print("    FIX1: a band write was sent after the preset: \(commands)"); return false }
    guard model.actionIsTakingTime else { print("    FIX1: the preset write showed no wait"); return false }
    model.handle(AppReply(state: AppState(connectionStatus: "connected", equalizer: AppEqualizer(presetCode: Int(EqualizerPreset.heavy.rawValue), bands: heavyBands, subtype: 4), stateAsOf: t1)), for: .status)
    guard model.viewState.preset == .heavy, model.viewState.bands == heavyBands, !model.actionIsTakingTime else { print("    FIX1: the Heavy report did not resolve the preset over the band edit"); return false }
    let later = [1, 1, 1, 1, 1, 1, 1, 1, 1, 1]
    model.handle(AppReply(state: AppState(connectionStatus: "connected", equalizer: AppEqualizer(presetCode: Int(EqualizerPreset.custom.rawValue), bands: later, subtype: 4), stateAsOf: t2)), for: .status)
    guard model.viewState.preset == .custom, model.viewState.bands == later else { print("    FIX1: an edit stayed pending after the Heavy report"); return false }
    return true
}

@MainActor func testCommandWithoutAFieldEditEndsItsWait() async -> Bool {
    let t0 = Date(timeIntervalSince1970: 5_000), t1 = Date(timeIntervalSince1970: 5_001)
    let model = PopoverModel(); model.apply(AppReply(state: AppState(connectionStatus: "connected", stateAsOf: t0)))
    model.send(.cycle)
    model.handle(AppReply(state: AppState(connectionStatus: "connected", stateAsOf: t0), stale: true), for: .cycle)
    model.handle(AppReply(state: AppState(connectionStatus: "connected", stateAsOf: t0)), for: .status)
    try? await Task.sleep(nanoseconds: 600_000_000)
    guard model.actionIsTakingTime else { print("    FIX3: a reply with the send-time snapshot ended the wait"); return false }
    model.handle(AppReply(state: AppState(connectionStatus: "connected", stateAsOf: t1)), for: .status)
    guard !model.actionIsTakingTime else { print("    FIX3: a newer report did not end the wait"); return false }
    let capped = PopoverModel(pendingWriteCap: 0.3); capped.apply(AppReply(state: AppState(connectionStatus: "connected", stateAsOf: t0)))
    capped.send(.cycle)
    try? await Task.sleep(nanoseconds: 600_000_000)
    guard !capped.actionIsTakingTime else { print("    FIX3: the cap did not end a field-less command's wait"); return false }
    return true
}

@MainActor func testCommandErrorIsShownWhateverTheStatus() -> Bool {
    let t0 = Date(timeIntervalSince1970: 3_000), t1 = Date(timeIntervalSince1970: 3_001)
    let state = AppState(connectionStatus: "connected", stateAsOf: t0)
    let model = PopoverModel(); model.handle(AppReply(state: state, error: "playback device is not connected"), for: .switchPlayback(macAddress: "B"))
    guard model.viewState.commandError == "playback device is not connected" else { print("    connected error reply was hidden"); return false }
    model.handle(AppReply(state: state), for: .status)
    guard model.viewState.commandError == "playback device is not connected" else { print("    same snapshot cleared the error"); return false }
    model.handle(AppReply(state: AppState(connectionStatus: "connected", stateAsOf: t1)), for: .status)
    guard model.viewState.commandError == nil else { print("    newer snapshot did not clear the error"); return false }
    model.handle(AppReply(state: AppState(connectionStatus: "connected", stateAsOf: t1), error: "again"), for: .status); model.send(.status)
    guard model.viewState.commandError == "again" else { print("    status command cleared the error"); return false }
    model.send(.setMode(.nc))
    guard model.viewState.commandError == nil else { print("    write command did not clear the error"); return false }
    return true
}

@MainActor func testPlaceholderShowsTheAgentsDiagnosis() -> Bool {
    let failed = PopoverModel.map(AppState(connectionStatus: "failed", lastError: "No paired WH-1000XM6 found"))
    guard failed.placeholderTitle == "No paired WH-1000XM6 found", failed.agentReachable, failed.placeholderDetail == nil else { print("    P4: failed-state diagnosis was not exposed"); return false }
    guard PopoverModel.map(AppState(connectionStatus: "disconnected")).placeholderTitle == "Headphones not connected" else { print("    P4: disconnected diagnosis is wrong"); return false }
    guard PopoverViewState().placeholderTitle == "Connecting to agent…" else { print("    P4: fresh placeholder is wrong"); return false }
    let model = PopoverModel(); model.apply(error: SocketClientError.timeout)
    guard model.viewState.placeholderTitle == "Agent not running", !model.viewState.agentReachable, model.viewState.placeholderDetail != nil else { print("    P4: socket-error placeholder is wrong"); return false }
    return true
}

@MainActor func testControlsNeverInventValues() -> Bool {
    let view = PopoverModel.map(AppState(connectionStatus: "connected", battery: AppBattery(level: 50, charging: false)))
    guard !view.focusToggleEnabled, !view.stcToggleEnabled, view.mode == nil, view.preset == nil else { print("    P5: controls invented an unavailable headset value"); return false }
    guard let focus = try? String(data: AppRequestEncoder.data(for: .setFocus(true)), encoding: .utf8), focus == "{\"cmd\":\"set_focus\",\"enabled\":true}", let level = try? String(data: AppRequestEncoder.data(for: .setAmbientLevel(25)), encoding: .utf8), level == "{\"cmd\":\"set_ambient_level\",\"level\":20}" else { print("    P5: focused ambient encoders are wrong"); return false }
    return true
}

func testAppReplyDecodesStale() async -> Bool {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let state = AppState(connectionStatus: "connected")
    guard let staleData = try? encoder.encode(AppReply(state: state, stale: true)) else { print("    P6: could not encode stale fixture"); return false }
    do {
        let stale = try await SocketClient(transport: ImmediateTransport(result: .success(staleData))).request(.status)
        guard stale.stale else { print("    P6: stale field was not decoded"); return false }
        guard var object = try JSONSerialization.jsonObject(with: staleData) as? [String: Any] else { print("    P6: stale fixture is not an object"); return false }
        object.removeValue(forKey: "stale")
        let freshData = try JSONSerialization.data(withJSONObject: object)
        let fresh = try await SocketClient(transport: ImmediateTransport(result: .success(freshData))).request(.status)
        guard !fresh.stale else { print("    P6: absent stale field did not default false"); return false }
    } catch { print("    P6: socket fixture failed: \(error)"); return false }
    return true
}
