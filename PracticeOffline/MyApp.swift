import ClerkKit
import SwiftUI

/// Port of src/app/_layout.tsx: sets up Clerk and shows the start screen.
/// (Notifications, toasts, the player and account sheets come in later milestones.)
@main struct MyApp: App {
    /// Keeps the app in portrait except fullscreen video (see OrientationLock).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Read from Info.plist, which gets it from Secrets.xcconfig.
    private let publishableKey: String
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "ClerkPublishableKey") as? String ?? ""
        publishableKey = key.trimmingCharacters(in: .whitespaces)
        if !publishableKey.isEmpty {
            Clerk.configure(publishableKey: publishableKey)
        }
        // Opens the listening-time store, which closes sessions left open by a crash.
        _ = PlayTimeStore.shared
        // Daily practice reminders: first permission check and reschedule.
        PracticeReminders.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            if publishableKey.isEmpty {
                // Same idea as the Expo app's "Add your clerk publishable key" error,
                // but shown on screen instead of crashing.
                ContentUnavailableView(
                    "Clerk key missing",
                    systemImage: "key",
                    description: Text("Add CLERK_PUBLISHABLE_KEY to Secrets.xcconfig, then build again.")
                )
            } else {
                MainScreen()
                    .environment(Clerk.shared)
                    // Notification permission may have been changed in the iPhone's Settings.
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            Task { await NotificationPermission.shared.refresh() }
                            // Only sends a request when something changed.
                            PushNotifications.shared.sync()
                        }
                    }
            }
        }
    }
}
