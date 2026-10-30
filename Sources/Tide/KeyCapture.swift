import AppKit

/// Listens for keys pressed while one of Tide's windows is key, for the
/// Keyboard pane's "press the key instead of hunting for it in a list".
///
/// A local NSEvent monitor is enough: the Settings window is the one in
/// front, so nothing system-wide is needed — no event tap, no Input
/// Monitoring prompt. Every keyboard event is swallowed while it listens,
/// so pressing ⌘ or Escape picks that key instead of acting on the window.
///
/// What an NSEvent carries is a virtual key code (or, for media keys, an
/// aux-control key type), not the HID usage the remapper stores; see
/// hidUsage(of:onAppleKeyboard:) for the way back. Tide's own remaps have to
/// be out of the way while this listens (KeyRemapper.isSuspended), or a
/// Caps Lock remapped to Escape would read as Escape.
final class KeyCapture {

    enum Key: Equatable {
        /// A key press or modifier press, by virtual key code.
        case keyCode(UInt16)
        /// A media or volume key, by its NX_KEYTYPE_* value.
        case mediaKey(Int)
    }

    struct Press {
        let key: Key
        /// The IORegistry ID of whatever sent the event (CGEvent field 87),
        /// 0 when it doesn't say. See KeyRemapper.keyboard(forSenderID:).
        let senderID: UInt64
    }

    private var monitor: Any?

    var isListening: Bool { monitor != nil }

    /// Reports every key press until `stop()`. Releases, auto-repeats and
    /// non-key events are passed over.
    func start(onPress: @escaping (Press) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .systemDefined]) { event in
            // Media keys share .systemDefined with plenty of unrelated
            // traffic that isn't this monitor's to swallow.
            if event.type == .systemDefined, Self.mediaKey(of: event) == nil {
                return event
            }
            if let key = Self.pressedKey(of: event) {
                let senderID = event.cgEvent.map { UInt64(bitPattern: $0.getIntegerValueField(Self.senderIDField)) } ?? 0
                onPress(Press(key: key, senderID: senderID))
            }
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    // MARK: - Reading events

    /// Not in CGEventField's public list; see ScrollDirectionManager.
    private static let senderIDField = CGEventField(rawValue: 87)!

    private static func pressedKey(of event: NSEvent) -> Key? {
        switch event.type {
        case .keyDown:
            return event.isARepeat ? nil : .keyCode(event.keyCode)
        case .flagsChanged:
            return isModifierDown(event) ? .keyCode(event.keyCode) : nil
        case .systemDefined:
            return mediaKey(of: event)
        default:
            return nil
        }
    }

    /// A modifier sends flagsChanged both ways; only the press counts.
    /// Read from the device-dependent bits (IOLLEvent.h's NX_DEVICE*KEYMASK)
    /// rather than .command/.shift and friends, which can't tell a release
    /// of one side from the other side still being held.
    private static func isModifierDown(_ event: NSEvent) -> Bool {
        // Caps Lock reports its lock state, not the key: every flagsChanged
        // it sends is a press.
        if event.keyCode == 0x39 { return true }
        guard let mask = deviceModifierMasks[event.keyCode] else { return false }
        return event.modifierFlags.rawValue & mask != 0
    }

    private static let deviceModifierMasks: [UInt16: UInt] = [
        0x3B: 0x0001, // Left Control
        0x38: 0x0002, // Left Shift
        0x3C: 0x0004, // Right Shift
        0x37: 0x0008, // Left Command
        0x36: 0x0010, // Right Command
        0x3A: 0x0020, // Left Option
        0x3D: 0x0040, // Right Option
        0x3E: 0x2000  // Right Control
    ]

    /// Same aux-control payload VolumeKeyTap decodes: subtype 8, key type
    /// in data1's top half, 0x0A in its state byte on the way down.
    private static func mediaKey(of event: NSEvent) -> Key? {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return nil }
        let keyType = (event.data1 & 0xFFFF_0000) >> 16
        let isKeyDown = ((event.data1 & 0xFF00) >> 8) == 0x0A
        let isRepeat = event.data1 & 0x1 == 1
        guard isKeyDown, !isRepeat, consumerUsageByMediaKey[keyType] != nil else { return nil }
        return .mediaKey(keyType)
    }

    // MARK: - Back to HID usages

    /// The HID usage behind a captured key, in RemappableKey's packing, or
    /// nil for a key Tide doesn't offer (fn, the keypad…).
    ///
    /// The way back from a virtual key code is a fixed table — key codes
    /// name positions, the same on every layout — except for three that
    /// macOS gives two keys each: Print Screen, Scroll Lock and Pause come
    /// through as F13, F14 and F15. Apple's keyboards have no Print Screen
    /// and PC keyboards rarely have F13, so the keyboard's maker decides.
    static func hidUsage(of key: Key, onAppleKeyboard: Bool) -> UInt64? {
        switch key {
        case .mediaKey(let keyType):
            return consumerUsageByMediaKey[keyType].map { RemappableKey.consumerPage << 32 | $0 }
        case .keyCode(let keyCode):
            let usage = (onAppleKeyboard ? appleOnlyUsageByKeyCode[keyCode] : pcOnlyUsageByKeyCode[keyCode])
                ?? keyboardUsageByKeyCode[keyCode]
            return usage.map { RemappableKey.keyboardPage << 32 | $0 }
        }
    }

    /// NX_KEYTYPE_* (ev_keymap.h) → Consumer page usage. Fast-forward and
    /// rewind are what some keyboards send for next/previous track, and
    /// macOS treats them the same way.
    private static let consumerUsageByMediaKey: [Int: UInt64] = [
        0: 0xE9,  // NX_KEYTYPE_SOUND_UP → Volume Up
        1: 0xEA,  // NX_KEYTYPE_SOUND_DOWN → Volume Down
        2: 0x6F,  // NX_KEYTYPE_BRIGHTNESS_UP → Brightness Up
        3: 0x70,  // NX_KEYTYPE_BRIGHTNESS_DOWN → Brightness Down
        7: 0xE2,  // NX_KEYTYPE_MUTE → Mute
        16: 0xCD, // NX_KEYTYPE_PLAY → Play/Pause
        17: 0xB5, // NX_KEYTYPE_NEXT → Next Track
        18: 0xB6, // NX_KEYTYPE_PREVIOUS → Previous Track
        19: 0xB5, // NX_KEYTYPE_FAST → Next Track
        20: 0xB6  // NX_KEYTYPE_REWIND → Previous Track
    ]

    private static let appleOnlyUsageByKeyCode: [UInt16: UInt64] = [
        0x69: 0x68, // F13
        0x6B: 0x69, // F14
        0x71: 0x6A  // F15
    ]

    private static let pcOnlyUsageByKeyCode: [UInt16: UInt64] = [
        0x69: 0x46, // Print Screen
        0x6B: 0x47, // Scroll Lock
        0x71: 0x48  // Pause
    ]

    /// Virtual key code (Carbon's kVK_*) → Keyboard page usage, for every
    /// key RemappableKey lists apart from the three above.
    private static let keyboardUsageByKeyCode: [UInt16: UInt64] = [
        // Letters
        0x00: 0x04, 0x0B: 0x05, 0x08: 0x06, 0x02: 0x07, 0x0E: 0x08, 0x03: 0x09, 0x05: 0x0A,
        0x04: 0x0B, 0x22: 0x0C, 0x26: 0x0D, 0x28: 0x0E, 0x25: 0x0F, 0x2E: 0x10, 0x2D: 0x11,
        0x1F: 0x12, 0x23: 0x13, 0x0C: 0x14, 0x0F: 0x15, 0x01: 0x16, 0x11: 0x17, 0x20: 0x18,
        0x09: 0x19, 0x0D: 0x1A, 0x07: 0x1B, 0x10: 0x1C, 0x06: 0x1D,
        // Numbers 1–9, 0
        0x12: 0x1E, 0x13: 0x1F, 0x14: 0x20, 0x15: 0x21, 0x17: 0x22,
        0x16: 0x23, 0x1A: 0x24, 0x1C: 0x25, 0x19: 0x26, 0x1D: 0x27,
        // Return, Escape, Delete, Tab, Space
        0x24: 0x28, 0x35: 0x29, 0x33: 0x2A, 0x30: 0x2B, 0x31: 0x2C,
        // - = [ ] \ ; ' ` , . /
        0x1B: 0x2D, 0x18: 0x2E, 0x21: 0x2F, 0x1E: 0x30, 0x2A: 0x31, 0x29: 0x33,
        0x27: 0x34, 0x32: 0x35, 0x2B: 0x36, 0x2F: 0x37, 0x2C: 0x38,
        // Caps Lock
        0x39: 0x39,
        // F1–F12
        0x7A: 0x3A, 0x78: 0x3B, 0x63: 0x3C, 0x76: 0x3D, 0x60: 0x3E, 0x61: 0x3F,
        0x62: 0x40, 0x64: 0x41, 0x65: 0x42, 0x6D: 0x43, 0x67: 0x44, 0x6F: 0x45,
        // F16–F19 (F20 is Lock Screen's stand-in, not offered as a key)
        0x6A: 0x6B, 0x40: 0x6C, 0x4F: 0x6D, 0x50: 0x6E,
        // Insert (macOS's Help), Home, Page Up, Forward Delete, End, Page Down
        0x72: 0x49, 0x73: 0x4A, 0x74: 0x4B, 0x75: 0x4C, 0x77: 0x4D, 0x79: 0x4E,
        // Right, Left, Down, Up
        0x7C: 0x4F, 0x7B: 0x50, 0x7D: 0x51, 0x7E: 0x52,
        // Num Lock (macOS's keypad Clear), Non-US Backslash, Menu
        0x47: 0x53, 0x0A: 0x64, 0x6E: 0x65,
        // Left Control, Shift, Option, Command; then the right-hand ones
        0x3B: 0xE0, 0x38: 0xE1, 0x3A: 0xE2, 0x37: 0xE3,
        0x3E: 0xE4, 0x3C: 0xE5, 0x3D: 0xE6, 0x36: 0xE7
    ]
}
