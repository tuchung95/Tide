import Foundation

/// Persisted configuration for the per-device scroll direction override
/// (see ScrollDirectionManager) — separate from the other stores since it
/// backs its own settings pane.
///
/// macOS itself only has ONE scroll direction switch ("Natural scrolling"),
/// shared by every pointing device: flipping it for the trackpad flips it
/// for the mouse too, which is exactly backwards for people who want
/// natural scrolling on the trackpad and classic wheel direction on a
/// mouse. This store drives the fix: keep the system setting tuned for one
/// device, and let Tide flip the other one back.
enum ScrollSettingsStore {
    private static let defaults = UserDefaults.standard
    private static let isEnabledKey = "Scroll.isEnabled"
    private static let reverseMouseKey = "Scroll.reverseMouse"
    private static let reverseTrackpadKey = "Scroll.reverseTrackpad"

    /// Master switch. Off by default: the feature needs Accessibility
    /// permission, so it only starts once the user asks for it.
    static var isEnabled: Bool {
        get { defaults.object(forKey: isEnabledKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: isEnabledKey) }
    }

    /// Flip vertical scrolling coming from a mouse (wheel or Magic Mouse).
    /// On by default because that's the common case: natural scrolling
    /// left on for the trackpad, reversed back to classic for the mouse.
    static var reverseMouse: Bool {
        get { defaults.object(forKey: reverseMouseKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: reverseMouseKey) }
    }

    /// Flip vertical scrolling coming from a trackpad.
    static var reverseTrackpad: Bool {
        get { defaults.object(forKey: reverseTrackpadKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: reverseTrackpadKey) }
    }

    /// Nothing to intercept when the master switch is off, or when it's on
    /// but neither device class is actually being reversed.
    static var isActive: Bool {
        isEnabled && (reverseMouse || reverseTrackpad)
    }
}
