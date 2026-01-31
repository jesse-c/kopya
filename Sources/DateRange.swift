import Foundation

// MARK: - Date Helpers

struct DateRange {
    let start: Date
    let end: Date

    // MARK: - ParseRelative Helper Methods

    /// Parse combined time format like "1h30m"
    private static func parseCombinedFormat(_ input: String, relativeTo now: Date) -> DateRange? {
        // Split by 'h' to get hours and minutes parts
        let parts = input.split(separator: "h")
        guard parts.count == 2,
              let hours = Int(parts[0]),
              hours > 0 else {
            return nil
        }

        // Get the minutes part (remove the 'm' at the end)
        let minutesPart = parts[1]
        guard minutesPart.hasSuffix("m"),
              let minutes = Int(minutesPart.dropLast()) else {
            return nil
        }

        // Calculate total seconds
        let totalSeconds = (hours * 3600) + (minutes * 60)

        // For time ranges, we want to calculate forward from now to now + duration
        let end = now.addingTimeInterval(Double(totalSeconds))

        return DateRange(start: now, end: end)
    }

    /// Parse single unit format like "1h", "30m"
    private static func parseSingleUnit(_ input: String, relativeTo now: Date) -> DateRange? {
        // Parse number and unit
        guard let number = Int(String(input.dropLast())),
              let unit = input.last else {
            return nil
        }

        guard number > 0 else {
            return nil
        }

        let calendar = Calendar.current
        var components = DateComponents()

        switch unit {
        case "s":
            components.second = number
        case "m":
            components.minute = number
        case "h":
            components.hour = number
        case "d":
            components.day = number
        default:
            return nil
        }

        guard let end = calendar.date(byAdding: components, to: now) else {
            return nil
        }

        return DateRange(start: now, end: end)
    }

    static func parseRelative(_ input: String, relativeTo now: Date = Date()) -> DateRange? {
        // Handle combined time formats like "1h30m"
        if input.contains("h"), input.contains("m") {
            return parseCombinedFormat(input, relativeTo: now)
        }

        // Handle single unit formats like "1h", "30m"
        return parseSingleUnit(input, relativeTo: now)
    }
}
