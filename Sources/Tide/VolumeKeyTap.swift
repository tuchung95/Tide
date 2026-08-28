import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Intercepts the keyboard's volume keys before macOS sees them.
///
/// The volume keys aren't ordinary key events: they arrive as
/// `systemDefined` events carrying an "aux control button" payload, which
/// is why a plain hot key registration can't reach them and an event tap
/// is the only way in. That means the Accessibility permission — the same
/// one ScrollDirectionManager needs, and this deliberately mirrors that
/// class's lifecycle rather than sharing its tap, since the two watch
/// different event masks and are switched on independently.
///
/// The tap only swallows a key when the handler says it acted on it. Every
/// other event, including volume keys arriving while the feature has
/// nothing to do with them, passes through untouched so macOS keeps
/// behaving normally.
final class VolumeKeyTap {

    enum StartResult {
        case running
        case disabled
        /// Enabled but not trusted for Accessibility yet; polls in the
        /// background and starts by itself once permission lands.
        case needsAccessibility
    }

    enum Key {
        case up
        case down
        case mute
    }

    struct Press {
        let key: Key
        /// Auto-repeat from the key being held down.
        let isRepeat: Bool
    }

    /// Returns true if the press was handled and the event should be
    /// swallowed; false to let macOS have it.
    var onPress: ((Press, CGEventFlags) -> Bool)?

    /// Whether the tap should be installed at all — wired to the settings
    /// toggle by MonitorVolumeKeyManager.
    var isEnabled: () -> Bool = { false }

    /// Fired when the tap actually starts, including the delayed start
    /// after permission is granted from System Settings.
    var onStarted: (() -> Void)?

    /// Fired (once) when the app IS trusted but the tap still can't be
    /// created — macOS sometimes only applies the privilege after a
    /// relaunch.
    var onTapCreationFailedWhileTrusted: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionPollTimer: Timer?
    private var hasReportedTapFailureWhileTrusted = false

    var isRunning: Bool { eventTap != nil }

    /// Brings the tap in line with the current setting. Safe to call
    /// repeatedly — at launch, on every settings change, and whenever the
    /// audio output device changes.
    @discardableResult
    func apply() -> StartResult {
        guard isEnabled() else {
            stop()
            return .disabled
        }
        if isRunning { return .running }
        guard AXIsProcessTrusted() else {
            startPermissionPolling()
            return .needsAccessibility
        }
        return start() ? .running : .needsAccessibility
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Tap lifecycle

    private func start() -> Bool {
        let mask = CGEventMask(1 << Self.systemDefinedEventType.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<VolumeKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Tide: could not create volume key tap (Accessibility permission missing?)")
            startPermissionPolling()
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        hasReportedTapFailureWhileTrusted = false
        stopPermissionPolling()
        onStarted?()
        return true
    }

    private func stop() {
        stopPermissionPolling()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func startPermissionPolling() {
        guard permissionPollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.isEnabled() else {
                self.stop()
                return
            }
            guard AXIsProcessTrusted() else { return }
            if self.start() { return }
            guard !self.hasReportedTapFailureWhileTrusted else { return }
            self.hasReportedTapFailureWhileTrusted = true
            self.onTapCreationFailedWhileTrusted?()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }

    private func stopPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long; re-enabling is
        // the standard recovery, otherwise the keys silently stop being
        // intercepted until the app is relaunched.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == Self.systemDefinedEventType, isEnabled() else {
            return Unmanaged.passUnretained(event)
        }

        // The aux-control payload lives in fields CGEvent doesn't expose;
        // NSEvent is the only way to read `subtype` and `data1`. Safe here
        // because the event type has already been checked — those two
        // properties raise on event types that don't carry them.
        guard let nsEvent = NSEvent(cgEvent: event),
              let press = Self.decode(subtype: Int(nsEvent.subtype.rawValue), data1: nsEvent.data1),
              onPress?(press, event.flags) == true
        else {
            return Unmanaged.passUnretained(event)
        }

        // Handled: swallow it, so macOS doesn't also show its "can't
        // change this device's volume" HUD on top of what Tide just did.
        return nil
    }

    /// Decodes an aux-control-button payload.
    ///
    ///     subtype  8  = NX_SUBTYPE_AUX_CONTROL_BUTTONS
    ///     data1 bits  31..16  key code
    ///                 15..8   key state, 0x0A on the way down
    ///                 0       auto-repeat
    ///
    /// Only presses are reported: acting on the release too would step the
    /// volume twice per tap. Split out as a pure function so it can be
    /// exercised against known payloads without a keyboard.
    static func decode(subtype: Int, data1: Int) -> Press? {
        guard subtype == Self.auxControlButtonSubtype else { return nil }

        let keyCode = Int32((data1 & 0xFFFF_0000) >> 16)
        let keyFlags = data1 & 0x0000_FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        guard isKeyDown else { return nil }

        let key: Key
        switch keyCode {
        case Self.keyCodeSoundUp: key = .up
        case Self.keyCodeSoundDown: key = .down
        case Self.keyCodeMute: key = .mute
        default: return nil
        }
        return Press(key: key, isRepeat: keyFlags & 0x1 == 1)
    }

    // MARK: - Constants

    /// kCGEventSystemDefined. Not in CGEventType's Swift enum, which stops
    /// at the mouse/keyboard events.
    private static let systemDefinedEventType = CGEventType(rawValue: 14)!
    private static let auxControlButtonSubtype = 8
    private static let keyCodeSoundUp: Int32 = 0
    private static let keyCodeSoundDown: Int32 = 1
    private static let keyCodeMute: Int32 = 7
}
