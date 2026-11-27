import Foundation

/// Port of src/data/favoritesCache.ts: the last list loaded, saved on the phone so it
/// shows instantly and works offline. One file per user, so a different account on the
/// same phone never sees another user's list.
nonisolated enum FavoritesCache {
    private static func fileURL(userId: String) -> URL {
        let safeId = userId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? userId
        return URL.documentsDirectory.appending(path: "favorites-\(safeId).json")
    }

    /// The saved list, or nil if there isn't one (or it can't be read).
    @concurrent
    static func load(userId: String) async -> [MediaItem]? {
        guard let data = try? Data(contentsOf: fileURL(userId: userId)) else { return nil }
        return try? JSONDecoder().decode([MediaItem].self, from: data)
    }

    @concurrent
    static func save(_ items: [MediaItem], userId: String) async {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL(userId: userId), options: .atomic)
        } catch {
            print("Could not save favorites for offline use:", error)
        }
    }
}
