import Foundation

/// Persisted configuration for the copy sound (see CopySoundManager).
enum CopySoundSettingsStore {
    private static let defaults = UserDefaults.standard
    private static let isEnabledKey = "CopySound.isEnabled"
    private static let soundNameKey = "CopySound.soundName"

    /// Off by default, like Scrolling: hearing ⌘C takes the Accessibility
    /// permission, so it only starts once the user asks for it.
    static var isEnabled: Bool {
        get { defaults.object(forKey: isEnabledKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: isEnabledKey) }
    }

    /// One of macOS's own alert sounds, by name ("Pop", "Tink"…).
    static var soundName: String {
        get { defaults.string(forKey: soundNameKey) ?? defaultSoundName }
        set { defaults.set(newValue, forKey: soundNameKey) }
    }

    /// Short and soft enough to hear on every copy without wearing thin.
    static let defaultSoundName = "Pop"
}
