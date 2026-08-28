import Foundation

/// Persisted display settings — same shape as ScrollSettingsStore and
/// SpeedMeterSettingsStore.
///
/// Deliberately narrow: only the *software-dimmed* brightness is stored.
/// The built-in panel's brightness is remembered by macOS, and a DDC
/// monitor keeps brightness and volume in its own firmware, so saving
/// those here and re-applying them at launch would do nothing useful and
/// actively fight the keyboard's brightness keys and the monitor's own
/// buttons. A gamma ramp is the one thing that genuinely evaporates when
/// the app quits or the display is replugged.
///
/// Keyed by DisplayInfo.persistenceKey rather than CGDirectDisplayID,
/// which is only stable within one boot (see DisplayInfo).
enum DisplaySettingsStore {

    private static let defaults = UserDefaults.standard
    private static let isEnabledKey = "Display.isEnabled"
    private static let forceGammaKey = "Display.forceGamma"
    private static let gammaBrightnessKeyPrefix = "Display.brightness."

    /// Master switch for the whole Displays section of the menu. On by
    /// default: unlike the scroll reversal, nothing here needs a
    /// permission grant, so there's no reason to make the user opt in.
    static var isEnabled: Bool {
        get { defaults.object(forKey: isEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: isEnabledKey) }
    }

    /// Debug escape hatch: routes every external display through the gamma
    /// dimmer even when DDC works, so the fallback path can be exercised
    /// on a machine that has a well-behaved monitor attached (or, on a
    /// laptop-only machine, so it can be tested at all).
    ///
    ///     defaults write com.tide.menubar Display.forceGamma -bool YES
    static var forceGamma: Bool {
        defaults.bool(forKey: forceGammaKey)
    }

    /// Last software-dimmed brightness for this display, 0…1, or nil if it
    /// has never been dimmed — in which case the display is left alone.
    static func gammaBrightness(for key: String) -> Float? {
        guard let value = defaults.object(forKey: gammaBrightnessKeyPrefix + key) as? Double else { return nil }
        return Float(min(max(value, 0), 1))
    }

    static func setGammaBrightness(_ value: Float, for key: String) {
        defaults.set(Double(min(max(value, 0), 1)), forKey: gammaBrightnessKeyPrefix + key)
    }
}
