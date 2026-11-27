import FirebaseCore
import FirebaseMessaging
import Foundation
import Observation
import UIKit

/// Port of src/notifications/push.ts (see docs/push-notifications.md and docs/push-server.md):
/// server push for new pinned events. This phone's FCM token is registered with the
/// commonvocab worker (provider "fcm", platform "ios"), which sends a push through Firebase
/// when a message is pinned.
@MainActor @Observable
final class PushNotifications {
    static let shared = PushNotifications()

    /// `userInfo["type"]` of a new-event push.
    nonisolated static let newPinnedType = "new-pinned"

    nonisolated struct Registration: Codable, Equatable, Sendable {
        let token: String
        let userId: String
    }

    private struct Saved: Codable {
        /// The "New pinned events" switch. On by default; nothing is sent without permission anyway.
        var enabled = true
        /// The Pinned tab's "Get notified" card was closed.
        var cardDismissed = false
        /// What the worker currently has for this phone, so it can be removed later.
        var registered: Registration?
    }

    private(set) var enabled: Bool
    private(set) var cardDismissed: Bool
    @ObservationIgnored private var registered: Registration?

    /// The signed-in user, as last told by the auth watcher. nil until it has run.
    @ObservationIgnored private var currentUserId: String??
    /// Syncs run one after another.
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var started = false

    private static let file = URL.documentsDirectory.appending(path: "push-settings.json")
    /// Where milestone 16 kept the switch before this file existed.
    private static let oldSwitchKey = "newPinnedEventsEnabled"

    private init() {
        var saved = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        if saved == nil {
            saved = Saved()
            if let old = UserDefaults.standard.object(forKey: Self.oldSwitchKey) as? Bool { saved?.enabled = old }
        }
        enabled = saved?.enabled ?? true
        cardDismissed = saved?.cardDismissed ?? false
        registered = saved?.registered
    }

    private func save() {
        let saved = Saved(enabled: enabled, cardDismissed: cardDismissed, registered: registered)
        do {
            try JSONEncoder().encode(saved).write(to: Self.file, options: .atomic)
        } catch {
            print("Could not save push settings:", error)
        }
    }

    // MARK: - Start-up

    /// Called once at launch, from the app delegate: sets up Firebase, listens for token
    /// changes, and asks Apple for this phone's push address (this never shows a prompt).
    func start() {
        guard !started else { return }
        started = true
        FirebaseApp.configure()
        Messaging.messaging().delegate = PushTokenListener.shared
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// From the app delegate. Until this arrives, Firebase can't make a token (the sync fails
    /// and is retried here).
    func apnsTokenReceived(_ deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
        sync()
    }

    // MARK: - Keeping the worker in line

    /// The signed-in user changed (nil: signed out): register, remove, or move the
    /// registration to the new account.
    func userChanged(_ userId: String?) {
        currentUserId = .some(userId)
        sync()
    }

    /// Makes the worker's registration for this phone match the switch, permission and the
    /// signed-in user. Failures are logged, and the next sync tries again.
    func sync() {
        guard let user = currentUserId else { return }   // The auth watcher hasn't run yet.
        let previous = queue
        queue = Task {
            await previous?.value
            do {
                try await syncNow(userId: user)
            } catch {
                print("Couldn't update push registration:", error)
            }
        }
    }

    private func syncNow(userId: String?) async throws {
        await NotificationPermission.shared.refresh()
        guard let userId, enabled, NotificationPermission.shared.granted else {
            if let old = registered {
                try await Self.deleteToken(old)
                registered = nil
                save()
                print("Push: unregistered this phone")
            }
            return
        }

        let token = try await Self.fcmToken()
        print("FCM token:", token)
        if registered == Registration(token: token, userId: userId) { return }
        // A new token, or another account on this phone: drop the old registration first.
        if let old = registered {
            try await Self.deleteToken(old)
            registered = nil
            save()
        }
        let next = Registration(token: token, userId: userId)
        try await Self.postToken(next)
        registered = next
        save()
        print("Push: registered this phone for new pinned events")
    }

    // MARK: - The switch and the card

    /// Asks for notification permission (if needed) and turns new-event pushes on. Returns
    /// `.blocked` when the iPhone won't ask again, so the caller can offer Settings.
    func turnOn() async -> NotificationPermission.Result {
        let result = await NotificationPermission.shared.askToTurnOn("hear about new events")
        guard result == .granted else { return result }
        enabled = true
        save()
        sync()
        Toast.show("You'll be notified about new events.")
        return result
    }

    /// The Settings switch turned off: this phone is unregistered from the worker.
    func turnOff() {
        enabled = false
        save()
        sync()
    }

    func dismissCard() {
        cardDismissed = true
        save()
    }

    // MARK: - Network (off the main thread)

    @concurrent
    private nonisolated static func fcmToken() async throws -> String {
        try await Messaging.messaging().token()
    }

    @concurrent
    private nonisolated static func postToken(_ registration: Registration) async throws {
        var request = URLRequest(url: API.commonvocabURL.appending(path: "push-tokens"))
        request.httpMethod = "POST"
        request.setValue(try APIAuth.commonvocabHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "user_id": registration.userId,
            "token": registration.token,
            "provider": "fcm",
            "platform": "ios",
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HTTPStatusError(what: "push registration", status: status) }
    }

    /// A registration the worker no longer has (404) counts as removed.
    @concurrent
    private nonisolated static func deleteToken(_ registration: Registration) async throws {
        let url = API.commonvocabURL.appending(path: "push-tokens").appending(queryItems: [
            URLQueryItem(name: "token", value: registration.token),
            URLQueryItem(name: "user_id", value: registration.userId),
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(try APIAuth.commonvocabHeader(), forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) || status == 404 else {
            throw HTTPStatusError(what: "push unregistration", status: status)
        }
    }
}

/// Firebase tells this when the FCM token is first known or changes. Not tied to the main
/// thread: Firebase may call it from its own queue, so a main-thread-only version would crash.
nonisolated final class PushTokenListener: NSObject, MessagingDelegate, Sendable {
    static let shared = PushTokenListener()

    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        Task { @MainActor in PushNotifications.shared.sync() }
    }
}
