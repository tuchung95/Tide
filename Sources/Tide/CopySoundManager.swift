import AppKit
import ApplicationServices
import CoreGraphics

/// Plays a short sound when ⌘C copies something — the same kind of
/// confirmation a screenshot gets from its shutter sound.
///
/// Hearing ⌘C in every app takes an event tap, and so the Accessibility
/// permission, which ScrollDirectionManager and VolumeKeyTap already ask
/// for; this mirrors their lifecycle rather than sharing a tap, since each
/// watches different events and is switched on independently. The tap
/// only watches: every event goes through untouched.
///
/// The keystroke alone isn't the signal. ⌘C with nothing selected copies
/// nothing, and a sound then would claim a copy that didn't happen. So the
/// keystroke only starts a short watch on the pasteboard's change count —
/// read before the app has even seen the key — and the sound plays if it
/// moves.
final class CopySoundManager {

    enum StartResult {
        case running
        case disabled
        /// Enabled but not trusted for Accessibility yet; polls in the
        /// background and starts by itself once permission lands.
        case needsAccessibility
    }

    /// Fired when the tap actually starts, including the delayed start
    /// after permission is granted from System Settings.
    var onStarted: (() -> Void)?

    /// Fired (once) when the app IS trusted but the tap still can't be
    /// created — macOS sometimes only applies the privilege after a
    /// relaunch.
    var onTapCreationFailedWhileTrusted: (() -> Void)?

    var isRunning: Bool { eventTap != nil }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionPollTimer: Timer?
    private var hasReportedTapFailureWhileTrusted = false
    private var pasteboardWatch: Timer?

    /// Brings the tap in line with CopySoundSettingsStore. Safe to call
    /// repeatedly — at launch and after every settings change.
    @discardableResult
    func apply() -> StartResult {
        guard CopySoundSettingsStore.isEnabled else {
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

    // MARK: - Sounds

    /// macOS's own alert sounds, by name, for the Settings picker.
    static var availableSoundNames: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        let names = files.filter { $0.hasSuffix(".aiff") }.map { ($0 as NSString).deletingPathExtension }.sorted()
        return names.isEmpty ? [CopySoundSettingsStore.defaultSoundName] : names
    }

    /// Plays `name`, cutting short the previous play of the same sound so a
    /// quick run of copies each gets heard.
    static func play(soundNamed name: String) {
        guard let sound = sound(named: name) ?? sound(named: CopySoundSettingsStore.defaultSoundName) else { return }
        sound.stop()
        sound.play()
    }

    private static var soundCache: [String: NSSound] = [:]

    private static func sound(named name: String) -> NSSound? {
        if let cached = soundCache[name] { return cached }
        let sound = NSSound(named: NSSound.Name(name))
        soundCache[name] = sound
        return sound
    }

    // MARK: - Tap lifecycle

    private func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<CopySoundManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Tide: could not create copy key tap (Accessibility permission missing?)")
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
        pasteboardWatch?.invalidate()
        pasteboardWatch = nil
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
            guard CopySoundSettingsStore.isEnabled else {
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
        // The system disables a tap that takes too long; re-enabling is the
        // standard recovery, or copies silently go unheard until relaunch.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown, CopySoundSettingsStore.isEnabled, Self.isCopyShortcut(event) {
            watchPasteboard()
        }
        return Unmanaged.passUnretained(event)
    }

    /// ⌘C exactly: ⌘⇧C, ⌥⌘C and friends are other commands in most apps,
    /// and a held-down ⌘C repeating isn't more copies. Matched by character
    /// rather than key code, since ⌘C follows the keyboard layout — on
    /// Dvorak it's a different physical key.
    static func isCopyShortcut(_ event: CGEvent) -> Bool {
        let flags = event.flags
        guard flags.contains(.maskCommand),
              flags.isDisjoint(with: [.maskShift, .maskControl, .maskAlternate]),
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0
        else { return false }
        return NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased() == "c"
    }

    private func watchPasteboard() {
        pasteboardWatch?.invalidate()
        pasteboardWatch = Self.watchForCopy(on: .general) {
            Self.play(soundNamed: CopySoundSettingsStore.soundName)
        }
    }

    /// Calls `onCopy` if `pasteboard` changes within `window`, measured
    /// against its count right now — which, called from the tap, is from
    /// before the app has had the key. Split out with the pasteboard as a
    /// parameter so it can be exercised on a private one rather than the
    /// user's clipboard.
    @discardableResult
    static func watchForCopy(on pasteboard: NSPasteboard, within window: TimeInterval = copyWindow,
                             then onCopy: @escaping () -> Void) -> Timer {
        let baseline = pasteboard.changeCount
        let deadline = Date().addingTimeInterval(window)
        let timer = Timer(timeInterval: pasteboardPollInterval, repeats: true) { timer in
            if pasteboard.changeCount != baseline {
                timer.invalidate()
                onCopy()
            } else if Date() >= deadline {
                timer.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Most apps write the pasteboard within milliseconds of ⌘C; browsers
    /// and Electron apps can take a couple of hundred. Much later than this,
    /// a change is likelier something else writing the clipboard.
    static let copyWindow: TimeInterval = 0.5
    private static let pasteboardPollInterval: TimeInterval = 0.025
}
