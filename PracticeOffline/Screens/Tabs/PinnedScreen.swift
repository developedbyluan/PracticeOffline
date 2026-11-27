import ClerkKit
import SwiftUI

/// Port of src/app/(tabs)/pinned.tsx: the signed-in user's pinned messages, loaded fresh
/// each time the tab is opened, with pull to refresh, and the "I'll be there!" replies.
/// Online only. Also keeps the event reminders in line with the replies, and offers
/// new-event notifications with the "Get notified" card.
struct PinnedScreen: View {
    @Environment(Clerk.self) private var clerk

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Pinned")
        }
    }

    @ViewBuilder private var content: some View {
        if !clerk.isLoaded {
            ProgressView()
        } else if let userId = clerk.user?.id {
            PinnedList(userId: userId)
                // A different user starts from scratch.
                .id(userId)
        } else {
            Text("Sign in to see pinned messages.")
                .foregroundStyle(.secondary)
        }
    }
}

struct PinnedList: View {
    let userId: String
    var baseURL: URL = API.commonvocabURL

    /// `messages` is nil when nothing has loaded yet for this user. `problem` says why the
    /// latest load failed; an earlier list stays on screen under it.
    private struct LoadState {
        var messages: [PinnedMessage]?
        var problem: LoadProblem?
        var loadedAt: Date
    }

    private static let offlineToast = "You're offline. Try again when you're connected."

    @State private var state: LoadState?
    @State private var loadTask: Task<[PinnedMessage]?, Never>?
    @State private var isRetrying = false
    /// The user's membership role, which decides who gets the "I'll be there!" button.
    /// Kept from the last successful lookup; nil while unknown.
    @State private var role: String?
    /// The user's own "I'll be there!" state, set right after a send or remove so the
    /// button changes at once. Dropped when a reload from the server agrees.
    @State private var overrides: [Int: Bool] = [:]
    /// Messages with a reply request running: their button shows a spinner and ignores taps.
    @State private var busyIds: Set<Int> = []

    var body: some View {
        Group {
            if let state {
                list(state)
            } else {
                ProgressView()
            }
        }
        // Reload whenever the tab comes into view.
        .onAppear { Task { await reload() } }
        .onDisappear { loadTask?.cancel() }
        // An event reminder was tapped while this tab was already showing.
        .onChange(of: AppNavigation.shared.pinnedRequests) { Task { await reload() } }
        // A new-event push arrived while the app is open.
        .onChange(of: AppNavigation.shared.newPinnedArrivals) { Task { await reload() } }
    }

    private func list(_ state: LoadState) -> some View {
        let visible = state.messages.map { visiblePinned($0, now: state.loadedAt) } ?? []
        return GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    PushPromptCard()
                    if let problem = state.problem {
                        problemBox(problem, showRetry: state.messages == nil)
                    }
                    if state.messages != nil, visible.isEmpty {
                        Text("No pinned messages right now.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    ForEach(visible) { message in
                        let replied = isReplied(message)
                        PinnedCard(
                            message: message,
                            now: state.loadedAt,
                            replied: replied,
                            busy: busyIds.contains(message.id),
                            onToggleReply: { Task { await toggleReply(message, replied: replied) } },
                            joinable: canJoin(message, role: role),
                            roleKnown: role != nil
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
                // With no cards, the message sits in the middle of the screen.
                .frame(maxWidth: .infinity, minHeight: visible.isEmpty ? geometry.size.height : nil)
            }
            .refreshable { await reload() }
        }
    }

    /// Why the list couldn't load. With nothing to show, it has a Try again button too.
    private func problemBox(_ problem: LoadProblem, showRetry: Bool) -> some View {
        VStack(spacing: 12) {
            Text(problem == .offline
                 ? "You're offline. Pull down to try again."
                 : "Couldn't load pinned messages. Pull down to try again.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
            if showRetry {
                Button {
                    Task {
                        isRetrying = true
                        await reload()
                        isRetrying = false
                    }
                } label: {
                    Group {
                        if isRetrying { ProgressView() } else { Text("Try again") }
                    }
                    .frame(minWidth: 116)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRetrying)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func isReplied(_ message: PinnedMessage) -> Bool {
        overrides[message.id] ?? !attendingReplyIds(message, userId: userId).isEmpty
    }

    // MARK: - Loading

    /// Starts a fresh load, replacing any load still running, and waits for it. Returns the
    /// fresh list, or nil if it failed or a newer load replaced it.
    @discardableResult
    private func reload() async -> [PinnedMessage]? {
        loadTask?.cancel()
        let task = Task { await load() }
        loadTask = task
        return await task.value
    }

    private func load() async -> [PinnedMessage]? {
        // The role is looked up alongside; only the list decides success or failure.
        async let freshRole = lookUpRole()
        do {
            let messages = try await fetchPinnedMessages(userId: userId, baseURL: baseURL)
            let role = await freshRole
            guard !Task.isCancelled else { return nil }
            state = LoadState(messages: messages, problem: nil, loadedAt: .now)
            if let role { self.role = role }
            // Reminders 30 minutes before the events this user is going to and may join.
            // Skipped while the role is unknown, so a failed lookup never cancels them.
            if let known = self.role {
                EventReminders.shared.sync(
                    userId: userId,
                    events: attendingEvents(messages.filter { canJoin($0, role: known) }, userId: userId))
            }
            // Forget local states the server now agrees with.
            for message in messages {
                let onServer = !attendingReplyIds(message, userId: userId).isEmpty
                if overrides[message.id] == onServer { overrides[message.id] = nil }
            }
            return messages
        } catch {
            _ = await freshRole
            // Replaced by a newer load, or the tab closed: not a failure.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
            print("Couldn't load pinned messages:", error)
            let problem: LoadProblem = isOfflineError(error) ? .offline : .failed
            // Keep the list from an earlier load, with the message on top.
            if var previous = state, previous.messages != nil {
                previous.problem = problem
                state = previous
            } else {
                state = LoadState(messages: nil, problem: problem, loadedAt: .now)
            }
            return nil
        }
    }

    /// nil when the lookup fails; the role from an earlier lookup is then kept.
    private func lookUpRole() async -> String? {
        do {
            return try await fetchUserRole(userId: userId, baseURL: baseURL)
        } catch {
            if !Task.isCancelled { print("Couldn't load the user's role:", error) }
            return nil
        }
    }

    // MARK: - Replying

    /// Sends "I'll be there!", or removes the user's "I'll be there!" replies (only those).
    private func toggleReply(_ message: PinnedMessage, replied: Bool) async {
        // Checked before any waiting, so a fast double tap can't start two requests.
        guard !busyIds.contains(message.id), canJoin(message, role: role) else { return }
        busyIds.insert(message.id)
        defer { busyIds.remove(message.id) }

        if !replied {
            do {
                try await sendReply(messageId: message.id, userId: userId, body: attendingReply, baseURL: baseURL)
            } catch {
                print("Couldn't send the reply:", error)
                Toast.show(isOfflineError(error) ? Self.offlineToast : "Couldn't send your reply. Try again.")
                return
            }
            overrides[message.id] = true
            // May ask for notification permission the first time.
            let reminder = await EventReminders.shared.remindAfterReply(userId: userId, event: eventFor(message))
            Toast.show(reminder == .noPermission
                       ? "Reply sent. Turn on notifications to get a reminder."
                       : "Reply sent")
            // Quietly, to get the new reply's id, which a later remove needs.
            Task { await reload() }
            return
        }

        // A reply sent moments ago has no id yet: reload to get it.
        var ids = attendingReplyIds(message, userId: userId)
        if ids.isEmpty {
            let fresh = await reload() ?? state?.messages ?? []
            ids = fresh.first { $0.id == message.id }.map { attendingReplyIds($0, userId: userId) } ?? []
        }
        if ids.isEmpty {
            Toast.show("Couldn't remove your reply. Try again.")
            return
        }

        // Every "I'll be there!" by this user goes, so accidental duplicates go too.
        let userId = userId, baseURL = baseURL
        let failure: (any Error)? = await withTaskGroup(of: (any Error)?.self) { group in
            for id in ids {
                group.addTask {
                    do {
                        try await deleteReply(replyId: id, userId: userId, baseURL: baseURL)
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var first: (any Error)?
            for await error in group where first == nil { first = error }
            return first
        }
        if let failure {
            print("Couldn't remove the reply:", failure)
            Toast.show(isOfflineError(failure) ? Self.offlineToast : "Couldn't remove your reply. Try again.")
        } else {
            overrides[message.id] = false
            EventReminders.shared.cancel(messageId: message.id)
            Toast.show("Reply removed")
        }
        // Shows what's left, even after a partial remove.
        Task { await reload() }
    }
}
