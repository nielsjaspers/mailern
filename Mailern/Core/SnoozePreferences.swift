import Foundation
import Observation

struct SnoozeSettings: Codable, Equatable {
    var shortDelayMinutes = 60
    var longDelayMinutes = 180
    var eveningMinutes = 18 * 60
    var tomorrowMinutes = 9 * 60
    // Calendar weekday numbering: Sunday = 1, Monday = 2.
    var nextWeekday = 2
    var nextWeekMinutes = 9 * 60

    var isValid: Bool {
        (15...1440).contains(shortDelayMinutes) && (15...1440).contains(longDelayMinutes)
            && (0..<1440).contains(eveningMinutes) && (0..<1440).contains(tomorrowMinutes)
            && (1...7).contains(nextWeekday) && (0..<1440).contains(nextWeekMinutes)
    }

    func options(now: Date, calendar: Calendar = .current) -> [SnoozeOption] {
        func time(_ minutes: Int, on day: Date) -> Date? {
            calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
        }
        var result = [
            SnoozeOption(id: .shortDelay, title: Self.delayTitle(shortDelayMinutes), date: now.addingTimeInterval(Double(shortDelayMinutes) * 60)),
            SnoozeOption(id: .longDelay, title: Self.delayTitle(longDelayMinutes), date: now.addingTimeInterval(Double(longDelayMinutes) * 60))
        ]
        if let evening = time(eveningMinutes, on: now), evening > now {
            result.append(SnoozeOption(id: .evening, title: "This evening", date: evening))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           let date = time(tomorrowMinutes, on: tomorrow) {
            result.append(SnoozeOption(id: .tomorrow, title: "Tomorrow", date: date))
        }
        let weekday = calendar.component(.weekday, from: now)
        let daysToMonday = (9 - weekday) % 7
        // Next week starts on Monday regardless of the device's locale or week settings.
        if let monday = calendar.date(byAdding: .day, value: daysToMonday == 0 ? 7 : daysToMonday, to: calendar.startOfDay(for: now)),
           let day = calendar.date(byAdding: .day, value: (nextWeekday + 5) % 7, to: monday),
           let date = time(nextWeekMinutes, on: day) {
            result.append(SnoozeOption(id: .nextWeek, title: "Next week", date: date))
        }
        return result.filter { $0.date > now }.sorted {
            $0.date == $1.date ? $0.id.rawValue < $1.id.rawValue : $0.date < $1.date
        }
    }

    // Time-only controls use UTC reference dates so DST cannot alter the saved clock time.
    // Actual snooze dates above are still resolved in the user's local calendar.
    static func clockDate(minutes: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(minutes) * 60)
    }

    static func clockMinutes(date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func delayTitle(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "In \(remainder) minutes" }
        let hourText = "\(hours) \(hours == 1 ? "hour" : "hours")"
        return remainder == 0 ? "In \(hourText)" : "In \(hourText) \(remainder) minutes"
    }
}

struct SnoozeOption: Identifiable {
    enum ID: Int { case shortDelay, longDelay, evening, tomorrow, nextWeek }
    var id: ID
    var title: String
    var date: Date
}

@MainActor @Observable
final class SnoozePreferences {
    var settings: SnoozeSettings {
        didSet {
            guard settings.isValid, let data = try? JSONEncoder().encode(settings) else { return }
            defaults.set(data, forKey: Self.key)
        }
    }
    private let defaults: UserDefaults
    private static let key = "snoozeSettings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(SnoozeSettings.self, from: data), saved.isValid {
            settings = saved
        } else { settings = SnoozeSettings() }
    }
}
