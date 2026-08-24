import Foundation

/// Reads per-interface byte counters via getifaddrs and computes
/// download/upload throughput by diffing successive samples.
final class NetworkMonitor {

    struct Sample {
        var downloadBytesPerSecond: Double
        var uploadBytesPerSecond: Double
    }

    /// Interfaces to aggregate. Physical Wi-Fi / Ethernet adapters on macOS
    /// are named en0, en1, ... Restricting to these avoids double-counting
    /// traffic that also passes through virtual interfaces (bridge, utun,
    /// awdl, llw, etc).
    private let interfacePrefix = "en"

    private var lastReceivedBytes: UInt64?
    private var lastSentBytes: UInt64?
    private var lastTimestamp: Date?

    /// Takes a new reading and returns the current throughput.
    /// Returns nil on the very first call (no prior sample to diff against).
    @discardableResult
    func poll() -> Sample? {
        let now = Date()
        let (received, sent) = Self.currentByteCounters(matchingPrefix: interfacePrefix)

        defer {
            lastReceivedBytes = received
            lastSentBytes = sent
            lastTimestamp = now
        }

        guard
            let prevReceived = lastReceivedBytes,
            let prevSent = lastSentBytes,
            let prevTime = lastTimestamp
        else {
            return nil
        }

        let elapsed = now.timeIntervalSince(prevTime)
        guard elapsed > 0 else { return nil }

        // Counters can wrap or reset (e.g. interface re-associates); guard
        // against negative deltas by clamping to zero.
        let downDelta = received >= prevReceived ? received - prevReceived : 0
        let upDelta = sent >= prevSent ? sent - prevSent : 0

        return Sample(
            downloadBytesPerSecond: Double(downDelta) / elapsed,
            uploadBytesPerSecond: Double(upDelta) / elapsed
        )
    }

    private static func currentByteCounters(matchingPrefix prefix: String) -> (received: UInt64, sent: UInt64) {
        var totalReceived: UInt64 = 0
        var totalSent: UInt64 = 0

        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else {
            return (0, 0)
        }
        defer { freeifaddrs(ifaddrPointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            let addr = current.pointee
            guard let name = addr.ifa_name.map({ String(cString: $0) }) else { continue }
            guard name.hasPrefix(prefix) else { continue }

            // Byte counters live on the AF_LINK entry for the interface.
            guard let sockaddrPointer = addr.ifa_addr,
                  sockaddrPointer.pointee.sa_family == UInt8(AF_LINK)
            else { continue }

            let flags = Int32(addr.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            guard let dataPointer = addr.ifa_data else { continue }
            let networkData = dataPointer.assumingMemoryBound(to: if_data.self).pointee

            totalReceived += UInt64(networkData.ifi_ibytes)
            totalSent += UInt64(networkData.ifi_obytes)
        }

        return (totalReceived, totalSent)
    }
}
