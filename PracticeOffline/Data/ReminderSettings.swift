import Foundation
import Observation

// Port of src/data/reminderSettings.ts (see docs/practice-reminders.md): the daily practice
// reminder settings, saved on the phone for every account (like the text size).

nonisolated struct ReminderTime: Codable, Hashable, Sendable {
    var hour: Int
    var minute: Int

    var isValid: Bool { (0...23).contains(hour) && (0...59).contains(minute) }
    fileprivate var minutes: Int { hour * 60 + minute }

    /// Today at this time, e.g. for a time picker or formatting.
    var date: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
    }

    init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    init(_ date: Date) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        self.init(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    /// "8:00 PM" or "20:00", following the phone's 12/24-hour setting.
    var formatted: String { date.formatted(date: .omitted, time: .shortened) }
}

nonisolated struct ReminderSettings: Codable, Equatable, Sendable {
    var enabled = false
    /// Times chosen by the user, sorted and unique. Empty means "follow my habit".
    var fixedTimes: [ReminderTime] = []
    /// The last day a lesson was opened (local YYYY-MM-DD), and when the first one was opened that day.
    var lastUseDay: String?
    var firstOpenTime: ReminderTime?

    static let maxFixedTimes = 5
    /// Used in habit mode until the user has opened a lesson.
    static let defaultTime = ReminderTime(hour: 20, minute: 0)

    /// The times the reminders fire: the chosen times, otherwise the habit time, otherwise 20:00.
    var reminderTimes: [ReminderTime] {
        fixedTimes.isEmpty ? [firstOpenTime ?? Self.defaultTime] : fixedTimes
    }

    /// Sorted, without duplicates, at most `maxFixedTimes`.
    static func normalize(_ times: [ReminderTime]) -> [ReminderTime] {
        var seen = Set<Int>()
        return times.filter { $0.isValid && seen.insert($0.minutes).inserted }
            .sorted { $0.minutes < $1.minutes }
            .prefix(maxFixedTimes)
            .map { $0 }
    }

    // Lenient reading: a broken field falls back to its default instead of losing the rest.
    private enum CodingKeys: String, CodingKey { case enabled, fixedTimes, lastUseDay, firstOpenTime }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        fixedTimes = Self.normalize((try? c.decode([ReminderTime].self, forKey: .fixedTimes)) ?? [])
        lastUseDay = try? c.decode(String.self, forKey: .lastUseDay)
        firstOpenTime = (try? c.decode(ReminderTime.self, forKey: .firstOpenTime)).flatMap { $0.isValid ? $0 : nil }
    }
}

/// The saved settings, shared by Settings and the player. Every change is saved to
/// <documents>/reminder-settings.json and reschedules the reminders.
@MainActor @Observable
final class ReminderSettingsStore {
    static let shared = ReminderSettingsStore()

    private(set) var settings: ReminderSettings

    private static let file = URL.documentsDirectory.appending(path: "reminder-settings.json")

    /// A missing or broken file means the defaults: reminders off, no times.
    private init() {
        settings = (try? Data(contentsOf: Self.file))
            .flatMap { try? JSONDecoder().decode(ReminderSettings.self, from: $0) } ?? ReminderSettings()
    }

    /// Saves the change and reschedules the reminders.
    func update(_ change: (inout ReminderSettings) -> Void) {
        var next = settings
        change(&next)
        next.fixedTimes = ReminderSettings.normalize(next.fixedTimes)
        guard next != settings else { return }
        save(next)
        PracticeReminders.shared.sync()
    }

    /// Called when a playable lesson opens. The first lesson of a new day sets the habit
    /// time; later ones that day don't change it. Reschedules only when the reminder
    /// follows the habit.
    func recordLessonOpened(at now: Date = .now) {
        let today = PlayTimeStore.localDate(now)
        guard settings.lastUseDay != today else { return }
        var next = settings
        next.lastUseDay = today
        next.firstOpenTime = ReminderTime(now)
        save(next)
        if next.enabled, next.fixedTimes.isEmpty { PracticeReminders.shared.sync() }
    }

    private func save(_ next: ReminderSettings) {
        settings = next
        do {
            try JSONEncoder().encode(next).write(to: Self.file, options: .atomic)
        } catch {
            print("Could not save reminder settings:", error)
        }
    }
}
