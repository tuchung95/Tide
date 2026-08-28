import AppKit

/// One connected display, plus everything needed to talk to it and to
/// recognise it again after it's been unplugged and plugged back in.
///
/// `CGDirectDisplayID` is deliberately NOT used for persistence: macOS
/// hands out those ids per session, so the same monitor gets a different
/// number after a reboot (or sometimes just after a sleep/wake cycle).
struct DisplayInfo {

    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool

    /// EDID-derived identity, also used to pair a display with its DDC
    /// transport (see DDCService).
    let vendorNumber: UInt32
    let modelNumber: UInt32
    let serialNumber: UInt32

    /// Stable across replugs, so the last brightness/volume the user chose
    /// can be restored when this monitor comes back.
    ///
    /// Most monitors report a serial of 0, which is why the model name is
    /// folded in too: two different displays from the same vendor with the
    /// same model number and no serial genuinely are indistinguishable
    /// here, and sharing one saved value is a better failure mode than
    /// having neither of them remember anything.
    var persistenceKey: String {
        "\(vendorNumber)-\(modelNumber)-\(serialNumber)-\(name)"
    }

    /// Every display macOS currently considers online, in the order
    /// CoreGraphics reports them (main display first).
    static func onlineDisplays() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

        let names = screenNamesByDisplayID()

        return ids.compactMap { id in
            // A mirrored secondary shows the primary's image, so exposing
            // its own brightness slider would be a control with no visible
            // effect. Skip it.
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }

            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            return DisplayInfo(
                id: id,
                name: names[id] ?? (isBuiltIn ? "Built-in Display" : "External Display"),
                isBuiltIn: isBuiltIn,
                vendorNumber: CGDisplayVendorNumber(id),
                modelNumber: CGDisplayModelNumber(id),
                serialNumber: CGDisplaySerialNumber(id)
            )
        }
    }

    /// NSScreen is the only public source of the human-readable name macOS
    /// itself shows ("Color LCD", "DELL U2720Q"); CoreGraphics has no
    /// equivalent, so the two lists are joined on the display id NSScreen
    /// stashes in its deviceDescription.
    private static func screenNamesByDisplayID() -> [CGDirectDisplayID: String] {
        var result: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            result[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
        }
        return result
    }
}
