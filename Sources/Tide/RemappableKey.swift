import Foundation

/// A key Tide can remap, identified the way macOS's keyboard driver sees
/// it: a HID usage packed as `page << 32 | usage` — the exact number the
/// driver's UserKeyMapping property takes (see KeyRemapper), so nothing is
/// translated on the way. Mostly the Keyboard/Keypad page (0x07); media and
/// volume keys live on the Consumer page (0x0C) instead, and the driver
/// maps between pages as readily as within one.
///
/// Named by position on a US ANSI keyboard, the way remappers generally
/// name keys: the driver swaps physical keys before the input source turns
/// them into characters, so on an AZERTY keyboard the key listed here as
/// "Q" is the one printed "A".
struct RemappableKey {
    let hidUsage: UInt64
    let name: String

    struct Group {
        let title: String
        let keys: [RemappableKey]
    }

    /// Every key offered in the Keyboard pane's pickers, in menu order.
    static let groups: [Group] = [
        Group(title: "Modifiers", keys: [
            key(0x39, "Caps Lock"),
            key(0xE0, "Left Control"),
            key(0xE2, "Left Option"),
            key(0xE3, "Left Command"),
            key(0xE1, "Left Shift"),
            key(0xE4, "Right Control"),
            key(0xE6, "Right Option"),
            key(0xE7, "Right Command"),
            key(0xE5, "Right Shift")
        ]),
        Group(title: "Editing & Navigation", keys: [
            key(0x29, "Escape"),
            key(0x28, "Return"),
            key(0x2B, "Tab"),
            key(0x2C, "Space"),
            key(0x2A, "Delete"),
            key(0x4C, "Forward Delete"),
            key(0x4A, "Home"),
            key(0x4D, "End"),
            key(0x4B, "Page Up"),
            key(0x4E, "Page Down"),
            key(0x50, "Left Arrow"),
            key(0x4F, "Right Arrow"),
            key(0x52, "Up Arrow"),
            key(0x51, "Down Arrow")
        ]),
        // The extra keys on a Windows keyboard, which macOS mostly ignores —
        // the usual reason to remap one is to give it a job.
        Group(title: "PC Keyboard", keys: [
            key(0x46, "Print Screen"),
            key(0x47, "Scroll Lock"),
            key(0x48, "Pause"),
            key(0x49, "Insert"),
            key(0x65, "Menu"),
            key(0x53, "Num Lock"),
            key(0x64, "Non-US Backslash")
        ]),
        // Mostly wanted as targets — a keyboard without media keys getting
        // them on keys it does have — but they work as sources too, on
        // keyboards that send them as media keys (KeyRemapper also maps a
        // keyboard's separate media-key service).
        Group(title: "Media & Volume", keys: [
            consumerKey(0xCD, "Play/Pause"),
            consumerKey(0xB6, "Previous Track"),
            consumerKey(0xB5, "Next Track"),
            consumerKey(0xE2, "Mute"),
            consumerKey(0xEA, "Volume Down"),
            consumerKey(0xE9, "Volume Up"),
            consumerKey(0x70, "Brightness Down"),
            consumerKey(0x6F, "Brightness Up")
        ]),
        // F13–F20 have no key on most keyboards, which is what makes them
        // useful targets: anything remapped to one can be bound as a
        // shortcut without clashing with an existing one. macOS stops
        // recognising function keys after F20.
        Group(title: "Function Keys", keys: (1...12).map { key(0x39 + UInt64($0), "F\($0)") }
            + (13...20).map { key(0x5B + UInt64($0), "F\($0)") }),
        Group(title: "Letters", keys: zip(0x04...0x1D, "ABCDEFGHIJKLMNOPQRSTUVWXYZ").map { key(UInt64($0), String($1)) }),
        Group(title: "Numbers", keys: zip(0x1E...0x27, "1234567890").map { key(UInt64($0), String($1)) }),
        Group(title: "Symbols", keys: [
            key(0x35, "` Grave Accent"),
            key(0x2D, "- Minus"),
            key(0x2E, "= Equals"),
            key(0x2F, "[ Left Bracket"),
            key(0x30, "] Right Bracket"),
            key(0x31, "\\ Backslash"),
            key(0x33, "; Semicolon"),
            key(0x34, "' Quote"),
            key(0x36, ", Comma"),
            key(0x37, ". Period"),
            key(0x38, "/ Slash")
        ])
    ]

    static let all: [RemappableKey] = groups.flatMap(\.keys)

    /// Display name for a stored usage. Falls back to the raw number rather
    /// than failing, so a mapping saved by a later version that knows more
    /// keys still shows up (and can still be removed) here.
    static func name(for hidUsage: UInt64) -> String {
        all.first { $0.hidUsage == hidUsage }?.name ?? String(format: "Key 0x%llX", hidUsage)
    }

    /// What a newly added mapping starts as: Caps Lock → Escape, about the
    /// most common remap there is, or the first key not remapped yet when
    /// Caps Lock already is. Nil only once every listed key is taken.
    static func suggestedRemap(excluding usedSources: Set<UInt64>) -> KeyRemap? {
        let escape = keyboardPage << 32 | 0x29
        guard let source = all.first(where: { !usedSources.contains($0.hidUsage) })?.hidUsage else { return nil }
        let capsLock = keyboardPage << 32 | 0x39
        return KeyRemap(from: source, to: source == escape ? capsLock : escape)
    }

    private static func key(_ usage: UInt64, _ name: String) -> RemappableKey {
        RemappableKey(hidUsage: keyboardPage << 32 | usage, name: name)
    }

    private static func consumerKey(_ usage: UInt64, _ name: String) -> RemappableKey {
        RemappableKey(hidUsage: consumerPage << 32 | usage, name: name)
    }

    static let keyboardPage: UInt64 = 0x07
    static let consumerPage: UInt64 = 0x0C
}
