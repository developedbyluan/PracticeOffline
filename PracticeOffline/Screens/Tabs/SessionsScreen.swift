import ClerkKit
import SwiftUI

/// Port of src/app/(tabs)/sessions.tsx: listening history, one row per lesson, most
/// listening time first. Only the signed-in user's sessions. Tapping a row opens that
/// lesson's sessions. (The Android Upload button comes in a later milestone.)
struct SessionsScreen: View {
    @Environment(Clerk.self) private var clerk

    var body: some View {
        if clerk.isLoaded {
            SessionsList(userId: clerk.user?.id)
        } else {
            ProgressView()
        }
    }
}

/// The Sessions tab's content for one user (nil: nobody signed in).
struct SessionsList: View {
    let userId: String?

    private struct LessonRow: Identifiable {
        let mediaId: Int
        let name: String
        let thumbnailURL: String?
        let thumbnailFile: URL?
        let totalSeconds: Int
        let sessionCount: Int
        var id: Int { mediaId }
    }

    @State private var rows: [LessonRow]?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sessions")
                .navigationDestination(for: LessonSessionsScreen.Route.self) { route in
                    LessonSessionsScreen(route: route)
                }
        }
        // Reload every time the tab is shown, so new sessions and deletions appear.
        .onAppear { Task { await load() } }
        .onChange(of: userId) { Task { await load() } }
    }

    @ViewBuilder private var content: some View {
        if userId == nil {
            Text("Sign in to see your listening history.")
                .foregroundStyle(.secondary)
        } else if let rows {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No listening yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Play a lesson and your listening time will show up here.")
                )
            } else {
                list(rows)
            }
        } else {
            ProgressView()
        }
    }

    private func list(_ rows: [LessonRow]) -> some View {
        let grandTotal = rows.reduce(0) { $0 + $1.totalSeconds }
        return List {
            Section {
                ForEach(rows) { row in
                    NavigationLink(value: LessonSessionsScreen.Route(mediaId: row.mediaId, name: row.name, userId: userId)) {
                        rowView(row)
                    }
                }
            } header: {
                Text("Total \(formatDuration(grandTotal))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        }
        .listStyle(.plain)
    }

    private func rowView(_ row: LessonRow) -> some View {
        let sessions = "\(row.sessionCount) \(row.sessionCount == 1 ? "session" : "sessions")"
        return HStack(spacing: 12) {
            Group {
                if row.thumbnailURL != nil || row.thumbnailFile != nil {
                    ThumbnailImage(url: row.thumbnailURL, localFile: row.thumbnailFile)
                        .scaledToFill()
                } else {
                    Color(.systemGray5)
                }
            }
            .frame(width: 96, height: 54)
            .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(Text(formatDuration(row.totalSeconds)).fontWeight(.semibold).foregroundStyle(.primary)) · \(sessions)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(formatDuration(row.totalSeconds)), \(sessions)")
        .accessibilityHint("Shows each session")
    }

    private func load() async {
        guard let userId else { return }
        let totals = PlayTimeStore.shared.lessonTotals(userId: userId)
        let favorites = await FavoritesCache.load(userId: userId) ?? []
        guard self.userId == userId else { return }
        let byMediaId = Dictionary(favorites.map { ($0.mediaId, $0) }, uniquingKeysWith: { first, _ in first })
        let downloads = MediaDownloads.shared
        rows = totals.map { total in
            let item = byMediaId[total.mediaId]
            // A lesson that left the favorites list may still be downloaded.
            let download = item == nil ? downloads.downloadDetails(mediaId: total.mediaId) : nil
            let name = item?.fileName ?? download?.fileName
            let thumbnail = item?.fileThumbnailUrl ?? download?.thumbnailUrl
            return LessonRow(
                mediaId: total.mediaId,
                name: (name?.isEmpty == false ? name : nil) ?? "Lesson \(total.mediaId)",
                thumbnailURL: thumbnail?.isEmpty == false ? thumbnail : nil,
                thumbnailFile: downloads.localThumbnailURL(mediaId: total.mediaId),
                totalSeconds: total.totalSeconds,
                sessionCount: total.sessionCount
            )
        }
    }
}

/// Listening time as "45s", "3m 20s" or "1h 5m 10s". Units below the largest one are
/// always shown ("3m 0s"), so lengths line up in lists. Port of src/utils/formatDuration.ts.
func formatDuration(_ totalSeconds: Int) -> String {
    let seconds = max(0, totalSeconds)
    let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
    if h > 0 { return "\(h)h \(m)m \(s)s" }
    if m > 0 { return "\(m)m \(s)s" }
    return "\(s)s"
}
