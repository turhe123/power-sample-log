import Foundation
import IOKit

/// One reading of battery, power and thermal state at a point in time.
struct PowerSample {
    var timestamp: Date
    var hasBattery: Bool
    var batteryPercent: Int?
    var isCharging: Bool?
    var adapterConnected: Bool?
    var voltage: Double?      // volts
    var amperage: Double?     // amps, negative while discharging
    var temperature: Double?  // °C
    var cycleCount: Int?
    var lowPowerMode: Bool
    var thermalState: String

    /// Instantaneous battery power in watts (negative while discharging).
    var watts: Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }
}

/// The CSV columns the logger can write, in file order.
enum Column: String, CaseIterable, Identifiable {
    case timestamp, batteryPercent = "battery_percent", charging, adapterConnected = "adapter_connected"
    case voltage = "voltage_v", amperage = "amperage_a", watts, temperature = "temperature_c"
    case cycleCount = "cycle_count", lowPowerMode = "low_power_mode", thermalState = "thermal_state", note

    var id: String { rawValue }

    /// Columns that only make sense on a Mac with a battery.
    var needsBattery: Bool {
        switch self {
        case .timestamp, .lowPowerMode, .thermalState, .note: return false
        default: return true
        }
    }

    /// Columns that are always written and cannot be turned off.
    var isRequired: Bool { self == .timestamp || self == .note }

    var title: String {
        switch self {
        case .timestamp: return "Timestamp"
        case .batteryPercent: return "Battery %"
        case .charging: return "Charging"
        case .adapterConnected: return "Adapter connected"
        case .voltage: return "Voltage (V)"
        case .amperage: return "Amperage (A)"
        case .watts: return "Watts"
        case .temperature: return "Temperature (°C)"
        case .cycleCount: return "Cycle count"
        case .lowPowerMode: return "Low Power Mode"
        case .thermalState: return "Thermal pressure"
        case .note: return "Note / marker"
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    /// The raw CSV field for this column (unescaped).
    func value(for s: PowerSample, note: String) -> String {
        func fmt(_ d: Double?, _ digits: Int) -> String { d.map { String(format: "%.\(digits)f", $0) } ?? "" }
        func flag(_ b: Bool?) -> String { b.map { $0 ? "1" : "0" } ?? "" }
        switch self {
        case .timestamp: return Column.isoFormatter.string(from: s.timestamp)
        case .batteryPercent: return s.batteryPercent.map(String.init) ?? ""
        case .charging: return flag(s.isCharging)
        case .adapterConnected: return flag(s.adapterConnected)
        case .voltage: return fmt(s.voltage, 3)
        case .amperage: return fmt(s.amperage, 3)
        case .watts: return fmt(s.watts, 2)
        case .temperature: return fmt(s.temperature, 1)
        case .cycleCount: return s.cycleCount.map(String.init) ?? ""
        case .lowPowerMode: return flag(s.lowPowerMode)
        case .thermalState: return s.thermalState
        case .note: return note
        }
    }
}

/// Reads the AppleSmartBattery IORegistry entry and ProcessInfo power/thermal state.
enum PowerSampler {
    static func read() -> PowerSample {
        let info = ProcessInfo.processInfo
        var sample = PowerSample(timestamp: Date(), hasBattery: false, lowPowerMode: info.isLowPowerModeEnabled,
                                 thermalState: thermalName(info.thermalState))
        guard let props = batteryProperties() else { return sample }
        sample.hasBattery = true
        let current = int(props["CurrentCapacity"])
        let max = int(props["MaxCapacity"])
        if let current, let max, max > 0 {
            sample.batteryPercent = Int((Double(current) / Double(max) * 100).rounded())
        }
        sample.isCharging = props["IsCharging"] as? Bool
        sample.adapterConnected = props["ExternalConnected"] as? Bool
        sample.voltage = int(props["Voltage"]).map { Double($0) / 1000 }
        sample.amperage = int(props["InstantAmperage"] ?? props["Amperage"]).map { Double(signed16($0)) / 1000 }
        sample.temperature = int(props["Temperature"]).map { Double($0) / 100 }
        sample.cycleCount = int(props["CycleCount"])
        return sample
    }

    /// Whether this Mac exposes a smart battery at all.
    static var hasBattery: Bool { batteryProperties() != nil }

    private static func batteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any],
              dict["BatteryInstalled"] as? Bool ?? true else { return nil }
        return dict
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) }
    }

    /// Some Macs report negative amperage as a large unsigned value; fold it back into range.
    private static func signed16(_ v: Int) -> Int {
        abs(v) > Int(Int16.max) ? Int(Int16(truncatingIfNeeded: v)) : v
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// Escapes a field so commas, quotes and line breaks don't break CSV columns.
func csvEscape(_ field: String) -> String {
    guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
