import Foundation
import SwiftData

// Port of src/data/playTimeDb.ts (see docs/play-time-tracking.md): listening sessions,
// stored on the phone with SwiftData instead of SQLite. One store for the phone; each
// session carries the Clerk user ID of whoever was signed in when it started.

/// One visit to a lesson's player. Same fields as the Android `play_sessions` table.
@Model
final class PlaySession {
    /// A UUID, made when the session starts. Stays the same through crash recovery, so an
    /// upload later can't count a session twice.
    @Attribute(.unique) var id: String
    var mediaId: Int
    /// Whole seconds of playing, rounded down. Measured with a stopwatch, never endedAt − startedAt.
    var seconds: Int
    /// When the player was opened (the phone's clock).
    var startedAt: Date
    /// When the player was left; the last checkpoint while the session is open.
    var endedAt: Date
    /// The phone's local calendar day when the session started, "YYYY-MM-DD". A session
    /// from 23:50 to 00:20 counts toward the first day.
    var startedDate: String
    /// The Clerk user ID, read when the session started; nil if nobody was known.
    var userId: String?
    /// Always "mobile".
    var source: String
    /// "open" while the player is open, then "done".
    var status: String
    /// For uploading later; nil = not uploaded yet.
    var uploadedAt: Date?

    init(id: String, mediaId: Int, startedAt: Date, startedDate: String, userId: String?) {
        self.id = id
        self.mediaId = mediaId
        self.seconds = 0
        self.startedAt = startedAt
        self.endedAt = startedAt
        self.startedDate = startedDate
        self.userId = userId
        self.source = "mobile"
        self.status = PlaySession.open
        self.uploadedAt = nil
    }

    static let open = "open"
    static let done = "done"
}

/// One lesson's listening, for the Sessions tab (a later milestone).
struct LessonTotal {
    let mediaId: Int
    let totalSeconds: Int
    let sessionCount: Int
}

/// Reads and writes listening sessions. Writes never interrupt playback: a failure is
/// printed and the session keeps going.
@MainActor
final class PlayTimeStore {
    static let shared = PlayTimeStore()

    private let context: ModelContext?

    /// Opens the store and finishes sessions left open by a crash or force-quit. Recovery
    /// runs here, before anything else touches the store, so it can never close the
    /// session of a player that is opening right now.
    private init() {
        do {
            let container = try ModelContainer(
                for: PlaySession.self,
                configurations: ModelConfiguration("play-time")
            )
            context = ModelContext(container)
            context?.autosaveEnabled = false
            recoverOpenSessions()
        } catch {
            print("Play time: couldn't open the store:", error)
            context = nil
        }
    }

    /// A session still open at startup never ended normally. Keep it with its last
    /// checkpoint, or drop it if it was under a second.
    private func recoverOpenSessions() {
        write("recover open sessions") { context in
            let open = PlaySession.open
            let sessions = try context.fetch(FetchDescriptor<PlaySession>(predicate: #Predicate { $0.status == open }))
            for session in sessions {
                if session.seconds < 1 {
                    context.delete(session)
                } else {
                    session.status = PlaySession.done
                }
            }
        }
    }

    // MARK: - Writing (used by the player)

    func insertOpenSession(id: String, mediaId: Int, userId: String?, now: Date = .now) {
        write("start a session") { context in
            context.insert(PlaySession(id: id, mediaId: mediaId, startedAt: now,
                                       startedDate: Self.localDate(now), userId: userId))
        }
    }

    func checkpoint(id: String, seconds: Int, endedAt: Date = .now) {
        write("save a checkpoint") { context in
            guard let session = try self.session(id, in: context), session.status == PlaySession.open else { return }
            session.seconds = seconds
            session.endedAt = endedAt
        }
    }

    /// Ends a session. Under one second of playing, it's thrown away.
    func finish(id: String, seconds: Int, endedAt: Date = .now) {
        write("finish a session") { context in
            guard let session = try self.session(id, in: context) else { return }
            if seconds < 1 {
                context.delete(session)
            } else {
                session.seconds = seconds
                session.endedAt = endedAt
                session.status = PlaySession.done
            }
        }
    }

    // MARK: - Reading (for the Sessions tab and uploading, later milestones)

    /// Finished sessions of this user that haven't been uploaded yet, oldest first.
    func unuploadedSessions(userId: String) -> [PlaySession] {
        let done = PlaySession.done
        return fetch(FetchDescriptor<PlaySession>(
            predicate: #Predicate { $0.userId == userId && $0.status == done && $0.uploadedAt == nil },
            sortBy: [SortDescriptor(\.startedAt)]
        ))
    }

    /// The server confirmed this session; it's never sent again.
    func markUploaded(id: String) {
        write("mark a session uploaded") { context in
            try self.session(id, in: context)?.uploadedAt = .now
        }
    }

    func delete(id: String) {
        write("delete a session") { context in
            if let session = try self.session(id, in: context) { context.delete(session) }
        }
    }

    /// One entry per lesson, most listening time first (ties: most recently listened first).
    func lessonTotals(userId: String) -> [LessonTotal] {
        let sessions = finishedSessions(userId: userId)
        let byLesson = Dictionary(grouping: sessions, by: \.mediaId)
        return byLesson.map { mediaId, sessions in
            (total: LessonTotal(mediaId: mediaId, totalSeconds: sessions.reduce(0) { $0 + $1.seconds },
                                sessionCount: sessions.count),
             last: sessions.map(\.startedAt).max() ?? .distantPast)
        }
        .sorted { ($0.total.totalSeconds, $0.last) > ($1.total.totalSeconds, $1.last) }
        .map(\.total)
    }

    /// A lesson's finished sessions, newest first.
    func lessonSessions(userId: String, mediaId: Int) -> [PlaySession] {
        let done = PlaySession.done
        return fetch(FetchDescriptor<PlaySession>(
            predicate: #Predicate { $0.userId == userId && $0.mediaId == mediaId && $0.status == done },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        ))
    }

    private func finishedSessions(userId: String) -> [PlaySession] {
        let done = PlaySession.done
        return fetch(FetchDescriptor<PlaySession>(
            predicate: #Predicate { $0.userId == userId && $0.status == done }
        ))
    }

    // MARK: - Helpers

    private func session(_ id: String, in context: ModelContext) throws -> PlaySession? {
        var descriptor = FetchDescriptor<PlaySession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetch(_ descriptor: FetchDescriptor<PlaySession>) -> [PlaySession] {
        guard let context else { return [] }
        do {
            return try context.fetch(descriptor)
        } catch {
            print("Play time: couldn't read sessions:", error)
            return []
        }
    }

    /// Makes a change and saves it straight away, so a crash right after loses nothing.
    private func write(_ label: String, _ change: (ModelContext) throws -> Void) {
        guard let context else { return }
        do {
            try change(context)
            try context.save()
        } catch {
            print("Play time: couldn't \(label):", error)
            context.rollback()
        }
    }

    /// The phone's local calendar day, "YYYY-MM-DD".
    static func localDate(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Port of src/hooks/usePlayTimeTracking.ts: records one listening session for as long as
/// the player is open. Only time while the media is actually playing counts, measured with
/// a stopwatch (a monotonic clock), so changing the phone's clock can't affect it.
/// Driven by the playback engine, so it keeps counting in the background.
@MainActor
final class PlayTimeTracker {
    /// While playing, save the running total at most this often, so a crash or force-quit
    /// loses at most about this much time.
    private static let checkpointEvery: Duration = .seconds(5)

    private let id = UUID().uuidString
    private let clock = ContinuousClock()
    /// Finished playing segments.
    private var total: Duration = .zero
    /// When the current playing segment started; nil while not playing.
    private var segmentStart: ContinuousClock.Instant?
    private var lastCheckpoint: ContinuousClock.Instant
    private var finished = false

    /// Starts the session (the player opened). `userId` is read now; signing in or out
    /// later doesn't move the session to another user.
    init(mediaId: Int, userId: String?) {
        lastCheckpoint = clock.now
        PlayTimeStore.shared.insertOpenSession(id: id, mediaId: mediaId, userId: userId)
    }

    /// Total playing time so far, including the segment in progress, in whole seconds.
    private var playedSeconds: Int {
        let open = segmentStart.map { clock.now - $0 } ?? .zero
        return Int((total + open).components.seconds)
    }

    /// Playing started or stopped, for any reason: count the segment, and checkpoint on stop.
    func setPlaying(_ playing: Bool) {
        guard !finished else { return }
        if playing {
            if segmentStart == nil { segmentStart = clock.now }
        } else if let start = segmentStart {
            total += clock.now - start
            segmentStart = nil
            checkpoint()
        }
    }

    /// Called on every time update; saves every few seconds while playing.
    func tick() {
        guard segmentStart != nil, clock.now - lastCheckpoint >= Self.checkpointEvery else { return }
        checkpoint()
    }

    /// Saves the running total, e.g. when the app leaves the screen, in case it's killed there.
    func checkpoint() {
        guard !finished else { return }
        lastCheckpoint = clock.now
        PlayTimeStore.shared.checkpoint(id: id, seconds: playedSeconds)
    }

    /// Ends the session (the player closed).
    func finish() {
        guard !finished else { return }
        setPlaying(false)
        finished = true
        PlayTimeStore.shared.finish(id: id, seconds: Int(total.components.seconds))
    }
}
