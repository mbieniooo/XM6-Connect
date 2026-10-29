import SwiftUI
import WidgetKit
#if canImport(SonyHeadphonesKit)
import SonyHeadphonesKit
#endif

struct XM6ConnectWidgetEntry: TimelineEntry {
    let date: Date
    let model: XM6ConnectWidgetViewModel
}

struct XM6ConnectWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> XM6ConnectWidgetEntry {
        XM6ConnectWidgetEntry(date: .now, model: .unavailable)
    }
    func getSnapshot(in context: Context, completion: @escaping (XM6ConnectWidgetEntry) -> Void) {
        completion(entry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<XM6ConnectWidgetEntry>) -> Void) {
        // A timeline refresh updates the display only; it does not acquire a control lease.
        let now = Date.now
        let current = entry(now: now)
        let entries = XM6ConnectWidgetLogic.timelineDates(for: current.model, now: now).map { entry(now: $0) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
    private func entry(now: Date = .now) -> XM6ConnectWidgetEntry {
        let model = XM6ConnectStateReader.agentStateURL().map { XM6ConnectStateReader.readViewModel(from: $0, now: now) } ?? .unavailable
        return XM6ConnectWidgetEntry(date: now, model: model)
    }
}

struct XM6ConnectDesktopWidget: Widget {
    static let kind = "io.github.mbieniooo.xm6connect.widget"
    let kind = Self.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: XM6ConnectWidgetProvider()) { entry in
            XM6ConnectWidgetView(entry: entry)
        }
        .configurationDisplayName("XM6-Connect")
        .description("Choose noise control and equalizer presets.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct XM6ConnectWidgetView: View {
    let entry: XM6ConnectWidgetEntry
    @Environment(\.widgetFamily) private var family
    // Desktop widgets often render tinted on macOS, where colour alone cannot carry
    // meaning. Selection is carried by weight and an outline; `pill` keeps the
    // selected label readable in every rendering mode.
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        // The system's content margins are the only padding; each layout fills the rest of
        // the height itself.
        Group {
            if family == .systemMedium { mediumLayout } else { smallLayout }
        }
        .opacity(entry.model.freshness == .stale ? 0.55 : 1)
        .containerBackground(for: .widget) { Color.clear }
    }

    // The mode row has priority so that, if space runs short, its labels are never the
    // ones scaled down.
    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(showsMode: true)
            modeRow.layoutPriority(1)
            presetRow
        }
    }

    // The small widget holds one group, so the three modes are stacked full width under
    // the battery and share the height between them. Their own labels name the current
    // mode, which the header has too little width to spell out beside the battery.
    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(showsMode: false)
            VStack(spacing: 5) {
                modeButton("Noise Cancelling", .noiseCancelling, selected: entry.model.selectedMode == .noiseCancelling, fillsHeight: true)
                modeButton("Ambient", .ambient, selected: entry.model.selectedMode == .ambient, fillsHeight: true)
                modeButton("Off", .off, selected: entry.model.selectedMode == .off, fillsHeight: true)
            }
        }
    }

    private func header(showsMode: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: entry.model.charging ? "battery.100.bolt" : "battery.100")
            Text(entry.model.batteryLevel.map { "\($0)%" } ?? "—").monospacedDigit()
            Spacer()
            if showsMode { Text(modeTitle(entry.model.selectedMode)).fontWeight(.semibold) }
            if entry.model.freshness == .stale {
                Image(systemName: "clock.badge.exclamationmark").accessibilityLabel("State may be stale")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func modeTitle(_ mode: XM6ConnectWidgetMode?) -> String {
        switch mode {
        case .noiseCancelling: return "Noise Cancelling"
        case .ambient: return "Ambient"
        case .off: return "Off"
        case nil: return "—"
        }
    }

    private var modeRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Noise control").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                modeButton("Noise Cancel", .noiseCancelling, selected: entry.model.selectedMode == .noiseCancelling)
                modeButton("Ambient", .ambient, selected: entry.model.selectedMode == .ambient)
                modeButton("Off", .off, selected: entry.model.selectedMode == .off)
            }
        }
    }

    // Four columns keeps every preset legible in a medium widget; a single row of
    // seven collapsed into an unreadable strip.
    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Equalizer").font(.caption2).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(EqualizerPreset.allCases) { presetButton($0) }
            }
        }
    }

    private func modeButton(_ title: String, _ action: XM6ConnectDarwinNotification.Action, selected: Bool, fillsHeight: Bool = false) -> some View {
        Link(destination: XM6ConnectDarwinNotification.url(for: action)) {
            pill(title, selected: selected, font: .caption2, fillsHeight: fillsHeight)
        }
    }

    private func presetButton(_ preset: EqualizerPreset) -> some View {
        Link(destination: XM6ConnectDarwinNotification.url(for: .equalizer(preset))) {
            pill(preset.label, selected: entry.model.selectedPreset == preset, font: .caption2)
        }
    }

    /// One label style for every button. In full color the selected pill is filled with
    /// the tint and its text uses the background color. In the accented and vibrant modes
    /// the system draws fill and text in the same color, so the selected pill is a
    /// translucent fill with an outline and its text stays in the primary style.
    private func pill(_ title: String, selected: Bool, font: Font, fillsHeight: Bool = false) -> some View {
        Text(title)
            .font(font)
            .fontWeight(selected ? .bold : .regular)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil)
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
            .background {
                Capsule().fill(selected ? (renderingMode == .fullColor ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.25))) : AnyShapeStyle(.quaternary))
            }
            .foregroundStyle(selected && renderingMode == .fullColor ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            .overlay {
                if selected { Capsule().strokeBorder(.primary, lineWidth: 1) }
            }
    }
}

@main
struct XM6ConnectWidgetBundle: WidgetBundle {
    var body: some Widget { XM6ConnectDesktopWidget() }
}
