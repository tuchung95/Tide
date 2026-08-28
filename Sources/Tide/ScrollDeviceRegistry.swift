import Foundation
import IOKit
import IOKit.hid

/// Maps a scroll event's originating device to "mouse" or "trackpad".
///
/// A CGEvent carries the IORegistry entry ID of the HID device that
/// produced it in an undocumented-but-stable integer field (87, the sender
/// ID). Looking that ID up against the IORegistry's own IOHIDDevice
/// entries is the only way to tell a Magic Mouse from a trackpad: both
/// send *continuous* (pixel) scroll events, so the usual
/// `kCGScrollWheelEventIsContinuous` heuristic lumps them together.
///
/// Deliberately reads the registry directly (IOServiceGetMatchingServices
/// + IORegistryEntryCreateCFProperty) rather than opening an IOHIDManager:
/// opening HID devices for listening trips the Input Monitoring privacy
/// prompt, while plain registry properties need no permission at all.
///
/// Not thread-safe by design — it's only touched from the event tap
/// callback and the settings pane, both on the main run loop.
final class ScrollDeviceRegistry {

    enum Category {
        case mouse
        case trackpad
    }

    private var categoriesByRegistryID: [UInt64: Category] = [:]
    private var lastRefresh: TimeInterval = 0
    /// A device plugged in after the last scan shows up as an unknown
    /// sender ID; rescanning has a real cost (dozens of registry entries),
    /// so unknown IDs only trigger at most one rescan per this interval.
    private static let refreshCooldown: TimeInterval = 2

    init() {
        refresh()
    }

    /// nil when the sender ID isn't a device we could classify (0, an
    /// entry without usable properties, or a synthetic/posted event).
    func category(forSenderID senderID: UInt64) -> Category? {
        guard senderID != 0 else { return nil }
        if let known = categoriesByRegistryID[senderID] {
            return known
        }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastRefresh >= Self.refreshCooldown else { return nil }
        refresh()
        return categoriesByRegistryID[senderID]
    }

    /// Rebuilds the whole map rather than patching it: devices disappear
    /// on sleep/unpair too, and a full scan is simpler than tracking both
    /// directions.
    private func refresh() {
        lastRefresh = Date().timeIntervalSinceReferenceDate

        guard let matching = IOServiceMatching("IOHIDDevice") else { return }
        var iterator: io_iterator_t = 0
        // Matching on "IOHIDDevice" also picks up its subclasses, which is
        // what the concrete entries actually are (AppleUserHIDDevice and
        // friends on recent macOS).
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        var found: [UInt64: Category] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else { continue }
            guard let category = Self.classify(service: service) else { continue }
            found[registryID] = category
        }
        categoriesByRegistryID = found
    }

    private static func classify(service: io_service_t) -> Category? {
        let product = (property(service, kIOHIDProductKey) as? String) ?? ""

        // Name first: the built-in trackpad reports itself as "Apple
        // Internal Keyboard / Trackpad" — a composite device that also
        // exposes a plain mouse usage, so its usage pairs alone would read
        // as a mouse.
        if product.range(of: "trackpad", options: .caseInsensitive) != nil {
            return .trackpad
        }
        if product.range(of: "mouse", options: .caseInsensitive) != nil {
            return .mouse
        }

        if usagePairs(service).contains(where: { $0.page == kHIDPage_Digitizer && $0.usage == kHIDUsage_Dig_TouchPad }) {
            return .trackpad
        }

        let page = (property(service, kIOHIDPrimaryUsagePageKey) as? Int) ?? 0
        let usage = (property(service, kIOHIDPrimaryUsageKey) as? Int) ?? 0
        if page == kHIDPage_GenericDesktop && (usage == kHIDUsage_GD_Mouse || usage == kHIDUsage_GD_Pointer) {
            return .mouse
        }
        return nil
    }

    private static func usagePairs(_ service: io_service_t) -> [(page: Int, usage: Int)] {
        guard let pairs = property(service, kIOHIDDeviceUsagePairsKey) as? [[String: Any]] else { return [] }
        return pairs.compactMap { pair in
            guard let page = pair[kIOHIDDeviceUsagePageKey] as? Int,
                  let usage = pair[kIOHIDDeviceUsageKey] as? Int else { return nil }
            return (page, usage)
        }
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
}
