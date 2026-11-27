import ClerkKit
import ClerkKitUI
import SwiftUI

/// Port of src/app/index.tsx.
/// Loading → spinner. Signed in → the tabs. Signed out → a "Sign In" button
/// that opens Clerk's sign-in sheet.
struct MainScreen: View {
    @Environment(Clerk.self) private var clerk
    @State private var isAuthOpen = false

    var body: some View {
        content
            // Notifications belong to the signed-in user: signing out cancels every event
            // reminder and unregisters from new-event pushes; switching accounts cancels the
            // previous account's reminders and moves the push registration.
            .task(id: clerk.isLoaded ? (clerk.user?.id ?? "signed-out") : nil) {
                guard clerk.isLoaded else { return }
                let userId = clerk.user?.id
                EventReminders.shared.cancelOtherUsers(userId)
                // Register for new-event pushes, remove the registration, or move it.
                PushNotifications.shared.userChanged(userId)
                // The next sign-in starts on Home, like the Android app.
                if userId == nil { AppNavigation.shared.tab = .home }
            }
    }

    @ViewBuilder private var content: some View {
        if !clerk.isLoaded {
            ProgressView()
                .controlSize(.large)
        } else if clerk.user != nil {
            // `user` is set for pending sessions too, like treatPendingAsSignedOut: false.
            TabsLayout()
        } else {
            Button("Sign In") { isAuthOpen = true }
                .sheet(isPresented: $isAuthOpen) {
                    // Closes itself once sign-in finishes.
                    AuthView()
                }
        }
    }
}
