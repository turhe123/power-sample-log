# PowerSampleLog — specification

**Tagline:** Log battery, power and thermal samples to a CSV file you can open in a spreadsheet.

**Category:** System Monitoring

**Inspired by (paid):** iStatistica Pro ($9.99 one-time)

**Frameworks:** SwiftUI, AppKit, IOKit, UniformTypeIdentifiers, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

(1) What the paid app does and demand. iStatistica Pro is a Mac App Store system monitor listed at 9.99 dollars. It offers menu bar monitors for battery, CPU and more, and its comparison articles against iStat Menus highlight data export to CSV and a remote web view as reasons to pick it. Many people who test a battery, a charger or a heavy workload want raw numbers they can chart in a spreadsheet, and macOS does not give an easy way to get them. Our clean-room version is a pure logger. It writes a time series of power and thermal readings to a CSV file at a chosen interval and nothing else.

(2) Feature set. Sample every 1, 5, 10 or 60 seconds. Each row records timestamp, battery percent, charging flag, adapter connected flag, battery voltage, battery amperage, computed battery watts, battery temperature, cycle count, Low Power Mode flag and thermal pressure state. Start and stop recording from the menu bar. Name a session and choose a save location with a save panel, then append rows in place. Show a rolling row count, file size and elapsed time. Add a marker button that writes a row with a note, such as Started render, so events can be matched against the data. An auto-stop option ends the session after a set duration or when the battery hits a chosen level.

(3) UI. MenuBarExtra in window style. The popover shows Recording or Idle, a Start and Stop button, elapsed time, row count and the last sample values, plus a Marker text field with an Add button. Settings: interval, default folder, auto-stop options, columns to include, launch at login. Empty state: No sessions yet, with a Start Session button. Shortcuts: Option-Command-L starts or stops, Option-Command-M adds a marker.

(4) Technical approach. Read the AppleSmartBattery registry entry for voltage, amperage, temperature, cycles and charging flags using IOKit. Read ProcessInfo thermalState and isLowPowerModeEnabled. Use a DispatchSourceTimer on a background queue and a FileHandle opened for appending, writing a header row on creation. Flush on every row so data survives a crash. Use UniformTypeIdentifiers for the comma-separated values type in the save panel. Persist settings with AppStorage. Launch at login via SMAppService. No permissions are required, but keep the folder choice as a security-scoped bookmark if the app is ever sandboxed.

(5) Edge cases. If the file becomes unwritable or the volume disappears, stop recording and show an alert. Escape marker text so commas and quotes do not break columns. Keep sampling during display sleep but note that the Mac may sleep, which creates gaps, so write a gap marker row on wake. Limit file size with an optional rotate at 50 megabytes. On Macs without a battery, record only the thermal columns. Never overwrite an existing file without confirmation.
