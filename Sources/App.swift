import SwiftUI

/// App entry point: a window-style menu bar extra plus a Settings scene.
@main
struct PowerSampleLogApp: App {
    @StateObject private var recorder = Recorder.shared

    init() {
        HotKeys.register()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(recorder)
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "bolt.batteryblock")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

/// Opens the project's donation page.
enum Support {
    static func open() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
    }
}
