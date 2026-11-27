import Observation

/// Which tab is showing, so a notification tap can switch to the Pinned tab from anywhere
/// (port of the router.push("/pinned") in src/notifications/taps.ts).
@MainActor @Observable
final class AppNavigation {
    static let shared = AppNavigation()

    enum Tab: Hashable { case home, sessions, pinned, settings }

    var tab: Tab = .home
    /// Bumped on every "open Pinned" request, so the Pinned tab reloads and the player closes.
    private(set) var pinnedRequests = 0
    /// Bumped when a new-event push arrives while the app is open, so an open Pinned tab reloads.
    private(set) var newPinnedArrivals = 0

    private init() {}

    func openPinned() {
        tab = .pinned
        pinnedRequests += 1
    }

    func newPinnedArrived() {
        newPinnedArrivals += 1
    }
}
