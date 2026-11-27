import SwiftUI

/// Port of src/app/sessions/[mediaId].tsx: one lesson's listening sessions, newest first.
/// Swipe a row left to delete it. Only the signed-in user's sessions.
struct LessonSessionsScreen: View {
    struct Route: Hashable {
        let mediaId: Int
        let name: String
        /// The signed-in user whose sessions are shown.
        let userId: String?
    }

    /// A session as shown in a row (copied out of the store, so a deleted one can't linger).
    private struct SessionRow: Identifiable {
        let id: String
        let seconds: Int
        let startedAt: Date
        let endedAt: Date
    }

    let route: Route

    @State private var sessions: [SessionRow]?

    var body: some View {
        content
            .navigationTitle(route.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: load)
    }

    @ViewBuilder private var content: some View {
        if let sessions {
            if sessions.isEmpty {
                Text("No sessions left for this lesson.")
                    .foregroundStyle(.secondary)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(sessions)
            }
        } else {
            ProgressView()
        }
    }

    private func list(_ sessions: [SessionRow]) -> some View {
        let total = sessions.reduce(0) { $0 + $1.seconds }
        let count = "\(sessions.count) \(sessions.count == 1 ? "session" : "sessions")"
        return List {
            // The total and count, as a plain row (a list header would grey them out).
            VStack(alignment: .leading, spacing: 2) {
                Text(formatDuration(total))
                    .font(.largeTitle.bold())
                Text(count)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .listRowSeparator(.hidden, edges: .top)
            .accessibilityElement(children: .combine)

            ForEach(sessions) { session in
                row(session)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            delete(session.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .accessibilityAction(named: "Delete session") { delete(session.id) }
            }

            Text("Swipe left on a session to delete it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .listRowSeparator(.hidden, edges: .bottom)
                .accessibilityHidden(true)
        }
        .listStyle(.plain)
    }

    private func row(_ session: SessionRow) -> some View {
        let date = session.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        let range = "\(time(session.startedAt)) – \(time(session.endedAt))"
        let duration = formatDuration(session.seconds)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(date)
                    .font(.body.weight(.medium))
                Text(range)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(duration)
                .font(.body.weight(.semibold).monospacedDigit())
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(date), \(range), \(duration)")
    }

    private func load() {
        guard let userId = route.userId else {
            sessions = []
            return
        }
        sessions = PlayTimeStore.shared.lessonSessions(userId: userId, mediaId: route.mediaId).map {
            SessionRow(id: $0.id, seconds: $0.seconds, startedAt: $0.startedAt, endedAt: $0.endedAt)
        }
    }

    private func delete(_ id: String) {
        if PlayTimeStore.shared.delete(id: id) {
            withAnimation { sessions?.removeAll { $0.id == id } }
            Toast.show("Session deleted")
        } else {
            Toast.show("Couldn't delete this session. Please try again.")
        }
    }
}
