import CoreAudio
import Foundation

/// What macOS is currently playing sound through, and — the part that
/// matters here — whether macOS can control that device's volume at all.
///
/// A monitor's speakers reached over HDMI or DisplayPort typically expose
/// *no* volume property whatsoever:
///
///     default output: HX270S   transport dprt
///     kAudioDevicePropertyVolumeScalar   has = false
///
/// That's why the keyboard's volume keys do nothing there and the HUD
/// shows a "prohibited" sign — there is simply no knob for the system to
/// turn. That absence is exactly the signal MonitorVolumeKeyManager uses
/// to decide when Tide should take the keys over and drive the monitor's
/// own volume over DDC instead. An output macOS *can* handle is left
/// entirely alone.
///
/// Queried fresh on each keypress rather than cached: it's a couple of
/// property reads, and it means switching output device takes effect on
/// the very next key without anything to keep in sync.
enum AudioOutput {

    struct Device {
        let id: AudioDeviceID
        /// Matches the display's name for display audio ("HX270S"), which
        /// is how the right monitor gets picked when several are attached.
        let name: String?
        /// False when the device publishes no volume property for macOS to
        /// set — display audio, almost always.
        let canSystemControlVolume: Bool
    }

    /// The device sound is currently going to, or nil when CoreAudio has
    /// no default output at all.
    static var current: Device? {
        guard let id = defaultOutputDeviceID() else { return nil }
        return Device(
            id: id,
            name: stringProperty(id, kAudioObjectPropertyName),
            canSystemControlVolume: hasVolumeControl(id)
        )
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Whether macOS has any volume knob for this device.
    ///
    /// The main element is checked first and then the individual channels:
    /// devices differ in which one they publish, and offering either is
    /// enough to mean macOS can cope on its own.
    private static func hasVolumeControl(_ deviceID: AudioDeviceID) -> Bool {
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            if AudioObjectHasProperty(deviceID, &address) { return true }
        }
        return false
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
