import SwiftUI

/// Port of NotificationsSection and PracticeGroup in src/app/(tabs)/settings.tsx (see
/// docs/settings-notifications.md and docs/practice-reminders.md): the "Notifications are
/// off" notice and the daily practice reminder (EventRemindersRow is below). A switch is on only when its notifications
/// can actually arrive: turned on here and allowed by the iPhone.
struct NotificationsSection: View {
    @State private var permission = NotificationPermission.shared
    @State private var store = ReminderSettingsStore.shared
    @Environment(\.openURL) private var openURL
    @State private var asking = false
    /// Notifications were refused before: offer the iPhone's Settings.
    @State private var offerSettings = false

    /// Before the first check, assume allowed so the switch doesn't flicker off.
    private var granted: Bool { permission.status == nil || permission.granted }
    private var settings: ReminderSettings { store.settings }
    /// What the user sees: on only when reminders can actually arrive.
    private var enabled: Bool { settings.enabled && granted }
    private var choosingTimes: Bool { !settings.fixedTimes.isEmpty }

    var body: some View {
        Section {
            if permission.status != nil, !permission.granted {
                notice
            }

            Toggle("Practice reminder", isOn: Binding(
                get: { enabled },
                set: { on in Task { await toggleReminder(on) } }
            ))
            .disabled(asking)

            if enabled {
                Toggle("Choose times", isOn: Binding(
                    get: { choosingTimes },
                    // The list starts with the time the reminder uses now.
                    set: { on in store.update { $0.fixedTimes = on ? $0.reminderTimes : [] } }
                ))

                ForEach(Array(settings.fixedTimes.enumerated()), id: \.element) { index, time in
                    timeRow(index: index, time: time)
                }

                if choosingTimes, settings.fixedTimes.count < ReminderSettings.maxFixedTimes {
                    Button(action: addTime) {
                        Label("Add a time", systemImage: "plus")
                    }
                }
            }
        } header: {
            Text("Notifications")
        } footer: {
            if enabled { Text(footnote) }
        }
        .alert("Notifications are off for this app", isPresented: $offerSettings) {
            Button("Open Settings") { openSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To get reminders, allow notifications in your iPhone's Settings.")
        }
    }

    /// Shown while the iPhone doesn't allow this app's notifications.
    private var notice: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications are off for this app")
                    .font(.subheadline.weight(.semibold))
                Text("Practice reminders, event reminders and new events can't reach you.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(permission.canAskAgain ? "Turn on" : "Open Settings") {
                Task { await turnOnFromNotice() }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(asking)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
    }

    /// A chosen time: tap it to change it, ✕ to remove it.
    private func timeRow(index: Int, time: ReminderTime) -> some View {
        HStack {
            DatePicker(
                "Reminder \(index + 1)",
                selection: Binding(get: { time.date }, set: { change(index: index, to: ReminderTime($0)) }),
                displayedComponents: .hourAndMinute
            )
            Button {
                // Removing the last time switches back to following the habit.
                store.update { $0.fixedTimes.remove(at: index) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .tint(Color(.systemGray2))
            .accessibilityLabel("Remove \(time.formatted)")
        }
    }

    private var footnote: String {
        let count = settings.fixedTimes.count
        if choosingTimes {
            return count >= ReminderSettings.maxFixedTimes
                ? "Up to \(ReminderSettings.maxFixedTimes) reminders a day."
                : "You'll get a reminder every day at these times."
        }
        if let first = settings.firstOpenTime {
            return "Reminds you at \(first.formatted), the time you started a lesson on your last practice day."
        }
        return "Reminds you at \(ReminderSettings.defaultTime.formatted) until you start your first lesson."
    }

    // MARK: - Actions

    private func toggleReminder(_ on: Bool) async {
        guard on else {
            store.update { $0.enabled = false }
            return
        }
        asking = true
        defer { asking = false }
        switch await permission.askToTurnOn("get reminders") {
        case .granted: store.update { $0.enabled = true }
        case .blocked: offerSettings = true
        case .denied: break
        }
    }

    private func turnOnFromNotice() async {
        guard permission.canAskAgain else {
            openSettings()
            return
        }
        asking = true
        defer { asking = false }
        do {
            _ = try await permission.request()
        } catch {
            print("Couldn't ask for notification permission:", error)
            Toast.show("Couldn't turn on notifications. Please try again.")
        }
    }

    private func change(index: Int, to picked: ReminderTime) {
        let times = settings.fixedTimes
        guard times.indices.contains(index), times[index] != picked else { return }
        if times.contains(picked) {
            Toast.show("You already have a reminder at \(picked.formatted).")
            return
        }
        store.update { $0.fixedTimes[index] = picked }
    }

    /// Adds the next free hour after the last time; tap it to change it.
    private func addTime() {
        let times = settings.fixedTimes
        let last = times.last ?? ReminderSettings.defaultTime
        let free = (1...24).lazy
            .map { ReminderTime(hour: (last.hour + $0) % 24, minute: last.minute) }
            .first { !times.contains($0) }
        guard let free else { return }
        store.update { $0.fixedTimes.append(free) }
    }

    /// This app's page in the iPhone's Settings, where notifications can be allowed.
    private func openSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            openURL(url)
        }
    }
}

/// Port of the "Event reminders" switch in EventsGroup (settings.tsx): reminders 30 minutes
/// before events you said "I'll be there!" to. Shows on only while notifications are allowed.
struct EventRemindersRow: View {
    @State private var permission = NotificationPermission.shared
    @State private var reminders = EventReminders.shared
    @Environment(\.openURL) private var openURL
    @State private var asking = false
    @State private var offerSettings = false

    /// Before the first check, assume allowed so the switch doesn't flicker off.
    private var granted: Bool { permission.status == nil || permission.granted }

    var body: some View {
        Toggle(isOn: Binding(
            get: { reminders.enabled && granted },
            set: { on in Task { await toggle(on) } }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Event reminders")
                Text("30 minutes before events you're going to")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(asking)
        .alert("Notifications are off for this app", isPresented: $offerSettings) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To get event reminders, allow notifications in your iPhone's Settings.")
        }
    }

    private func toggle(_ on: Bool) async {
        guard on else {
            reminders.setEnabled(false)
            return
        }
        asking = true
        defer { asking = false }
        switch await permission.askToTurnOn("get event reminders") {
        case .granted: reminders.setEnabled(true)
        case .blocked: offerSettings = true
        case .denied: break
        }
    }
}
