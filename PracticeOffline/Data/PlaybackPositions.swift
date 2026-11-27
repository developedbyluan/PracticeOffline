import Foundation

/// Port of src/data/playbackPositions.ts: where each lesson was left off, so the player
/// can pick up from there next time. Stored outside media/, so removing a download keeps
/// its position. One file for the whole phone, loaded once.
@MainActor
enum PlaybackPositions {
    private struct SavedPosition: Codable {
        var seconds: Double
        var duration: Double
        /// ms since 1970
        var updatedAt: Double
    }

    /// A position this close to the end counts as finished: the next open starts from 0.
    static let resumeEndMarginSeconds: Double = 5
    /// Don't rewrite the file for changes smaller than this.
    private static let minChangeSeconds: Double = 1

    private static let file = URL.documentsDirectory.appending(path: "playback-positions.json")
    private static var cache: [String: SavedPosition]?

    /// Loaded once, on first use. A missing or broken file starts empty.
    private static var positions: [String: SavedPosition] {
        if let cache { return cache }
        let loaded = (try? Data(contentsOf: file))
            .flatMap { try? JSONDecoder().decode([String: SavedPosition].self, from: $0) } ?? [:]
        cache = loaded
        return loaded
    }

    /// Where to start this lesson: the saved second, or 0 if there's none or it was finished.
    static func resumePosition(mediaId: Int) -> Double {
        guard let saved = positions[String(mediaId)], saved.seconds > 0 else { return 0 }
        if saved.duration > 0, saved.seconds >= saved.duration - resumeEndMarginSeconds { return 0 }
        return saved.seconds
    }

    static func save(mediaId: Int, seconds: Double, duration: Double) {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return }
        var all = positions
        let key = String(mediaId)
        if let previous = all[key], abs(previous.seconds - seconds) < minChangeSeconds { return }

        all[key] = SavedPosition(seconds: max(0, seconds), duration: duration,
                                 updatedAt: Date.now.timeIntervalSince1970 * 1000)
        cache = all
        do {
            try JSONEncoder().encode(all).write(to: file, options: .atomic)
        } catch {
            print("Could not save the playback position:", error)
        }
    }
}
