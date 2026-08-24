import Foundation

enum SpeedFormatter {

    /// Formats a byte-per-second rate as a short human string, e.g. "1.2 MB/s".
    static func format(bytesPerSecond: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = bytesPerSecond
        var unitIndex = 0

        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let decimals = (unitIndex == 0) ? 0 : 1
        return String(format: "%.\(decimals)f %@", value, units[unitIndex])
    }
}
