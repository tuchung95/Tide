import CoreGraphics
import Foundation

/// Makes the keyboard's volume keys drive an external monitor's speakers.
///
/// Ties together the three pieces: VolumeKeyTap catches the keys,
/// AudioOutput says whether macOS could have handled them itself, and
/// DisplayController does the DDC write.
///
/// The rule is deliberately conservative — Tide only takes a key when
/// macOS demonstrably cannot act on it (the output device publishes no
/// volume property) *and* there's an unambiguous monitor to send it to.
/// Anything else passes straight through, so the keys keep working
/// normally the moment output goes back to the Mac's own speakers.
final class MonitorVolumeKeyManager {

    /// Fired on the main thread after a key changed the volume, with the
    /// monitor's name and the new 0…1 level — macOS shows no HUD for a key
    /// Tide swallowed, so the app puts up its own feedback.
    var onVolumeChanged: ((String, Float) -> Void)?

    var onStarted: (() -> Void)? {
        get { keyTap.onStarted }
        set { keyTap.onStarted = newValue }
    }

    var onTapCreationFailedWhileTrusted: (() -> Void)? {
        get { keyTap.onTapCreationFailedWhileTrusted }
        set { keyTap.onTapCreationFailedWhileTrusted = newValue }
    }

    var isRunning: Bool { keyTap.isRunning }

    private let keyTap = VolumeKeyTap()
    private unowned let displayController: DisplayController

    /// Level to come back to when mute is pressed a second time.
    private var premuteVolume: Float?

    /// One sixteenth, matching the step macOS itself uses for the volume
    /// keys; a quarter of that with Shift+Option held, again as macOS does.
    private static let step: Float = 1.0 / 16.0
    private static let fineStep: Float = 1.0 / 64.0
    /// Where unmuting lands when there's no remembered level (the monitor
    /// was already silent when Tide first saw it).
    private static let defaultUnmuteVolume: Float = 0.25

    init(displayController: DisplayController) {
        self.displayController = displayController
        keyTap.isEnabled = { DisplaySettingsStore.useVolumeKeys }
        keyTap.onPress = { [weak self] press, flags in
            self?.handle(press, flags: flags) ?? false
        }
    }

    /// Brings the tap in line with the current setting. Safe to call
    /// repeatedly — at launch and after every settings change.
    @discardableResult
    func apply() -> VolumeKeyTap.StartResult {
        keyTap.apply()
    }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        keyTap.requestAccessibilityPermission()
    }

    // MARK: - Key handling

    /// Returns true when the press was acted on and should be swallowed.
    private func handle(_ press: VolumeKeyTap.Press, flags: CGEventFlags) -> Bool {
        // macOS can drive this output itself — don't get in its way.
        guard let output = AudioOutput.current, !output.canSystemControlVolume else { return false }
        guard let display = targetDisplay(forOutputNamed: output.name) else { return false }

        let current = display.volume
        let newValue: Float

        switch press.key {
        case .mute:
            // Holding mute must not flip it back and forth many times a
            // second; only the initial press counts.
            guard !press.isRepeat else { return true }
            if current > 0 {
                premuteVolume = current
                newValue = 0
            } else {
                newValue = premuteVolume ?? Self.defaultUnmuteVolume
                premuteVolume = nil
            }

        case .up, .down:
            // Shift+Option is the system's own "finer steps" modifier.
            let magnitude = flags.contains(.maskShift) && flags.contains(.maskAlternate)
                ? Self.fineStep
                : Self.step
            let delta = press.key == .up ? magnitude : -magnitude
            newValue = min(max(current + delta, 0), 1)
            // Turning the volume up by hand ends the mute, so the
            // remembered level would be stale.
            if newValue > 0 { premuteVolume = nil }
        }

        // Stepping the cached value rather than re-reading the monitor is
        // what makes a held key produce even steps: a DDC read costs
        // ~100ms, far longer than the gap between auto-repeats, and the
        // write queue already coalesces so only the latest value is sent.
        displayController.setVolume(newValue, forDisplayID: display.info.id)
        onVolumeChanged?(display.info.name, newValue)
        return true
    }

    /// Picks the monitor a volume key should act on.
    ///
    /// Display audio devices are named after the display itself
    /// ("HX270S"), so the name is the reliable link when more than one
    /// monitor is attached. With no usable name, a single volume-capable
    /// monitor is unambiguous; anything else would be guessing, and
    /// guessing wrong means changing the volume of the wrong screen.
    private func targetDisplay(forOutputNamed name: String?) -> DisplayController.ManagedDisplay? {
        let candidates = displayController.displays.filter { $0.supportsVolume }
        guard !candidates.isEmpty else { return nil }

        if let name, !name.isEmpty {
            let matches = candidates.filter { $0.info.name == name }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { return nil }
        }
        return candidates.count == 1 ? candidates[0] : nil
    }
}
