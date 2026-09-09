import Foundation

/// Compact durations for log lines and the menu bar: `41s`, `12m03s`, `1h02m`.
public enum FleetDurationFormatter {
    public static func string(from duration: Duration) -> String {
        string(from: TimeInterval(duration.components.seconds))
    }

    public static func string(from interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%dh%02dm", hours, minutes)
        }
        if minutes > 0 {
            return String(format: "%dm%02ds", minutes, seconds)
        }
        return "\(seconds)s"
    }
}
