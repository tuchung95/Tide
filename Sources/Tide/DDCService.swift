import CoreGraphics
import Foundation
import IOKit

/// DDC/CI transport for external monitors on Apple Silicon.
///
/// DDC/CI is the standard the monitor's own on-screen menu speaks: a tiny
/// I2C conversation over the video cable that can read and write "VCP"
/// feature codes (0x10 = brightness, 0x62 = speaker volume). macOS exposes
/// no public API for it, so this goes through IOKit's `IOAVService*`
/// functions — present in the shipping IOKit binary but absent from its
/// headers, hence the dlsym lookups below rather than a plain import.
///
/// Apple Silicon only. The Intel path would need `IOI2CInterface`, which
/// is header-only C that Swift can't reach without a bridging header, and
/// this project compiles with bare `swiftc` (see Scripts/build_app.sh).
/// On Intel every external display simply reports DDC as unavailable and
/// DisplayController falls back to gamma dimming.
final class DDCService {

    /// VCP feature codes, from the MCCS spec.
    enum VCP: UInt8 {
        case brightness = 0x10
        case volume = 0x62
    }

    /// One monitor's I2C endpoint — an opaque `IOAVService` CF object.
    ///
    /// Held as `CFTypeRef` so ARC owns it: `IOAVServiceCreateWithService`
    /// follows the Create Rule (+1 retained), and `takeRetainedValue()` at
    /// the call site hands that reference over to ARC.
    private let service: CFTypeRef

    private init(service: CFTypeRef) {
        self.service = service
    }

    /// The raw pointer the I2C functions expect. Unretained: `service`
    /// keeps the object alive for the whole call.
    private var servicePointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(service as AnyObject).toOpaque()
    }

    // MARK: - Discovery

    /// Pairs every external display with its DDC endpoint.
    ///
    /// The IORegistry doesn't link the two directly, so this walks the
    /// service plane in order and relies on the layout Apple's display
    /// stack produces: each display's `AppleCLCD2` (or
    /// `IOMobileFramebufferShim`) node — which carries the EDID identity
    /// in `DisplayAttributes.ProductAttributes` — is followed by the
    /// `DCPAVServiceProxy` node that owns its I2C channel.
    static func discover(for displays: [DisplayInfo]) -> [CGDirectDisplayID: DDCService] {
        let externals = displays.filter { !$0.isBuiltIn }
        guard !externals.isEmpty, isAvailable else { return [:] }

        let endpoints = externalEndpoints()
        guard !endpoints.isEmpty else {
            NSLog("Tide: DDC found no external AV services for \(externals.count) external display(s)")
            return [:]
        }

        var result: [CGDirectDisplayID: DDCService] = [:]
        var unmatched = endpoints

        // Preferred pass: match on the EDID numbers, which is the only way
        // to get the pairing right when several monitors are attached.
        for display in externals {
            guard let index = unmatched.firstIndex(where: { $0.matches(display) }) else { continue }
            result[display.id] = DDCService(service: unmatched.remove(at: index).service)
        }

        // Fallback: registry order. Apple's own ProductAttributes are
        // inconsistent between display models (some report the EDID serial,
        // some an "AlphanumericSerialNumber", some neither), so a failed
        // match is common — and with a single external display, which is
        // the overwhelmingly common setup, order is unambiguous anyway.
        for display in externals where result[display.id] == nil {
            guard !unmatched.isEmpty else { break }
            result[display.id] = DDCService(service: unmatched.removeFirst().service)
        }

        NSLog("Tide: DDC paired \(result.count)/\(externals.count) external display(s)")
        return result
    }

    /// An `IOAVService` for one externally-connected port, plus the EDID
    /// identity of the display node that preceded it in the registry.
    private struct Endpoint {
        let service: CFTypeRef
        let vendorID: UInt32?
        let productID: UInt32?
        let serialNumber: UInt32?

        /// Deliberately requires a positive product match rather than
        /// accepting "all the fields we have happen to be nil" — that
        /// would match every display at once.
        func matches(_ display: DisplayInfo) -> Bool {
            guard let productID, productID == display.modelNumber else { return false }
            if let vendorID, vendorID != display.vendorNumber { return false }
            if let serialNumber, display.serialNumber != 0, serialNumber != display.serialNumber {
                return false
            }
            return true
        }
    }

    private static func externalEndpoints() -> [Endpoint] {
        guard let createWithService = Symbols.shared?.createWithService else { return [] }

        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(
            kIOMainPortDefault,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var endpoints: [Endpoint] = []
        var pendingAttributes: [String: Any]?

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }

            guard let className = entryClassName(entry) else { continue }

            if className == "AppleCLCD2" || className == "IOMobileFramebufferShim" {
                pendingAttributes = productAttributes(of: entry)
                continue
            }

            guard className == "DCPAVServiceProxy" else { continue }

            // "Embedded" is the built-in panel, which has no DDC at all —
            // its brightness goes through DisplayServices instead.
            guard registryString(entry, "Location") == "External" else {
                pendingAttributes = nil
                continue
            }

            guard let raw = createWithService(kCFAllocatorDefault, entry) else {
                pendingAttributes = nil
                continue
            }
            // Create Rule: the +1 reference is transferred to ARC here.
            let service = Unmanaged<CFTypeRef>.fromOpaque(raw).takeRetainedValue()

            let attributes = pendingAttributes
            pendingAttributes = nil
            endpoints.append(Endpoint(
                service: service,
                vendorID: edidNumber(attributes, "LegacyManufacturerID"),
                productID: edidNumber(attributes, "ProductID"),
                serialNumber: edidNumber(attributes, "SerialNumber")
            ))
        }

        return endpoints
    }

    /// Reads one EDID field out of `ProductAttributes`, rejecting anything
    /// that can't be a real EDID value. Apple's own built-in panels report
    /// a 48-bit `ProductID` there, and blindly truncating that to 32 bits
    /// could collide with a genuine external monitor's model number.
    private static func edidNumber(_ attributes: [String: Any]?, _ key: String) -> UInt32? {
        guard let value = (attributes?[key] as? NSNumber)?.int64Value,
              value >= 0, value <= Int64(UInt32.max)
        else { return nil }
        return UInt32(value)
    }

    private static func entryClassName(_ entry: io_registry_entry_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &buffer) == KERN_SUCCESS else { return nil }
        return String(cString: buffer)
    }

    private static func registryString(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private static func productAttributes(of entry: io_registry_entry_t) -> [String: Any]? {
        guard let attributes = IORegistryEntryCreateCFProperty(
            entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any] else { return nil }
        return attributes["ProductAttributes"] as? [String: Any]
    }

    // MARK: - VCP read / write

    /// Reads a feature's current and maximum value, or nil if the monitor
    /// doesn't answer.
    ///
    /// Retried a few times because DDC has no delivery guarantees at all:
    /// a monitor that's still waking, or busy with its own OSD, just drops
    /// the request on the floor.
    func read(_ vcp: VCP) -> (current: UInt16, max: UInt16)? {
        for attempt in 0..<Self.attemptCount {
            if attempt > 0 { usleep(Self.retryDelayMicroseconds) }
            if let value = attemptRead(vcp) { return value }
        }
        return nil
    }

    @discardableResult
    func write(_ vcp: VCP, value: UInt16) -> Bool {
        guard let writeI2C = Symbols.shared?.writeI2C else { return false }

        var packet: [UInt8] = [
            0x84,                       // source address + length byte
            0x03,                       // "set VCP feature" opcode
            vcp.rawValue,
            UInt8(value >> 8),
            UInt8(value & 0xFF),
            0                           // checksum, filled in below
        ]
        packet[5] = Self.checksum(seed: Self.writeChecksumSeed, bytes: packet, upTo: 5)
        // Read out here rather than inside the closure: `packet` is
        // exclusively borrowed for the duration of withUnsafeMutableBytes.
        let packetLength = UInt32(packet.count)

        for attempt in 0..<Self.attemptCount {
            if attempt > 0 { usleep(Self.retryDelayMicroseconds) }
            let status = packet.withUnsafeMutableBytes { buffer in
                writeI2C(servicePointer, Self.chipAddress, Self.dataOffset, buffer.baseAddress!, packetLength)
            }
            if status == KERN_SUCCESS { return true }
        }
        return false
    }

    private func attemptRead(_ vcp: VCP) -> (current: UInt16, max: UInt16)? {
        guard let symbols = Symbols.shared else { return nil }

        var request: [UInt8] = [
            0x82,                       // source address + length byte
            0x01,                       // "get VCP feature" opcode
            vcp.rawValue,
            0                           // checksum, filled in below
        ]
        request[3] = Self.checksum(seed: Self.writeChecksumSeed, bytes: request, upTo: 3)
        let requestLength = UInt32(request.count)

        let writeStatus = request.withUnsafeMutableBytes { buffer in
            symbols.writeI2C(servicePointer, Self.chipAddress, Self.dataOffset, buffer.baseAddress!, requestLength)
        }
        guard writeStatus == KERN_SUCCESS else { return nil }

        // The spec allows the monitor up to 40ms to prepare its reply;
        // reading too early returns garbage rather than blocking.
        usleep(Self.replyDelayMicroseconds)

        var reply = [UInt8](repeating: 0, count: Self.replyLength)
        let readStatus = reply.withUnsafeMutableBytes { buffer in
            symbols.readI2C(servicePointer, Self.chipAddress, 0, buffer.baseAddress!, UInt32(Self.replyLength))
        }
        guard readStatus == KERN_SUCCESS else { return nil }

        // Expected reply: 6E 88 02 00 <vcp> <type> <max hi> <max lo> <cur hi> <cur lo> ...
        // A result code (reply[2]) other than 0 means "unsupported feature",
        // which is how a monitor without speakers answers a volume query.
        guard reply[1] == 0x88, reply[2] == 0x00, reply[4] == vcp.rawValue else { return nil }

        let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard max > 0 else { return nil }
        return (current: min(current, max), max: max)
    }

    /// DDC's checksum is a plain XOR of every byte, seeded with the
    /// destination address the packet is being sent to.
    private static func checksum(seed: UInt8, bytes: [UInt8], upTo end: Int) -> UInt8 {
        var result = seed
        for index in 0..<end {
            result ^= bytes[index]
        }
        return result
    }

    // MARK: - Constants

    /// 0x37 is the DDC/CI display address; 0x51 the host's own address,
    /// which doubles as the offset writes are addressed to.
    private static let chipAddress: UInt32 = 0x37
    private static let dataOffset: UInt32 = 0x51
    private static let writeChecksumSeed: UInt8 = 0x6E ^ 0x51
    private static let replyLength = 12
    private static let attemptCount = 3
    private static let retryDelayMicroseconds: UInt32 = 40_000
    private static let replyDelayMicroseconds: UInt32 = 40_000

    static var isAvailable: Bool { Symbols.shared != nil }

    // MARK: - Private IOKit symbols

    /// `IOAVService*` ships in IOKit but isn't declared in any public
    /// header, so it's resolved at runtime. Failing to find it is treated
    /// as "no DDC on this machine" rather than as an error: that's exactly
    /// what a future macOS that removes these symbols should degrade to.
    private final class Symbols {

        // Everything is passed as raw pointers rather than as CF types:
        // Swift's automatic CF bridging only applies to functions it has a
        // header for, and getting the retain/release ownership wrong on a
        // dlsym'd Create function is a use-after-free waiting to happen.
        typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
        typealias TransferI2C = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

        let createWithService: CreateWithService
        let writeI2C: TransferI2C
        let readI2C: TransferI2C

        static let shared: Symbols? = Symbols()

        private init?() {
            #if !arch(arm64)
            NSLog("Tide: DDC unavailable (Intel Mac); external displays will use software dimming")
            return nil
            #else
            guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
                  let create = dlsym(handle, "IOAVServiceCreateWithService"),
                  let write = dlsym(handle, "IOAVServiceWriteI2C"),
                  let read = dlsym(handle, "IOAVServiceReadI2C")
            else {
                NSLog("Tide: DDC unavailable (IOAVService symbols missing)")
                return nil
            }
            createWithService = unsafeBitCast(create, to: CreateWithService.self)
            writeI2C = unsafeBitCast(write, to: TransferI2C.self)
            readI2C = unsafeBitCast(read, to: TransferI2C.self)
            #endif
        }
    }
}
