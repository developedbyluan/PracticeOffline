import SwiftUI

/// Port of src/components/PushPromptCard.tsx: on the Pinned tab, offers new-event
/// notifications until they're on or the card is closed. Shown only while the "New pinned
/// events" switch is on but the iPhone hasn't allowed notifications.
struct PushPromptCard: View {
    @State private var push = PushNotifications.shared
    @State private var permission = NotificationPermission.shared
    @Environment(\.openURL) private var openURL
    @State private var asking = false
    /// Notifications were refused before: offer the iPhone's Settings.
    @State private var offerSettings = false

    var body: some View {
        if push.enabled, !push.cardDismissed, permission.status != nil, !permission.granted {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Get notified about new events")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Button { push.dismissCard() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            Text("We'll let you know when a new event is pinned.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                Task {
                    asking = true
                    if await push.turnOn() == .blocked { offerSettings = true }
                    asking = false
                }
            } label: {
                Group {
                    if asking { ProgressView().tint(.white) } else { Text("Turn on").fontWeight(.semibold) }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(.white)
                .background(Color.blue, in: .rect(cornerRadius: 12))
                .contentShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(asking)
            .padding(.top, 8)
        }
        .padding(16)
        .background(Color.blue.opacity(0.1), in: .rect(cornerRadius: 14))
        .alert("Notifications are off for this app", isPresented: $offerSettings) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To hear about new events, allow notifications in your iPhone's Settings.")
        }
    }
}
