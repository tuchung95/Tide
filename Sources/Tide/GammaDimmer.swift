import CoreGraphics
import Foundation

/// Last-resort brightness for external displays that don't answer DDC —
/// cheap HDMI panels, most TVs, and anything behind a DisplayPort hub or
/// KVM that eats the I2C channel.
///
/// This doesn't touch the backlight; it scales the colour ramp the GPU
/// sends to the monitor, so the picture gets darker while the panel keeps
/// burning the same amount of light. That costs contrast in the shadows,
/// which is why it's only ever used when the real thing isn't available.
enum GammaDimmer {

    /// Displays currently being dimmed and the brightness each is set to,
    /// so they can be released individually (a display that gains DDC
    /// after a replug) or all at once (app quit). The values are needed
    /// because releasing one display resets them all — see `release`.
    private static var dimmedDisplays: [CGDirectDisplayID: Float] = [:]

    /// A gamma ramp can only scale *down* from what the panel is already
    /// showing, so 100% is "untouched". The floor stops at 25% rather than
    /// 0% because a fully black screen would leave the user with no way to
    /// see the menu they'd need to undo it.
    private static let minimumFactor: CGGammaValue = 0.25

    /// `brightness` is 0…1 in the same units as every other transport, so
    /// callers don't need to know which one they got.
    static func apply(displayID: CGDirectDisplayID, brightness: Float) {
        let clamped = min(max(brightness, 0), 1)
        let factor = minimumFactor + (1 - minimumFactor) * clamped

        // Identical ramp on all three channels: this is a neutral dim, not
        // a colour adjustment.
        let status = CGSetDisplayTransferByFormula(
            displayID,
            0, factor, 1,
            0, factor, 1,
            0, factor, 1
        )
        guard status == .success else {
            NSLog("Tide: gamma dim failed for display \(displayID) (status \(status.rawValue))")
            return
        }
        dimmedDisplays[displayID] = clamped
    }

    /// Puts one display's ramp back to the system's own profile.
    static func release(displayID: CGDirectDisplayID) {
        guard dimmedDisplays.removeValue(forKey: displayID) != nil else { return }
        CGDisplayRestoreColorSyncSettings()

        // CGDisplayRestoreColorSyncSettings has no per-display form, so
        // that call just reset every display — including any others Tide
        // was still dimming. Re-apply those.
        let stillDimmed = dimmedDisplays
        dimmedDisplays.removeAll()
        for (id, brightness) in stillDimmed {
            apply(displayID: id, brightness: brightness)
        }
    }

    /// Called on quit: a gamma ramp survives the process that set it, so
    /// skipping this would leave the user staring at a permanently dim
    /// screen with no app left to fix it.
    static func releaseAll() {
        guard !dimmedDisplays.isEmpty else { return }
        dimmedDisplays.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }

    static func isDimming(displayID: CGDirectDisplayID) -> Bool {
        dimmedDisplays[displayID] != nil
    }
}
