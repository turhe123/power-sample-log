import SwiftUI

/// The menu bar popover: status, start/stop, live stats, last sample and the marker field.
struct ContentView: View {
    @EnvironmentObject private var recorder: Recorder
    @AppStorage(Prefs.sessionCount) private var sessionCount = 0
    @AppStorage(Prefs.sessionName) private var sessionName = ""
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if !recorder.isRecording && sessionCount == 0 {
                emptyState
            } else {
                stats
                if let s = recorder.lastSample { SampleGrid(sample: s) }
                markerField
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Circle().fill(recorder.isRecording ? Color.red : Color.secondary).frame(width: 10, height: 10)
            Text(recorder.isRecording ? "Recording" : "Idle").font(.headline)
            Spacer()
            Button(recorder.isRecording ? "Stop" : "Start") { recorder.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .accentColor)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis").font(.largeTitle).foregroundStyle(.secondary)
            Text("No sessions yet").font(.headline)
            Text("Record battery, power and thermal samples to a CSV file.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            sessionNameField
            Button("Start Session") { recorder.start() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
    }

    private var sessionNameField: some View {
        TextField("Session name", text: $sessionName).textFieldStyle(.roundedBorder)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !recorder.isRecording { sessionNameField }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack {
                    stat("Elapsed", elapsed(at: context.date))
                    stat("Rows", "\(recorder.rowCount)")
                    stat("Size", ByteCountFormatter.string(fromByteCount: Int64(recorder.fileSize), countStyle: .file))
                }
            }
            if let url = recorder.fileURL {
                Button { recorder.revealFile() } label: {
                    Label(url.lastPathComponent, systemImage: "doc.text").lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.link).font(.caption)
            }
        }
    }

    private var markerField: some View {
        HStack {
            TextField("Marker, e.g. Started render", text: $recorder.markerText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { recorder.addMarker() }
            Button("Add") { recorder.addMarker() }
                .keyboardShortcut("m", modifiers: [.command, .option])
        }
        .disabled(!recorder.isRecording)
    }

    private var footer: some View {
        HStack {
            Button("Support / Donate ❤️") { Support.open() }
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: { Image(systemName: "gearshape") }
                .help("Settings…")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit PowerSampleLog")
        }
        .buttonStyle(.borderless)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func elapsed(at now: Date) -> String {
        guard let start = recorder.startDate else { return "0:00:00" }
        let end = recorder.isRecording ? now : (recorder.lastSample?.timestamp ?? start)
        let t = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }
}

/// Compact grid of the most recent sample's values.
private struct SampleGrid: View {
    let sample: PowerSample

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            if sample.hasBattery {
                row("Battery", sample.batteryPercent.map { "\($0)%" } ?? "—",
                    "Power", sample.watts.map { String(format: "%.2f W", $0) } ?? "—")
                row("Voltage", sample.voltage.map { String(format: "%.2f V", $0) } ?? "—",
                    "Current", sample.amperage.map { String(format: "%.2f A", $0) } ?? "—")
                row("Temp", sample.temperature.map { String(format: "%.1f °C", $0) } ?? "—",
                    "Cycles", sample.cycleCount.map(String.init) ?? "—")
                row("Adapter", yesNo(sample.adapterConnected), "Charging", yesNo(sample.isCharging))
            } else {
                Text("No battery — thermal columns only").font(.caption).foregroundStyle(.secondary)
            }
            row("Thermal", sample.thermalState.capitalized, "Low Power", yesNo(sample.lowPowerMode))
        }
        .font(.caption)
    }

    private func yesNo(_ b: Bool?) -> String { b.map { $0 ? "Yes" : "No" } ?? "—" }

    private func row(_ k1: String, _ v1: String, _ k2: String, _ v2: String) -> some View {
        GridRow {
            Text(k1).foregroundStyle(.secondary)
            Text(v1).monospacedDigit()
            Text(k2).foregroundStyle(.secondary)
            Text(v2).monospacedDigit()
        }
    }
}
