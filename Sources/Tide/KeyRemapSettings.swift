import Foundation

/// One remapped key: pressing `from` acts as `to`. Both are HID usages in
/// the form the keyboard driver takes them (see RemappableKey).
struct KeyRemap: Codable, Equatable {
    var from: UInt64
    var to: UInt64
}

/// Which keyboards a set of remaps applies to.
enum KeyboardScope: Hashable, Codable {
    case allKeyboards
    case builtIn
    case external
    /// One particular keyboard, by the stable ID KeyRemapper gives it.
    case keyboard(id: String)

    func covers(_ keyboard: KeyRemapper.Keyboard) -> Bool {
        switch self {
        case .allKeyboards: return true
        case .builtIn: return keyboard.isBuiltIn
        case .external: return !keyboard.isBuiltIn
        case .keyboard(let id): return keyboard.id == id
        }
    }

    /// When two scopes covering the same keyboard remap the same key, the
    /// narrower one wins: a keyboard's own setting beats Built-in/External,
    /// which beats All Keyboards. Built-in and External never both cover
    /// one keyboard, so they can share a rank.
    fileprivate var precedence: Int {
        switch self {
        case .allKeyboards: return 0
        case .builtIn, .external: return 1
        case .keyboard: return 2
        }
    }
}

/// Persisted configuration for key remapping (see KeyRemapper) — separate
/// from the other stores since it backs its own settings pane.
enum KeyRemapStore {
    private struct Group: Codable {
        var scope: KeyboardScope
        var remaps: [KeyRemap]
        /// The keyboard's name when this is a `.keyboard` scope, saved so
        /// the pane can still list it, by name, while it's unplugged.
        var keyboardName: String?
    }

    private static let defaults = UserDefaults.standard
    private static let isEnabledKey = "KeyRemap.isEnabled"
    private static let groupsKey = "KeyRemap.groups"

    /// Master switch. On by default, unlike Scrolling's: remapping needs no
    /// permission, and with no mappings saved it does nothing anyway — so
    /// adding a first mapping just works, without hunting for a switch.
    static var isEnabled: Bool {
        get { defaults.object(forKey: isEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: isEnabledKey) }
    }

    static func remaps(for scope: KeyboardScope) -> [KeyRemap] {
        groups.first { $0.scope == scope }?.remaps ?? []
    }

    /// Replaces the remaps for `scope`. Pass the keyboard's current name
    /// with a `.keyboard` scope so it can be shown while disconnected.
    static func setRemaps(_ remaps: [KeyRemap], for scope: KeyboardScope, keyboardName: String? = nil) {
        var stored = groups
        let existingName = stored.first { $0.scope == scope }?.keyboardName
        stored.removeAll { $0.scope == scope }
        if !remaps.isEmpty {
            stored.append(Group(scope: scope, remaps: remaps, keyboardName: keyboardName ?? existingName))
        }
        groups = stored
    }

    /// Specific keyboards that have remaps saved, with their last known
    /// names — including ones that aren't connected right now.
    static var configuredKeyboards: [(id: String, name: String)] {
        groups.compactMap { group in
            guard case .keyboard(let id) = group.scope else { return nil }
            return (id, group.keyboardName ?? "Keyboard")
        }
    }

    /// What `keyboard` should actually do, merged across every scope that
    /// covers it, narrowest scope winning per key. Sorted by source key so
    /// two results can be compared directly.
    static func effectiveRemaps(for keyboard: KeyRemapper.Keyboard) -> [KeyRemap] {
        var winners: [UInt64: (remap: KeyRemap, precedence: Int)] = [:]
        for group in groups where group.scope.covers(keyboard) {
            for remap in group.remaps {
                if let current = winners[remap.from], current.precedence > group.scope.precedence { continue }
                winners[remap.from] = (remap, group.scope.precedence)
            }
        }
        return winners.values.map(\.remap).sorted { $0.from < $1.from }
    }

    private static var groups: [Group] {
        get {
            guard let data = defaults.data(forKey: groupsKey),
                  let decoded = try? JSONDecoder().decode([Group].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: groupsKey)
        }
    }
}
