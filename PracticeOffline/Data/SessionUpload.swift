import Foundation

// Port of src/data/sessionUpload.ts (see docs/play-time-tracking.md, "Uploading"):
// sends listening sessions to POST /sessions, one at a time.

/// HTTP Basic auth for flucom-api endpoints that need it, from Secrets.xcconfig (through
/// Info.plist). Like the Android app's EXPO_PUBLIC_ values, these end up inside the app,
/// so they can be extracted from it: fine for internal testing, not for a public release.
nonisolated enum APIAuth {
    struct MissingCredentials: LocalizedError {
        var errorDescription: String? { "Missing API_USER or API_PASS in Secrets.xcconfig" }
    }

    static func basicHeader() throws -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let user = (info["APIUser"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let pass = (info["APIPass"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !pass.isEmpty else { throw MissingCredentials() }
        return "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
    }
}

/// The request body. The server inserts it as is, so only these keys; never the session's id.
nonisolated struct SessionBody: Encodable, Sendable {
    let mediaId: Int
    /// Left out when unknown.
    let mediaSlug: String?
    /// Whole seconds.
    let timeSpent: Int
    /// Local "YYYY-MM-DD".
    let date: String
    /// ISO 8601, e.g. "2026-11-24T16:58:03.120Z".
    let timestamp: String
    let userId: String
    let deviceSource: String
}

/// The server answered, but not with success.
nonisolated struct UploadError: LocalizedError {
    let status: Int
    let responseText: String
    var errorDescription: String? { "Upload failed (\(status)): \(responseText)" }
}

/// How an upload went.
struct UploadSummary {
    enum StoppedBy { case offline, auth }

    /// Sessions waiting to be uploaded.
    var total = 0
    var sent = 0
    /// Rejected by the server (kept on the phone).
    var failed = 0
    /// Why the rest weren't tried.
    var stoppedBy: StoppedBy?

    /// The message shown after an upload.
    var message: String {
        func plural(_ n: Int) -> String { "\(n) \(n == 1 ? "session" : "sessions")" }
        if total == 0 { return "Everything is already uploaded." }
        if sent == total { return "Uploaded \(plural(sent))." }
        if sent == 0 {
            switch stoppedBy {
            case .offline: return "You're offline. Connect to the internet to upload."
            case .auth: return "Upload failed: the server didn't accept the app's login."
            case nil: return "Upload failed. Please try again."
            }
        }
        return "Uploaded \(sent) of \(plural(total)). \(total - sent) couldn't be sent. Try again later."
    }
}

/// Sends one session. Success is 200 with a JSON array holding the inserted row.
@concurrent
nonisolated func postSession(_ body: SessionBody, baseURL: URL = API.baseURL) async throws {
    var request = URLRequest(url: baseURL.appending(path: "sessions"))
    request.httpMethod = "POST"
    request.setValue(try APIAuth.basicHeader(), forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let text = String(decoding: data, as: UTF8.self)
    guard (200..<300).contains(status) else { throw UploadError(status: status, responseText: text) }
    guard let rows = try? JSONSerialization.jsonObject(with: data) as? [Any], !rows.isEmpty else {
        throw UploadError(status: status, responseText: "No row in response: \(text)")
    }
}

/// Uploads this user's finished, not-yet-uploaded sessions one at a time, oldest first.
/// Each session the server confirms is marked uploaded and then deleted from the phone
/// right away, so a failure halfway never re-sends the ones that worked. Offline or a
/// login error (401) stops the upload; any other rejection skips that session and continues.
@MainActor
func uploadSessions(userId: String, baseURL: URL = API.baseURL) async -> UploadSummary {
    let store = PlayTimeStore.shared
    let sessions = store.unuploadedSessions(userId: userId).map {
        (id: $0.id, mediaId: $0.mediaId, seconds: $0.seconds, startedDate: $0.startedDate, startedAt: $0.startedAt)
    }
    var summary = UploadSummary(total: sessions.count)
    guard !sessions.isEmpty else { return summary }

    let favorites = await FavoritesCache.load(userId: userId) ?? []
    let slugs = Dictionary(favorites.map { ($0.mediaId, $0.fileSlug) }, uniquingKeysWith: { first, _ in first })
    let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    for session in sessions {
        // A lesson that left the favorites list still has its slug in its download record.
        let slug = slugs[session.mediaId] ?? MediaDownloads.shared.downloadDetails(mediaId: session.mediaId)?.fileSlug
        let body = SessionBody(
            mediaId: session.mediaId,
            mediaSlug: slug?.isEmpty == false ? slug : nil,
            timeSpent: session.seconds,
            date: session.startedDate,
            timestamp: session.startedAt.formatted(timestamp),
            userId: userId,
            deviceSource: "mobile"
        )
        do {
            try await postSession(body, baseURL: baseURL)
        } catch let error as UploadError where error.status == 401 {
            print("Session upload failed:", session.id, error)
            summary.stoppedBy = .auth
            break
        } catch {
            print("Session upload failed:", session.id, error)
            if !(error is UploadError), isOfflineError(error) {
                summary.stoppedBy = .offline
                break
            }
            summary.failed += 1
            continue
        }

        summary.sent += 1
        // The server has it. Marking first means it's never sent again, even if deleting fails.
        store.markUploaded(id: session.id)
        store.delete(id: session.id)
    }
    return summary
}
