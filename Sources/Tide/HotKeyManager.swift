import AppKit
import Carbon.HIToolbox

/// Registers system-wide keyboard shortcuts via the Carbon Event Manager.
/// Unlike an NSEvent global monitor, RegisterEventHotKey doesn't require the
/// Accessibility permission, which keeps a lightweight menu bar app like
/// Tide from having to ask for it just to support shortcuts.
final class HotKeyManager {

    static let shared = HotKeyManager()

    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandlerRef: EventHandlerRef?

    private init() {
        installEventHandler()
    }

    /// Registers `combo` as a new global shortcut. Returns the id to pass to
    /// `unregister(id:)` later, or nil if the OS refused the registration
    /// (typically because the combo is already claimed elsewhere).
    @discardableResult
    func register(combo: KeyCombo, handler: @escaping () -> Void) -> UInt32? {
        let id = nextID
        nextID += 1

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let carbonModifiers = Self.carbonModifiers(from: combo.modifierFlags)

        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let ref = hotKeyRef else {
            NSLog("Tide: failed to register hotkey \(combo.displayString) (status \(status))")
            return nil
        }

        hotKeyRefs[id] = ref
        handlers[id] = handler
        return id
    }

    func unregister(id: UInt32) {
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers.removeValue(forKey: id)
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, userData in
            guard let eventRef, let userData else { return noErr }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }

            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
    }

    private static let signature: OSType = {
        // Four-char code "TdHk", packed the way Carbon expects.
        "TdHk".utf8.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }()

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
