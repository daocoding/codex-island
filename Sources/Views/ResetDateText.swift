import Foundation

enum ResetDateText {
    static func compact(_ resetAt: Date?, now: Date = Date()) -> String {
        guard let resetAt else { return "—" }
        guard resetAt > now else { return "0m" }

        if Calendar.current.isDate(resetAt, inSameDayAs: now) {
            let hour = Calendar.current.component(.hour, from: resetAt)
            let displayHour = hour % 12 == 0 ? 12 : hour % 12
            return "\(displayHour)\(hour < 12 ? "a" : "p")"
        }

        return formatted(resetAt, dateFormat: "M/d")
    }

    static func detailed(_ resetAt: Date) -> String {
        formatted(resetAt, dateFormat: "EEE M/d h:mm a")
    }

    private static func formatted(_ date: Date, dateFormat: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }
}
