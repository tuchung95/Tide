import Foundation

/// Per capture type (Selected Area / Window / Full Screen), whether it
/// saves to ~/Desktop and/or copies to the clipboard. The two are
/// independent toggles — both can be on at once ("song song"), one can be
/// off while the other stays on, or (rare, but allowed) both off, in which
/// case that capture type just does nothing when triggered.
enum CaptureSettingsStore {
    static func isSaveEnabled(for action: ShortcutAction) -> Bool {
        UserDefaults.standard.object(forKey: saveKey(action)) as? Bool ?? true
    }

    static func isCopyEnabled(for action: ShortcutAction) -> Bool {
        UserDefaults.standard.object(forKey: copyKey(action)) as? Bool ?? true
    }

    static func setSaveEnabled(_ enabled: Bool, for action: ShortcutAction) {
        UserDefaults.standard.set(enabled, forKey: saveKey(action))
    }

    static func setCopyEnabled(_ enabled: Bool, for action: ShortcutAction) {
        UserDefaults.standard.set(enabled, forKey: copyKey(action))
    }

    private static func saveKey(_ action: ShortcutAction) -> String {
        "TideCaptureSave.\(action.rawValue)"
    }

    private static func copyKey(_ action: ShortcutAction) -> String {
        "TideCaptureCopy.\(action.rawValue)"
    }
}
