import Foundation
import Observation
import UserNotifications

/// A pinned event the user said "I'll be there!" to.
nonisolated struct AttendingEvent: Sendable, Equatable {
    let messageId: Int
    let title: String
    /// Unix seconds.
    let start: Double
}

/// The events in a list that this user is going to.
nonisolated func attendingEvents(_ messages: [PinnedMessage], userId: String) -> [AttendingEvent] {
    messages.compactMap { message in
        message.pinnedRange != nil && !attendingReplyIds(message, userId: userId).isEmpty
            ? eventFor(message) : nil
    }
}

nonisolated func eventFor(_ message: PinnedMessage) -> AttendingEvent {
    AttendingEvent(messageId: message.id, title: messageTitle(message.body),
                   start: message.pinnedRange?.start ?? 0)
}

/// Port of src/notifications/eventReminders.ts (see docs/event-reminders.md): a reminder
/// 30 minutes before each pinned event the user said "I'll be there!" to. Scheduled on
/// the phone (no server push).
@MainActor @Observable
final class EventReminders {
    static let shared = EventReminders()

    enum ReplyResult { case scheduled, noPermission, off }

    /// `userInfo["type"]` of a reminder; tapping it opens the Pinned tab.
    nonisolated static let notificationType = "event-reminder"
    /// Each reminder's id is "event-reminder-<messageId>".
    private nonisolated static let prefix = "event-reminder-"
    private nonisolated static let leadSeconds: Double = 30 * 60
    private static let enabledKey = "eventRemindersEnabled"

    /// The "Event reminders" switch in Settings, saved on the phone. On by default.
    private(set) var enabled: Bool

    /// The last list synced, so the reminders can be rebuilt when the switch or permission
    /// turns on without waiting for the next Pinned load.
    @ObservationIgnored private var lastSync: (userId: String, events: [AttendingEvent])?
    /// Changes run one after another, so a cancel never interleaves with a schedule.
    @ObservationIgnored private var queue: Task<Void, Never>?

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Off cancels every event reminder; on schedules them again from the last Pinned list.
    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        resync()
    }

    /// Makes the scheduled reminders match the events this user is going to: adds new ones,
    /// moves changed times, and cancels the rest (including other accounts'). Never asks for
    /// permission; without it, nothing is scheduled.
    func sync(userId: String, events: [AttendingEvent]) {
        lastSync = (userId, events)
        let enabled = enabled
        enqueue { await Self.reconcile(userId: userId, events: events, enabled: enabled) }
    }

    /// Replays the last sync (switch or permission turned on). With none yet and the switch
    /// off, cancels everything.
    func resync() {
        if let lastSync {
            sync(userId: lastSync.userId, events: lastSync.events)
        } else if !enabled {
            cancelOtherUsers(nil)
        }
    }

    /// Right after the user says "I'll be there!": asks for notification permission if it
    /// hasn't been decided yet, then schedules the reminder. Nothing while the switch is off.
    func remindAfterReply(userId: String, event: AttendingEvent) async -> ReplyResult {
        guard enabled else { return .off }
        let permission = NotificationPermission.shared
        if !permission.granted {
            // Only shows the iPhone's question if it was never answered.
            guard (try? await permission.request()) == .granted else { return .noPermission }
        }
        await enqueue { await Self.schedule(userId: userId, event: event) }.value
        return .scheduled
    }

    /// Right after the user removes their reply.
    func cancel(messageId: Int) {
        enqueue { Self.center.removePendingNotificationRequests(withIdentifiers: ["\(Self.prefix)\(messageId)"]) }
    }

    /// Cancels every reminder that isn't this user's (all of them when signed out).
    func cancelOtherUsers(_ userId: String?) {
        if userId == nil || lastSync?.userId != userId { lastSync = nil }
        enqueue {
            let ids = await Self.scheduled()
                .filter { userId == nil || $0.content.userInfo["userId"] as? String != userId }
                .map(\.identifier)
            Self.center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    @discardableResult
    private func enqueue(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = queue
        let task = Task {
            await previous?.value
            await work()
        }
        queue = task
        return task
    }

    // MARK: - Off the main thread (UserNotifications calls back on its own queue)

    private nonisolated static var center: UNUserNotificationCenter { .current() }

    @concurrent
    private nonisolated static func scheduled() async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(prefix) }
    }

    @concurrent
    private nonisolated static func allowed() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    private nonisolated static func fireDate(_ event: AttendingEvent) -> Date {
        Date(timeIntervalSince1970: event.start - leadSeconds)
    }

    @concurrent
    private nonisolated static func reconcile(userId: String, events: [AttendingEvent], enabled: Bool) async {
        let existing = await scheduled()
        guard enabled, await allowed() else {
            center.removePendingNotificationRequests(withIdentifiers: existing.map(\.identifier))
            return
        }
        var wanted = Dictionary(
            events.filter { fireDate($0) > .now }.map { ("\(prefix)\($0.messageId)", $0) },
            uniquingKeysWith: { first, _ in first })
        var stale: [String] = []
        for request in existing {
            let info = request.content.userInfo
            if let event = wanted[request.identifier],
               info["userId"] as? String == userId,
               info["startsAt"] as? Double == event.start,
               request.content.title == event.title {
                wanted[request.identifier] = nil   // Already scheduled as it should be.
            } else {
                stale.append(request.identifier)
            }
        }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        for event in wanted.values { await schedule(userId: userId, event: event) }
    }

    /// Schedules (or replaces) one reminder. Nothing once its time has passed, e.g. for an
    /// event starting in less than 30 minutes.
    @concurrent
    private nonisolated static func schedule(userId: String, event: AttendingEvent) async {
        let id = "\(prefix)\(event.messageId)"
        center.removePendingNotificationRequests(withIdentifiers: [id])
        let date = fireDate(event)
        guard date > .now, await allowed() else { return }

        let start = Date(timeIntervalSince1970: event.start).formatted(date: .omitted, time: .shortened)
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = "Starts at \(start). You said you'll be there."
        content.sound = .default
        content.userInfo = ["type": notificationType, "messageId": event.messageId,
                            "userId": userId, "startsAt": event.start]
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        } catch {
            print("Couldn't schedule the event reminder:", error)
        }
    }
}
