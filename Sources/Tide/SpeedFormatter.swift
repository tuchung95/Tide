import Foundation

enum SpeedFormatter {

    /// Formats a byte-per-second rate as a short human string, e.g. "1.2 MB/s",
    /// in whichever magnitude system/notation `unit` selects.
    static func format(bytesPerSecond: Double, unit: SpeedUnit = .bytesBinary) -> String {
        switch unit {
        case .bytesBinary:
            return format(bytesPerSecond, base: 1024, units: ["B/s", "KB/s", "MB/s", "GB/s"])
        case .bytesDecimal:
            return format(bytesPerSecond, base: 1000, units: ["B/s", "KB/s", "MB/s", "GB/s"])
        case .bits:
            // Network bit rates are conventionally decimal (Mbps = 10^6
            // bit/s), unlike byte counts which are traditionally binary.
            return format(bytesPerSecond * 8, base: 1000, units: ["bit/s", "Kbit/s", "Mbit/s", "Gbit/s"])
        }
    }

    private static func format(_ magnitude: Double, base: Double, units: [String]) -> String {
        var value = magnitude
        var unitIndex = 0

        while value >= base, unitIndex < units.count - 1 {
            value /= base
            unitIndex += 1
        }

        let decimals = (unitIndex == 0) ? 0 : 1
        return String(format: "%.\(decimals)f %@", value, units[unitIndex])
    }
}
