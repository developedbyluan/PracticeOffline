import ClerkKit
import ClerkKitUI
import SwiftUI

/// Port of src/app/(tabs)/settings.tsx (see docs/settings-account.md): the Account section
/// (who's signed in, Clerk's profile screen, Sign out) and the notification settings.
struct SettingsScreen: View {
    var body: some View {
        NavigationStack {
            List {
                AccountSection()

                NotificationsSection()

                Section {
                    EventRemindersRow()
                    NewPinnedEventsRow()
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// Who's signed in, a way into Clerk's profile screen, and Sign out.
/// Signing out (here or inside Clerk's screen) clears `clerk.user`, so MainScreen swaps the
/// tabs for the sign-in screen by itself.
private struct AccountSection: View {
    @Environment(Clerk.self) private var clerk
    @State private var profileOpen = false
    @State private var confirmSignOut = false
    @State private var signingOut = false

    private var user: User? { clerk.user }
    private var email: String? { user?.primaryEmailAddress?.emailAddress }
    /// Like Clerk's fullName on Android: first and last name together.
    private var fullName: String? {
        let name = [user?.firstName, user?.lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    var body: some View {
        Section("Account") {
            Button { profileOpen = true } label: { profileRow }
                .disabled(user == nil)
                .accessibilityLabel(user == nil
                    ? "Loading account"
                    : ["Account", fullName ?? email ?? "Your account", fullName == nil ? nil : email]
                        .compactMap { $0 }.joined(separator: ", "))
                .accessibilityHint("Opens your account settings")

            Button(role: .destructive) { confirmSignOut = true } label: {
                Group {
                    if signingOut {
                        ProgressView().tint(.red)
                    } else {
                        Text("Sign out").fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.red)
            .disabled(signingOut)
        }
        // Clerk's profile screen slides up, like the player. Its own close button closes it.
        .sheet(isPresented: $profileOpen) {
            UserProfileView(isDismissible: true)
        }
        .alert("Sign out?", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) { Task { await signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded lessons stay on this phone.")
        }
    }

    private var profileRow: some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(user == nil ? "Loading…" : (fullName ?? email ?? "Your account"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if fullName != nil, let email {
                    Text(email)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }

    /// 40 pt round picture, or a grey circle while it loads or if there's none.
    private var avatar: some View {
        let placeholder = Circle().fill(Color(.systemGray4))
        return Group {
            if let url = user.flatMap({ URL(string: $0.imageUrl) }), !(user?.imageUrl.isEmpty ?? true) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    private func signOut() async {
        signingOut = true
        do {
            try await clerk.auth.signOut()
            // MainScreen now shows the sign-in screen, and this screen goes away.
        } catch {
            print("Couldn't sign out:", error)
            Toast.show("Couldn't sign out. Please try again.")
            signingOut = false
        }
    }
}

#Preview {
    SettingsScreen()
        .environment(Clerk.shared)
}
