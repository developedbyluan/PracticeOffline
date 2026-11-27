import Foundation
import Observation
import UserNotifications

/// Port of src/notifications/permission.ts (see docs/settings-notifications.md): the app's
/// notification permission, shared by every screen that shows a notification setting, so
/// a switch is "on" only when its notifications can actually arrive.
@MainActor @Observable
final class NotificationPermission {
    static let shared = NotificationPermission()

    enum Result { case granted, denied, blocked }

    /// nil until the first check.
    private(set) var status: UNAuthorizationStatus?

    var granted: Bool { status.map(Self.allows) ?? false }
    /// iPhone asks only once; after that, only the phone's Settings can change it.
    var canAskAgain: Bool { status == .notDetermined }

    private init() {}

    private static func allows(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    /// Checks the current permission. Runs at startup and whenever the app comes back to
    /// the front (it may have been changed in the iPhone's Settings). When it goes from
    /// not allowed to allowed, the reminders are set up again.
    func refresh() async {
        let next = await Self.currentStatus()
        let wasGranted = granted
        let firstCheck = status == nil
        status = next
        if !firstCheck, !wasGranted, granted {
            PracticeReminders.shared.sync()
            EventReminders.shared.resync()
        }
    }

    /// Asks the system if it still can. `.denied`: refused at the prompt just now.
    /// `.blocked`: refused earlier, and the iPhone won't ask again, so the user has to allow
    /// notifications in Settings.
    func request() async throws -> Result {
        let before = await Self.currentStatus()
        if before == .notDetermined {
            _ = try await Self.requestAuthorization()
        }
        await refresh()
        if granted { return .granted }
        return before == .notDetermined ? .denied : .blocked
    }

    /// The "turn something on" flow: asks for permission. `purpose` finishes the sentence,
    /// e.g. "get reminders". A refusal shows a message; `.blocked` means the caller should
    /// offer the iPhone's Settings.
    func askToTurnOn(_ purpose: String) async -> Result {
        do {
            let result = try await request()
            if result == .denied { Toast.show("Allow notifications to \(purpose).") }
            return result
        } catch {
            print("Couldn't ask for notification permission:", error)
            Toast.show("Couldn't turn on notifications. Please try again.")
            return .denied
        }
    }

    // Off the main thread: UserNotifications calls back on its own queue.

    @concurrent
    private nonisolated static func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @concurrent
    private nonisolated static func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
}
