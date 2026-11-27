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
