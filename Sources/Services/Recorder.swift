import AppKit
import UniformTypeIdentifiers

/// UserDefaults keys shared by `@AppStorage` views and the recorder.
enum Prefs {
    static let interval = "interval"
    static let folderBookmark = "defaultFolderBookmark"
    static let autoStopMinutes = "autoStopMinutes"
    static let autoStopBattery = "autoStopBattery"
    static let rotate = "rotateAt50MB"
    static let disabledColumns = "disabledColumns"
    static let sessionName = "sessionName"
    static let sessionCount = "sessionCount"
}

/// Owns the open CSV file. Only ever touched on the recorder's background queue.
private final class CSVFile {
    private(set) var url: URL
    private var handle: FileHandle
    private(set) var size: UInt64
    private let header: String

    init(url: URL, header: String, append: Bool) throws {
        let fm = FileManager.default
        let writeHeader = !append || !fm.fileExists(atPath: url.path)
        if writeHeader { guard fm.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) } }
        self.url = url
        self.header = header
        handle = try FileHandle(forWritingTo: url)
        size = try handle.seekToEnd()
        if writeHeader { try write(header) }
    }

    func write(_ line: String) throws {
        let data = Data((line + "\n").utf8)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        size += UInt64(data.count)
    }

    /// Closes the current file and continues in `name-partN.csv` beside it, never overwriting.
    func rotate() throws {
        try handle.close()
        let dir = url.deletingLastPathComponent()
        var base = url.deletingPathExtension().lastPathComponent
        if let r = base.range(of: #"-part\d+$"#, options: .regularExpression) { base.removeSubrange(r) }
        var n = 2
        var next = dir.appendingPathComponent("\(base)-part\(n).csv")
        while FileManager.default.fileExists(atPath: next.path) {
            n += 1
            next = dir.appendingPathComponent("\(base)-part\(n).csv")
        }
        guard FileManager.default.createFile(atPath: next.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
        url = next
        handle = try FileHandle(forWritingTo: next)
        size = 0
        try write(header)
    }

    func close() { try? handle.close() }
}

/// Runs a recording session: samples on a timer, appends CSV rows, handles markers, auto-stop, rotation and sleep gaps.
@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()
    nonisolated static let rotateLimit: UInt64 = 50 * 1024 * 1024

    @Published private(set) var isRecording = false
    @Published private(set) var startDate: Date?
    @Published private(set) var rowCount = 0
    @Published private(set) var fileSize: UInt64 = 0
    @Published private(set) var fileURL: URL?
    @Published private(set) var lastSample: PowerSample?
    @Published var markerText = ""

    private let queue = DispatchQueue(label: "com.turhe123.powersamplelog.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    /// State owned by `queue`; only read or written from blocks running on it.
    private final class IOState { var file: CSVFile?; var columns: [Column] = []; var rotate = false }
    nonisolated private let io = IOState()
    private var columns: [Column] = []
    private var stopBelow: Int?
    private var stopAbove: Int?
    private var stopAt: Date?
    private var sleepDate: Date?
    private let defaults = UserDefaults.standard

    private init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepDate = Date() }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
    }

    func toggle() { isRecording ? stop() : start() }

    // MARK: Session lifecycle

    /// Asks for a destination with a save panel, then begins sampling.
    func start() {
        guard !isRecording else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "New Recording Session"
        panel.prompt = "Start Recording"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let name = defaults.string(forKey: Prefs.sessionName).flatMap { $0.isEmpty ? nil : $0 } ?? "Power Session"
        panel.nameFieldStringValue = "\(name) \(Self.stamp()).csv"
        panel.directoryURL = DefaultFolder.resolve() ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // The save panel already confirmed replacement; offer appending in place as the safer choice.
        var append = false
        if FileManager.default.fileExists(atPath: url.path) {
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” already exists"
            alert.informativeText = "Append new rows to the end of the existing file, or replace its contents?"
            alert.addButton(withTitle: "Append")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: append = true
            case .alertSecondButtonReturn: append = false
            default: return
            }
        }
        begin(at: url, append: append)
    }

    private func begin(at url: URL, append: Bool) {
        let disabled = Set((defaults.string(forKey: Prefs.disabledColumns) ?? "").split(separator: ",").map(String.init))
        let battery = PowerSampler.hasBattery
        columns = Column.allCases.filter { ($0.isRequired || !disabled.contains($0.rawValue)) && (battery || !$0.needsBattery) }
        let header = columns.map(\.rawValue).joined(separator: ",")

        let file: CSVFile
        do {
            file = try CSVFile(url: url, header: header, append: append)
        } catch {
            showError("Couldn’t open the file for writing.", error)
            return
        }
        let cols = columns, rotate = defaults.bool(forKey: Prefs.rotate), io = io
        queue.sync { io.file = file; io.columns = cols; io.rotate = rotate }
        let first = PowerSampler.read()
        let minutes = defaults.integer(forKey: Prefs.autoStopMinutes)
        stopAt = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        stopBelow = nil; stopAbove = nil
        let level = defaults.integer(forKey: Prefs.autoStopBattery)
        if level > 0, let pct = first.batteryPercent {
            if pct > level { stopBelow = level } else if pct < level { stopAbove = level }
        }

        fileURL = url
        fileSize = file.size
        rowCount = 0
        startDate = Date()
        isRecording = true
        defaults.set(defaults.integer(forKey: Prefs.sessionCount) + 1, forKey: Prefs.sessionCount)
        if !battery { addMarker("No battery detected — recording thermal columns only") }

        let interval = [1, 5, 10, 60].contains(defaults.integer(forKey: Prefs.interval)) ? defaults.integer(forKey: Prefs.interval) : 5
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(interval), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    /// Stops sampling and closes the file.
    func stop() {
        guard isRecording else { return }
        timer?.cancel()
        timer = nil
        let io = io
        queue.async { io.file?.close(); io.file = nil }
        isRecording = false
    }

    // MARK: Rows

    /// Writes a marker row with a note so events can be lined up with the data.
    func addMarker(_ text: String? = nil) {
        guard isRecording else { return }
        let note = (text ?? markerText).trimmingCharacters(in: .whitespacesAndNewlines)
        let finalNote = note.isEmpty ? "Marker" : note
        if text == nil { markerText = "" }
        queue.async { [weak self] in self?.writeRow(PowerSampler.read(), note: finalNote, isSample: false) }
    }

    nonisolated private func tick() {
        let sample = PowerSampler.read()
        writeRow(sample, note: "", isSample: true)
    }

    /// Runs on `queue`. Formats and appends one row, then reports back to the main actor.
    nonisolated private func writeRow(_ sample: PowerSample, note: String, isSample: Bool) {
        guard let f = io.file else { return }
        let line = io.columns.map { csvEscape($0.value(for: sample, note: note)) }.joined(separator: ",")
        do {
            if io.rotate && f.size >= Recorder.rotateLimit { try f.rotate() }
            try f.write(line)
            let size = f.size, url = f.url
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.didWrite(sample, size: size, url: url, isSample: isSample) }
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isRecording else { return }
                    self.stop()
                    self.showError("Recording stopped: the file is no longer writable (the disk may be full or the volume was ejected).", error)
                }
            }
        }
    }

    private func didWrite(_ sample: PowerSample, size: UInt64, url: URL, isSample: Bool) {
        guard isRecording else { return }
        rowCount += 1
        fileSize = size
        fileURL = url
        if isSample { lastSample = sample }
        if let stopAt, Date() >= stopAt { autoStop("duration reached"); return }
        if let pct = sample.batteryPercent {
            if let stopBelow, pct <= stopBelow { autoStop("battery reached \(pct)%") }
            else if let stopAbove, pct >= stopAbove { autoStop("battery reached \(pct)%") }
        }
    }

    private func autoStop(_ reason: String) {
        let note = "Auto-stop: \(reason)"
        let io = io
        queue.async {
            let sample = PowerSampler.read()
            try? io.file?.write(io.columns.map { csvEscape($0.value(for: sample, note: note)) }.joined(separator: ","))
        }
        stop()
    }

    private func handleWake() {
        guard isRecording else { sleepDate = nil; return }
        let from = sleepDate.map { $0.formatted(date: .omitted, time: .standard) } ?? "unknown"
        addMarker("GAP: Mac slept from \(from) to \(Date().formatted(date: .omitted, time: .standard))")
        sleepDate = nil
    }

    // MARK: Helpers

    func revealFile() {
        if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
    }

    private func showError(_ message: String, _ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return f.string(from: Date())
    }
}

/// Stores the default save folder as a (security-scoped when possible) bookmark.
enum DefaultFolder {
    static func save(_ url: URL) {
        let data = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        UserDefaults.standard.set(data, forKey: Prefs.folderBookmark)
    }

    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Prefs.folderBookmark) else { return nil }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        _ = url?.startAccessingSecurityScopedResource()
        if stale, let url { save(url) }
        return url
    }
}
