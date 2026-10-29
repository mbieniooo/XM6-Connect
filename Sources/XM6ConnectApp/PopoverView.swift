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

// This file contains the reusable popover view so it can live in
// XM6ConnectAppLogic and be reachable from the test target. Only the @main
// entry point has to stay outside a library, and it is the one thing with no
// behaviour worth testing.
public struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    @ObservedObject var login: LoginItemCoordinator
    /// Public so the test target can construct and render the real view offscreen;
    /// the memberwise initializer would otherwise be internal.
    public init(model: PopoverModel, login: LoginItemCoordinator) {
        self.model = model; self.login = login
    }
    @State private var ambientLevel = 1
    @State private var bands = Array(repeating: 0, count: 10)
    public var body: some View {
            // Show controls whenever the headset state is known. Under the lease the
            // resting state is "released", which is normal operation — treating anything
            // but "connected" as a failure left the popover empty almost always.
            Group { if model.viewState.hasDeviceState { ScrollView { VStack(alignment: .leading, spacing: 12) { leaseStatusRow; noiseCard; listeningModeCard; batteryRow; equalizerCard; stcRow; multipointCard; loginItemFooter }.padding(14) }.frame(maxHeight: maximumScrollHeight).fixedSize(horizontal: false, vertical: true) } else { VStack { disconnected; loginItemFooter } } }
            .padding(.top, PopoverLayout.topInset)
            .onReceive(model.$viewState) { ambientLevel = $0.ambientLevel; bands = $0.bands }
    }
    private var noiseCard: some View { card { VStack(alignment: .leading, spacing: 8) {
        Label("Noise control", systemImage: "waveform.circle.fill").font(.headline)
        Picker("Mode", selection: Binding(get: { model.viewState.mode }, set: { if let mode = $0 { model.selectMode(mode) } })) { Text("NC").tag(AppMode.nc as AppMode?); Text("Ambient").tag(AppMode.ambient as AppMode?); Text("Off").tag(AppMode.off as AppMode?) }.pickerStyle(.segmented).labelsHidden()
        HStack { Text("Ambient level"); Slider(value: Binding(get: { Double(ambientLevel) }, set: { ambientLevel = Int($0.rounded()); model.settleAmbientLevel(ambientLevel) }), in: 1...20, step: 1).disabled(!model.viewState.ambientSliderEnabled); Text("\(ambientLevel)").monospacedDigit().frame(width: 24) }
        Toggle("Focus on voice", isOn: Binding(get: { model.viewState.focusOnVoice }, set: { model.setFocus($0) })).disabled(!model.viewState.focusToggleEnabled)
    } } }
    /// All enablement and selection decisions live in `PopoverViewState`; this is
    /// deliberately only a projection so the behavior remains in XM6ConnectAppLogic.
    private var listeningModeCard: some View { card { VStack(alignment: .leading, spacing: 8) {
        Label("Listening mode", systemImage: "speaker.wave.3.fill").font(.headline)
        Picker("Mode", selection: Binding(get: { model.viewState.selectedListeningMode }, set: { if let mode = $0 { model.selectListeningMode(mode) } })) {
            ForEach(ListeningMode.allCases) { mode in Text(mode.label).tag(mode as ListeningMode?) }
        }.pickerStyle(.segmented).labelsHidden()
        Picker("Room size", selection: Binding(get: { model.viewState.bgmRoomSize }, set: { if let roomSize = $0 { model.selectBGMRoomSize(roomSize) } })) {
            ForEach(BGMRoomSize.allCases) { roomSize in Text(roomSize.label).tag(roomSize as BGMRoomSize?) }
        }.pickerStyle(.menu).disabled(!model.viewState.bgmRoomSizeEnabled)
    } } }
    /// One honest line about who holds the control channel, so "released" reads as
    /// normal rather than broken.
    private var leaseStatusRow: some View {
        Group {
            if model.actionIsTakingTime {
                Text("Working…").font(.caption2).foregroundStyle(.secondary)
            } else if let error = model.viewState.commandError {
                Text(error).font(.caption2).foregroundStyle(.secondary)
            } else if case .disconnected(let message) = model.viewState.connection {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private var batteryRow: some View { HStack { Image(systemName: model.viewState.charging ? "battery.100.bolt" : "battery.100"); Text(model.viewState.batteryLevel.map { "\($0)%" } ?? "—"); Spacer(); Text(model.lastSnapshot.deviceName ?? "XM6-Connect").foregroundStyle(.secondary) }.padding(.horizontal, 4) }
    private var equalizerCard: some View { card { VStack(alignment: .leading, spacing: 8) {
        Label("Equalizer", systemImage: "slider.vertical.3").font(.headline)
        Picker("Preset", selection: Binding(get: { model.viewState.preset }, set: { if let preset = $0 { model.selectPreset(preset) } })) { ForEach(EqualizerPreset.allCases) { Text($0.label).tag($0 as EqualizerPreset?) } }.pickerStyle(.menu)
        HStack(alignment: .bottom, spacing: PopoverLayout.eqBandSpacing) { ForEach(0..<PopoverLayout.eqBandCount, id: \.self) { index in VStack { Slider(value: Binding(get: { Double(bands[index]) }, set: { bands[index] = Int($0.rounded()); model.editBand(index, value: bands[index]) }), in: -6...6, step: 1).frame(width: PopoverLayout.eqSliderHeight).rotationEffect(.degrees(-90)).frame(width: PopoverLayout.eqBandColumnWidth, height: PopoverLayout.eqSliderHeight).disabled(!model.viewState.eqBandsEnabled); Text("\(bands[index])").font(.caption2).frame(width: PopoverLayout.eqBandColumnWidth) } } }
    } } }
    private var stcRow: some View { Toggle(isOn: Binding(get: { model.viewState.speakToChat ?? false }, set: { model.setSpeakToChat($0) })) { Label("Speak to chat", systemImage: "bubble.left.and.bubble.right") }.disabled(!model.viewState.stcToggleEnabled).padding(.horizontal, 4) }
    private var multipointCard: some View { card { VStack(alignment: .leading, spacing: 6) {
        Label("Multipoint", systemImage: "dot.radiowaves.left.and.right").font(.headline)
        ForEach(model.viewState.multipointRows) { row in
            Button { model.switchPlayback(to: row) } label: {
                HStack {
                    Image(systemName: row.isPlayback ? "play.fill" : "circle").font(.caption)
                    Text(row.name)
                    Spacer()
                    if row.isPlayback { Text("Playing").font(.caption).foregroundStyle(.secondary) }
                    Image(systemName: row.connected ? "checkmark" : "xmark.circle").foregroundStyle(row.connected ? .primary : .secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(!row.isActionable)
            .opacity(row.connected ? 1 : 0.5)
            .accessibilityLabel("\(row.name), \(row.isPlayback ? "playing" : row.connected ? "connected" : "not connected")")
        }
    } } }
    /// A ScrollView takes whatever height it is offered, and the menu-bar window offers its
    /// own current height, so the scroll area reports its content height itself. It is
    /// capped at the usable screen height so a short display can still scroll.
    private var maximumScrollHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 60 }
    private var disconnected: some View {
        let action = PlaceholderAction.for(socketUnreachable: model.socketUnreachable, agentJob: login.agentJob)
        return VStack(spacing: 12) {
            Image(systemName: "headphones").font(.largeTitle).foregroundStyle(.secondary)
            Text(model.viewState.placeholderTitle).font(.headline)
            if let detail = model.viewState.placeholderDetail { Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary) }
            Button(action.title) {
                switch action {
                case .reconnect: model.send(.reconnect)
                case .startAgent: login.startAgent(then: { model.send(.status) })
                case .enableLoginItem: login.set(true, then: { model.send(.status) })
                }
            }.buttonStyle(.borderedProminent).disabled(action != .reconnect && login.isBusy)
        }.padding(24).frame(width: PopoverLayout.popoverWidth)
    }
    private var loginItemFooter: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Start XM6-Connect at login", isOn: Binding(get: { login.status.isEnabled }, set: { login.set($0) })).disabled(login.isBusy)
            Text(login.failure ?? login.status.caption).font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 4).padding(.bottom, 8)
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View { content().padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
}
