import Foundation
import IOKit
import IOKit.hid

/// Remaps keys per keyboard by setting the HID event system's
/// UserKeyMapping property on each keyboard's service — the mechanism
/// behind `hidutil property --set '{"UserKeyMapping":…}'`, reached through
/// IOHIDEventSystemClient's public API instead of by shelling out.
///
/// Chosen over an event tap (which ScrollDirectionManager and VolumeKeyTap
/// use) because the remap happens inside the keyboard driver, before any
/// key event exists: it needs no Accessibility permission, it also applies
/// in password fields, where Secure Input blinds every tap, and remapped
/// modifiers behave like real ones without rewriting the flags of every
/// later event. The trade-off is that it maps one key to one key only.
///
/// System Settings' own Modifier Keys live in a different property
/// (HIDKeyboardModifierMappingPairs), so the two don't overwrite each other.
///
/// The property belongs to the *service*, not to the physical keyboard: it
/// is gone once the keyboard disconnects (a Bluetooth keyboard after sleep,
/// a USB one replugged) and after a restart. So this watches IOKit for new
/// HID services and reapplies. The flip side is that it survives Tide
/// quitting, which is why the app delegate calls `removeAll()` on the way
/// out.
final class KeyRemapper {

    struct Keyboard: Equatable {
        /// Stable across reconnects and relaunches (see keyboardID(of:)).
        let id: String
        let name: String
        let isBuiltIn: Bool
        let vendorID: Int

        /// Apple's USB vendor ID, or its Bluetooth SIG one.
        var isAppleKeyboard: Bool { vendorID == 0x05AC || vendorID == 0x004C }
    }

    enum Status: Equatable {
        /// The master switch is off.
        case off
        /// On, but no connected keyboard has anything to remap.
        case idle
        case active(keyboardCount: Int)
        /// The driver refused the property for this keyboard.
        case failed(keyboardName: String)
    }

    private(set) var status: Status = .off

    /// Fired after a keyboard connects or disconnects and the remaps have
    /// been brought up to date, so an open Settings window can refresh its
    /// keyboard list and status line.
    var onKeyboardsChanged: (() -> Void)?

    /// While set, every keyboard is put back to unmapped and stays that way
    /// — for the Keyboard pane, which needs to see which key was physically
    /// pressed, not what Tide currently turns it into. Clearing it reapplies.
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            apply()
        }
    }

    /// Services Tide has put a mapping on, by registry ID. Only these are
    /// ever cleared: a mapping someone set with hidutil on a keyboard Tide
    /// has nothing for isn't Tide's to remove.
    private var remappedServiceIDs: Set<UInt64> = []

    private var notificationPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var pendingReapplies: [DispatchWorkItem] = []

    /// A keyboard's IOKit service appears a moment before the HID event
    /// system has its own client for it, and only the latter takes the
    /// property, so a new keyboard is remapped after a short settle. The
    /// later pass catches a slow one instead of leaving it unmapped until
    /// the next change; passes that find nothing to do write nothing.
    private static let reapplyDelays: [TimeInterval] = [1, 4]

    func start() {
        observeServiceChanges()
        apply()
    }

    /// Every keyboard connected right now, one entry per physical keyboard
    /// even when it exposes several keyboard services.
    var connectedKeyboards: [Keyboard] {
        var seen = Set<String>()
        return keyboardServices()
            .compactMap { seen.insert($0.keyboard.id).inserted ? $0.keyboard : nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Brings every connected keyboard in line with KeyRemapStore. Safe to
    /// call repeatedly: a keyboard already carrying the right mapping isn't
    /// written to again.
    @discardableResult
    func apply() -> Status {
        let isEnabled = KeyRemapStore.isEnabled && !isSuspended
        var stillRemapped: Set<UInt64> = []
        var activeKeyboardIDs: Set<String> = []
        var failedKeyboardName: String?

        for service in keyboardServices() {
            let wanted = isEnabled ? KeyRemapStore.effectiveRemaps(for: service.keyboard) : []

            if wanted.isEmpty {
                if remappedServiceIDs.contains(service.registryID), !Self.setRemaps([], on: service.client) {
                    stillRemapped.insert(service.registryID)
                }
                continue
            }

            if Self.currentRemaps(of: service.client) == wanted || Self.setRemaps(wanted, on: service.client) {
                stillRemapped.insert(service.registryID)
                activeKeyboardIDs.insert(service.keyboard.id)
            } else {
                NSLog("Tide: could not remap keys on \(service.keyboard.name)")
                failedKeyboardName = failedKeyboardName ?? service.keyboard.name
                if remappedServiceIDs.contains(service.registryID) {
                    stillRemapped.insert(service.registryID)
                }
            }
        }
        // Rebuilt rather than added to, so services that have since
        // disappeared drop out with their keyboards.
        remappedServiceIDs = stillRemapped

        // A suspension lasts one key press; the status line should go on
        // describing the settings rather than flash "Off" for it.
        guard !isSuspended else { return status }
        if !isEnabled {
            status = .off
        } else if let failedKeyboardName {
            status = .failed(keyboardName: failedKeyboardName)
        } else if activeKeyboardIDs.isEmpty {
            status = .idle
        } else {
            status = .active(keyboardCount: activeKeyboardIDs.count)
        }
        return status
    }

    /// Puts back every keyboard Tide has remapped. For quitting: the
    /// property would otherwise outlive the app until the next restart.
    func removeAll() {
        for service in keyboardServices() where remappedServiceIDs.contains(service.registryID) {
            Self.setRemaps([], on: service.client)
        }
        remappedServiceIDs.removeAll()
    }

    // MARK: - Keyboard services

    private struct Service {
        let client: IOHIDServiceClient
        let registryID: UInt64
        let keyboard: Keyboard
        /// The event system client `client` came from. A service client
        /// reaches the event system through it without keeping it alive,
        /// so it's held here for as long as the service is.
        let eventSystem: IOHIDEventSystemClient
    }

    /// A fresh event system client on every call rather than one kept
    /// around: a client nobody schedules isn't told about services that
    /// appear after it was created, and building one costs a few
    /// milliseconds, against calls that only come from settings changes
    /// and keyboards connecting.
    private func keyboardServices() -> [Service] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return [] }

        var keyboards: [Service] = []
        var mediaKeyCandidates: [Service] = []
        for service in services {
            let isKeyboard = IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0
            let isMediaKeys = !isKeyboard
                && IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_Consumer), UInt32(kHIDUsage_Csmr_ConsumerControl)) != 0
            guard isKeyboard || isMediaKeys,
                  let registryID = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
            else { continue }

            let entry = Service(client: service, registryID: registryID,
                                keyboard: Self.describe(service, registryID: registryID), eventSystem: client)
            if isKeyboard {
                keyboards.append(entry)
            } else {
                mediaKeyCandidates.append(entry)
            }
        }

        // A keyboard's media and volume keys often arrive through a
        // Consumer Control service of their own, which has to carry the
        // same mapping for those keys to work as sources. Only ones that
        // belong to a keyboard found above, though: audio gear (a USB DAC,
        // a headset's buttons) has Consumer Control services too, and
        // isn't a keyboard to list or remap.
        let keyboardsByID = Dictionary(keyboards.map { ($0.keyboard.id, $0.keyboard) }) { first, _ in first }
        let mediaKeyServices = mediaKeyCandidates.compactMap { candidate -> Service? in
            guard let keyboard = keyboardsByID[candidate.keyboard.id] else { return nil }
            return Service(client: candidate.client, registryID: candidate.registryID, keyboard: keyboard, eventSystem: client)
        }
        return keyboards + mediaKeyServices
    }

    private static func describe(_ service: IOHIDServiceClient, registryID: UInt64) -> Keyboard {
        let product = (property(service, kIOHIDProductKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Keyboard(
            id: keyboardID(of: service, registryID: registryID, product: product),
            name: product.isEmpty ? "Keyboard" : product,
            isBuiltIn: (property(service, kIOHIDBuiltInKey) as? NSNumber)?.boolValue ?? false,
            vendorID: (property(service, kIOHIDVendorIDKey) as? NSNumber)?.intValue ?? 0
        )
    }

    /// The keyboard a key event came from, given the event's sender ID
    /// (CGEvent field 87, the same one ScrollDirectionManager reads). Which
    /// registry entry that ID names — the HID event service or the device
    /// beneath it — isn't documented, so both are accepted: the service
    /// itself, then its providers up the service plane.
    func keyboard(forSenderID senderID: UInt64) -> Keyboard? {
        guard senderID != 0 else { return nil }
        return keyboardServices().first { service in
            service.registryID == senderID || Self.providerIDs(ofRegistryID: service.registryID).contains(senderID)
        }?.keyboard
    }

    /// Registry IDs of an entry's providers, nearest first. A few levels
    /// covers service → interface → device; beyond that are buses and
    /// controllers, which no key event names as its sender.
    private static func providerIDs(ofRegistryID registryID: UInt64) -> [UInt64] {
        var ids: [UInt64] = []
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        for _ in 0..<4 where entry != 0 {
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            entry = result == KERN_SUCCESS ? parent : 0
            var parentID: UInt64 = 0
            if entry != 0, IORegistryEntryGetRegistryEntryID(entry, &parentID) == KERN_SUCCESS {
                ids.append(parentID)
            }
        }
        if entry != 0 {
            IOObjectRelease(entry)
        }
        return ids
    }

    /// An ID that names the same keyboard every time it connects. The
    /// registry ID can't be it — that's per service, new on every
    /// reconnect — and neither can vendor/product IDs alone: Bluetooth LE
    /// keyboards often report 0 for both. In order of preference:
    ///
    /// - PhysicalDeviceUniqueID, which Bluetooth keyboards carry (derived
    ///   from the device's address). Not exposed through the service
    ///   client, so it's read off the registry entry itself.
    /// - The serial number, alongside vendor and product IDs.
    /// - Vendor, product and name — the best that's left; two identical
    ///   keyboards without serials end up sharing their remaps.
    private static func keyboardID(of service: IOHIDServiceClient, registryID: UInt64, product: String) -> String {
        if let uniqueID = registryProperty(registryID: registryID, key: "PhysicalDeviceUniqueID") as? String, !uniqueID.isEmpty {
            return "uid:\(uniqueID)"
        }
        let vendorID = (property(service, kIOHIDVendorIDKey) as? NSNumber)?.intValue ?? 0
        let productID = (property(service, kIOHIDProductIDKey) as? NSNumber)?.intValue ?? 0
        if let serial = property(service, kIOHIDSerialNumberKey) as? String, !serial.isEmpty {
            return "serial:\(vendorID):\(productID):\(serial)"
        }
        return "model:\(vendorID):\(productID):\(product)"
    }

    private static func property(_ service: IOHIDServiceClient, _ key: String) -> Any? {
        IOHIDServiceClientCopyProperty(service, key as CFString)
    }

    private static func registryProperty(registryID: UInt64, key: String) -> Any? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // MARK: - The UserKeyMapping property

    private static let mappingKey = kIOHIDUserKeyUsageMapKey
    private static let sourceKey = kIOHIDKeyboardModifierMappingSrcKey
    private static let destinationKey = kIOHIDKeyboardModifierMappingDstKey

    private static func currentRemaps(of service: IOHIDServiceClient) -> [KeyRemap] {
        guard let pairs = property(service, mappingKey) as? [[String: NSNumber]] else { return [] }
        return pairs.compactMap { pair in
            guard let from = pair[sourceKey]?.uint64Value, let to = pair[destinationKey]?.uint64Value else { return nil }
            return KeyRemap(from: from, to: to)
        }
        .sorted { $0.from < $1.from }
    }

    /// An empty array clears the mapping.
    @discardableResult
    private static func setRemaps(_ remaps: [KeyRemap], on service: IOHIDServiceClient) -> Bool {
        let pairs = remaps.map { [sourceKey: NSNumber(value: $0.from), destinationKey: NSNumber(value: $0.to)] }
        return IOHIDServiceClientSetProperty(service, mappingKey as CFString, pairs as CFArray)
    }

    // MARK: - Connect/disconnect notifications

    /// Plain IOKit service notifications, like ScrollDeviceRegistry's
    /// registry reads: watching for services needs no permission, where
    /// opening an IOHIDManager to hear about devices would trip the Input
    /// Monitoring prompt.
    private func observeServiceChanges() {
        guard notificationPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)

        let callback: IOServiceMatchingCallback = { refcon, iterator in
            KeyRemapper.drain(iterator)
            guard let refcon else { return }
            Unmanaged<KeyRemapper>.fromOpaque(refcon).takeUnretainedValue().servicesDidChange()
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Every IOHIDEventService rather than only keyboards: a service's
        // usages aren't known to IOKit matching, and anything else that
        // turns up just costs one pass that finds nothing to change.
        // Each iterator has to be drained once here to arm it.
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOHIDEventService"),
                                         callback, refcon, &matchedIterator)
        Self.drain(matchedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOHIDEventService"),
                                         callback, refcon, &terminatedIterator)
        Self.drain(terminatedIterator)
    }

    private func servicesDidChange() {
        pendingReapplies.forEach { $0.cancel() }
        pendingReapplies = Self.reapplyDelays.map { delay in
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.apply()
                self.onKeyboardsChanged?()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }
}
