import Foundation
import UserNotifications

/// Port of src/notifications/reminders.ts (see docs/practice-reminders.md): daily practice
/// reminders, scheduled on the phone (no server push), so they work offline.
@MainActor
final class PracticeReminders {
    static let shared = PracticeReminders()

    /// Each reminder's id is "daily-practice-<index>".
    private nonisolated static let prefix = "daily-practice"

    /// Reschedules run one after another, so a cancel never interleaves with a schedule.
    private var queue: Task<Void, Never>?
    private var started = false

    private init() {}

    /// Called once at startup: banners for reminders that arrive while the app is open, the
    /// first permission check, and one sync in case permission or the app changed.
    func start() {
        guard !started else { return }
        started = true
        UNUserNotificationCenter.current().delegate = ForegroundNotifications.shared
        Task {
            await NotificationPermission.shared.refresh()
            sync()
        }
    }

    /// Makes the scheduled reminders match the settings. Never fails; errors are logged.
    func sync() {
        let previous = queue
        let settings = ReminderSettingsStore.shared.settings
        queue = Task {
            await previous?.value
            await Self.reschedule(settings)
        }
    }

    @concurrent
    private nonisolated static func reschedule(_ settings: ReminderSettings) async {
        let center = UNUserNotificationCenter.current()
        // Cancel every reminder first, so a removed time never keeps firing.
        let ids = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)

        guard settings.enabled else { return }
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }

        for (index, time) in settings.reminderTimes.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "Time to practice!"
            content.body = "Open the app and listen today."
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: DateComponents(hour: time.hour, minute: time.minute), repeats: true)
            let request = UNNotificationRequest(identifier: "\(prefix)-\(index)", content: content, trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                print("Couldn't schedule practice reminder \(index):", error)
            }
        }
    }
}

/// Shows notifications that arrive while the app is open as a banner, with sound. Tapping
/// one simply opens the app. Not tied to the main thread: the system calls it on its own
/// queue, so a main-thread-only version would crash.
nonisolated final class ForegroundNotifications: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = ForegroundNotifications()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
