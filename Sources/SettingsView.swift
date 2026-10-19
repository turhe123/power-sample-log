import SwiftUI
import ServiceManagement

/// Settings window: interval, default folder, auto-stop, rotation, columns and launch at login.
struct SettingsView: View {
    @AppStorage(Prefs.interval) private var interval = 5
    @AppStorage(Prefs.autoStopMinutes) private var autoStopMinutes = 0
    @AppStorage(Prefs.autoStopBattery) private var autoStopBattery = 0
    @AppStorage(Prefs.rotate) private var rotate = false
    @AppStorage(Prefs.disabledColumns) private var disabledColumns = ""
    @State private var folder: URL? = DefaultFolder.resolve()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Sampling") {
                Picker("Interval", selection: $interval) {
                    ForEach([1, 5, 10, 60], id: \.self) { Text("Every \($0) s").tag($0) }
                }
                LabeledContent("Default folder") {
                    HStack {
                        Text(folder?.path(percentEncoded: false) ?? "Documents").lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Toggle("Start a new file every 50 MB", isOn: $rotate)
            }
            Section("Auto-stop") {
                Stepper(value: $autoStopMinutes, in: 0...1440, step: 5) {
                    Text(autoStopMinutes == 0 ? "After duration: off" : "After \(autoStopMinutes) minutes")
                }
                Stepper(value: $autoStopBattery, in: 0...100, step: 5) {
                    Text(autoStopBattery == 0 ? "At battery level: off" : "When battery reaches \(autoStopBattery)%")
                }
            }
            Section("Columns") {
                ForEach(Column.allCases.filter { !$0.isRequired }) { column in
                    Toggle(column.title, isOn: binding(for: column))
                }
                Text("Timestamp and Note are always included. Macs without a battery record only thermal columns.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Text("The Mac may sleep while recording; a GAP marker row is written on wake.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Support / Donate ❤️") { Support.open() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 600)
    }

    private func binding(for column: Column) -> Binding<Bool> {
        Binding {
            !disabledSet.contains(column.rawValue)
        } set: { on in
            var set = disabledSet
            if on { set.remove(column.rawValue) } else { set.insert(column.rawValue) }
            disabledColumns = set.sorted().joined(separator: ",")
        }
    }

    private var disabledSet: Set<String> {
        Set(disabledColumns.split(separator: ",").map(String.init))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        DefaultFolder.save(url)
        folder = url
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn’t update login item: \(error.localizedDescription). You can manage it in System Settings › General › Login Items."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
