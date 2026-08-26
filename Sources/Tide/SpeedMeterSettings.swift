import Foundation

/// Which magnitude system + notation to format throughput numbers in.
enum SpeedUnit: String, CaseIterable {
    case bytesBinary
    case bytesDecimal
    case bits

    var displayName: String {
        switch self {
        case .bytesBinary: return "B/s (1024)"
        case .bytesDecimal: return "B/s (1000)"
        case .bits: return "bit/s"
        }
    }
}

/// Persisted configuration for the menu bar speed display — separate from
/// CaptureSettingsStore (screenshots) since this covers a different pane.
enum SpeedMeterSettingsStore {
    private static let defaults = UserDefaults.standard
    private static let isEnabledKey = "SpeedMeter.isEnabled"
    private static let showUploadKey = "SpeedMeter.showUpload"
    private static let showDownloadKey = "SpeedMeter.showDownload"
    private static let unitKey = "SpeedMeter.unit"
    private static let refreshIntervalKey = "SpeedMeter.refreshInterval"

    /// Master toggle for the menu bar speed text; the menu bar item itself
    /// always stays (it's the only way to reach the app), just without a
    /// live speed reading when this is off.
    static var isEnabled: Bool {
        get { defaults.object(forKey: isEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: isEnabledKey) }
    }

    static var showUpload: Bool {
        get { defaults.object(forKey: showUploadKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: showUploadKey) }
    }

    static var showDownload: Bool {
        get { defaults.object(forKey: showDownloadKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: showDownloadKey) }
    }

    static var unit: SpeedUnit {
        get { defaults.string(forKey: unitKey).flatMap(SpeedUnit.init) ?? .bytesBinary }
        set { defaults.set(newValue.rawValue, forKey: unitKey) }
    }

    /// Seconds between polls. Only a fixed set of values is offered in the
    /// UI (see SettingsWindowController), but any positive value works.
    static var refreshInterval: Double {
        get {
            let stored = defaults.double(forKey: refreshIntervalKey)
            return stored > 0 ? stored : 1.0
        }
        set { defaults.set(newValue, forKey: refreshIntervalKey) }
    }
}
