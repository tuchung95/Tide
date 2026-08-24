import AppKit

/// A single keyboard shortcut: one key plus modifier flags, using AppKit's
/// virtual key codes and modifier flags (Carbon's own bit layout is only
/// used at the point of registration, see HotKeyManager).
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16
    var modifierRawValue: UInt

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierRawValue)
    }

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierRawValue = modifierFlags.rawValue
    }

    /// Human-readable form, e.g. "⌃⇧4".
    var displayString: String {
        let flags = modifierFlags
        var parts = ""
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }
        parts += Self.keyName(for: keyCode)
        return parts
    }

    static func keyName(for keyCode: UInt16) -> String {
        keyCodeNames[keyCode] ?? "Key \(keyCode)"
    }

    /// The literal character NSMenuItem expects as a key-equivalent hint
    /// (e.g. "4" so the menu shows "⌃⇧4"). Only covers keys with a direct
    /// character — nil for arrows, function keys, Return/Tab/Space/Delete/
    /// Escape, which NSMenuItem represents with special Unicode constants
    /// instead; those shortcuts still work globally, they just don't get a
    /// menu hint.
    var menuEquivalentCharacter: String? {
        Self.menuEquivalentCharacters[keyCode]
    }

    private static let menuEquivalentCharacters: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7",
        28: "8", 29: "0", 31: "o", 32: "u", 34: "i", 35: "p",
        37: "l", 38: "j", 40: "k", 45: "n", 46: "m",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 50: "`"
    ]

    // ANSI US layout virtual key codes. Covers the keys people realistically
    // pick for a capture shortcut; anything else falls back to "Key N".
    private static let keyCodeNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7",
        28: "8", 29: "0", 31: "O", 32: "U", 34: "I", 35: "P",
        37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",", 44: "/", 50: "`",
        36: "⏎", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
}

/// The actions Tide lets you trigger with a global shortcut.
enum ShortcutAction: String, CaseIterable {
    case selectedArea
    case window
    case fullScreen

    var displayName: String {
        switch self {
        case .selectedArea: return "Selected Area"
        case .window: return "Window"
        case .fullScreen: return "Full Screen"
        }
    }

    /// Control+Shift+3/4/5 rather than Command+Shift+3/4/5: the Command
    /// versions are already owned by macOS's built-in screenshot tool, and a
    /// second global registration on the same combo would just never fire.
    var defaultCombo: KeyCombo {
        switch self {
        case .fullScreen: return KeyCombo(keyCode: 20, modifierFlags: [.control, .shift]) // 3
        case .selectedArea: return KeyCombo(keyCode: 21, modifierFlags: [.control, .shift]) // 4
        case .window: return KeyCombo(keyCode: 23, modifierFlags: [.control, .shift]) // 5
        }
    }
}

/// Persists per-action shortcut customizations in UserDefaults. Distinguishes
/// three states per action: never customized (use the built-in default),
/// customized to a specific combo, and explicitly cleared (no shortcut).
enum ShortcutStore {
    private struct StoredCombo: Codable {
        var combo: KeyCombo?
    }

    static func combo(for action: ShortcutAction) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key(for: action)),
              let stored = try? JSONDecoder().decode(StoredCombo.self, from: data)
        else {
            return action.defaultCombo
        }
        return stored.combo
    }

    /// Pass nil to explicitly clear the shortcut for this action.
    static func setCombo(_ combo: KeyCombo?, for action: ShortcutAction) {
        let stored = StoredCombo(combo: combo)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key(for: action))
    }

    static func resetToDefault(for action: ShortcutAction) {
        UserDefaults.standard.removeObject(forKey: key(for: action))
    }

    private static func key(for action: ShortcutAction) -> String {
        "TideShortcut.\(action.rawValue)"
    }
}
