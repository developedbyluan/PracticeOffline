import ClerkKit
import SwiftUI

/// Port of the list in src/app/(tabs)/pinned.tsx: the signed-in user's pinned messages,
/// loaded fresh each time the tab is opened, with pull to refresh. Online only.
/// Not yet ported: the "Get notified" card (comes with push) and "I'll be there!".
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

    @State private var state: LoadState?
    @State private var loadTask: Task<Void, Never>?
    @State private var isRetrying = false

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
    }

    private func list(_ state: LoadState) -> some View {
        let visible = state.messages.map { visiblePinned($0, now: state.loadedAt) } ?? []
        return GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    if let problem = state.problem {
                        problemBox(problem, showRetry: state.messages == nil)
                    }
                    if state.messages != nil, visible.isEmpty {
                        Text("No pinned messages right now.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    ForEach(visible) { message in
                        PinnedCard(message: message, now: state.loadedAt)
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

    /// Starts a fresh load, replacing any load still running, and waits for it.
    private func reload() async {
        loadTask?.cancel()
        let task = Task { await load() }
        loadTask = task
        await task.value
    }

    private func load() async {
        do {
            let messages = try await fetchPinnedMessages(userId: userId, baseURL: baseURL)
            guard !Task.isCancelled else { return }
            state = LoadState(messages: messages, problem: nil, loadedAt: .now)
        } catch {
            // Replaced by a newer load, or the tab closed: not a failure.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            print("Couldn't load pinned messages:", error)
            let problem: LoadProblem = isOfflineError(error) ? .offline : .failed
            // Keep the list from an earlier load, with the message on top.
            if var previous = state, previous.messages != nil {
                previous.problem = problem
                state = previous
            } else {
                state = LoadState(messages: nil, problem: problem, loadedAt: .now)
            }
        }
    }
}
