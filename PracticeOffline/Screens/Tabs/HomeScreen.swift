import ClerkKit
import SwiftUI

/// Port of src/app/(tabs)/index.tsx: the user's favorite lessons.
/// Shows the saved list right away, then loads a fresh one. Pull down to refresh.
/// If loading fails, the list on screen stays with a banner explaining why.
struct HomeScreen: View {
    /// `items` may be the saved copy. `problem` says why the latest request failed; with
    /// no saved copy (`items == nil`) the screen explains the problem with a Try again button.
    private struct FavoritesResult {
        let userId: String
        var items: [MediaItem]?
        var problem: LoadProblem?
    }

    /// Coming back to the app (or to this tab) refreshes the list at most this often.
    private static let refreshInterval: TimeInterval = 30

    @Environment(Clerk.self) private var clerk
    @Environment(\.scenePhase) private var scenePhase
    @State private var result: FavoritesResult?
    @State private var isRetrying = false
    @State private var lastFetchAt = Date.distantPast

    private var userId: String? { clerk.user?.id }

    var body: some View {
        content
            .task(id: userId) { await firstLoad() }
            .onChange(of: scenePhase) { _, phase in
                // Refresh when the app comes back to the foreground, so server updates are noticed.
                if phase == .active, let userId, isStale {
                    Task { await fetchFresh(userId: userId) }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if !clerk.isLoaded {
            ProgressView()
        } else if let userId {
            // A result for another user (or none yet) means this user's list is still loading.
            if let result, result.userId == userId {
                if let items = result.items {
                    list(items: items, problem: result.problem, userId: userId)
                } else {
                    loadFailed(problem: result.problem ?? .failed, userId: userId)
                }
            } else {
                ProgressView()
            }
        } else {
            Text("Sign in to see your favorites.")
        }
    }

    private func list(items: [MediaItem], problem: LoadProblem?, userId: String) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                if let problem {
                    StatusBanner(kind: problem)
                }
                if items.isEmpty {
                    Text("You have no favorites yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                }
                ForEach(items) { item in
                    MediaCard(name: item.fileName, author: item.fileAuthor, thumbnail: item.fileThumbnailUrl)
                }
            }
            .padding(20)
        }
        .refreshable { await fetchFresh(userId: userId) }
    }

    /// Shown when the list couldn't load and there's no saved copy to fall back on.
    private func loadFailed(problem: LoadProblem, userId: String) -> some View {
        let offline = problem == .offline
        return ContentUnavailableView {
            Label(
                offline ? "You're offline" : "Couldn't load your favorites",
                systemImage: offline ? "wifi.slash" : "info.circle"
            )
        } description: {
            Text(offline ? "Connect to the internet to load your favorites." : "Please try again in a moment.")
        } actions: {
            Button {
                Task {
                    isRetrying = true
                    await fetchFresh(userId: userId)
                    isRetrying = false
                }
            } label: {
                if isRetrying {
                    ProgressView().frame(minWidth: 100)
                } else {
                    Text("Try again").frame(minWidth: 100)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRetrying)
        }
    }

    private var isStale: Bool {
        Date.now.timeIntervalSince(lastFetchAt) > Self.refreshInterval
    }

    /// Runs when the screen appears or the signed-in user changes.
    private func firstLoad() async {
        guard let userId else { return }
        if result?.userId == userId {
            // Already showing this user's list (e.g. switching back to this tab).
            if isStale { await fetchFresh(userId: userId) }
            return
        }
        // Show the saved list right away, then replace it with fresh data.
        if let cached = await FavoritesCache.load(userId: userId), self.userId == userId {
            result = FavoritesResult(userId: userId, items: cached, problem: nil)
        }
        await fetchFresh(userId: userId)
    }

    /// Fetches the latest list and saves it for offline use. If the request fails, the
    /// list on screen (saved or fresh) stays, with a banner saying why.
    private func fetchFresh(userId: String) async {
        lastFetchAt = .now
        do {
            let items = try await fetchFavorites(userId: userId)
            guard self.userId == userId else { return }
            Task { await FavoritesCache.save(items, userId: userId) }
            result = FavoritesResult(userId: userId, items: items, problem: nil)
        } catch {
            // Leaving the screen mid-request cancels it; that's not a failure.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            guard self.userId == userId else { return }
            print("Couldn't load favorites:", error)
            let problem: LoadProblem = isOfflineError(error) ? .offline : .failed
            let previous = result?.userId == userId ? result?.items : nil
            result = FavoritesResult(userId: userId, items: previous, problem: problem)
        }
    }
}
