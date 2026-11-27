import Foundation

// Port of src/data/media.ts: the lesson and transcript models, and fetchFavorites.

/// One lesson in the user's favorites, as GET /favorites/by-user-id/{userId} returns it.
nonisolated struct MediaItem: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var mediaId: Int
    var createdAt: Double
    var fileName: String
    var fileSlug: String
    var fileStatus: String
    var fileAuthor: String
    var fileAuthorUrl: String
    var fileType: String
    var fileThumbnailUrl: String
    var fileProjectId: Int
    var fileFolderId: Int
    var fileOrder: Int
    var fileUrl: String
    var fileJsonId: Int
    /// When the media, thumbnail or transcript last changed, in ms since 1970.
    /// Optional: favorites saved by an older app version don't have it.
    var updatedAtOfMedia: Double?
}

extension MediaItem {
    /// Only `id` and `mediaId` are required. A missing or empty field gets a blank value
    /// instead of making the whole list fail to load.
    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: key)) ?? "" }
        func int(_ key: CodingKeys) -> Int { (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0 }
        id = try c.decode(Int.self, forKey: .id)
        mediaId = try c.decode(Int.self, forKey: .mediaId)
        createdAt = (try? c.decodeIfPresent(Double.self, forKey: .createdAt)) ?? 0
        fileName = text(.fileName)
        fileSlug = text(.fileSlug)
        fileStatus = text(.fileStatus)
        fileAuthor = text(.fileAuthor)
        fileAuthorUrl = text(.fileAuthorUrl)
        fileType = text(.fileType)
        fileThumbnailUrl = text(.fileThumbnailUrl)
        fileProjectId = int(.fileProjectId)
        fileFolderId = int(.fileFolderId)
        fileOrder = int(.fileOrder)
        fileUrl = text(.fileUrl)
        fileJsonId = int(.fileJsonId)
        updatedAtOfMedia = try? c.decodeIfPresent(Double.self, forKey: .updatedAtOfMedia)
    }
}

/// Which player can play a file.
nonisolated enum MediaKind: Sendable {
    case audio, video

    private static let audioExtensions: Set<String> = [".mp3", ".m4a", ".aac", ".wav"]
    private static let videoExtensions: Set<String> = [".mp4", ".m4v", ".mov", ".webm"]

    /// Judged by the URL's extension; nil if neither player can play it.
    init?(fileUrl: String) {
        let ext = fileExtension(fileUrl)
        if Self.audioExtensions.contains(ext) {
            self = .audio
        } else if Self.videoExtensions.contains(ext) {
            self = .video
        } else {
            return nil
        }
    }
}

/// Lowercase extension from the end of a URL's path, e.g. ".mp3". Empty if there isn't one.
nonisolated func fileExtension(_ url: String) -> String {
    let path = url.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
    guard let match = path.firstMatch(of: /\.([a-zA-Z0-9]{1,5})$/) else { return "" }
    return "." + match.1.lowercased()
}

/// Loads the user's favorites from the server.
@concurrent
nonisolated func fetchFavorites(userId: String) async throws -> [MediaItem] {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove("/")
    let safeId = userId.addingPercentEncoding(withAllowedCharacters: allowed) ?? userId
    let url = API.baseURL.appending(path: "favorites/by-user-id/\(safeId)", directoryHint: .notDirectory)
    let (data, response) = try await URLSession.shared.data(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw HTTPStatusError(what: "favorites", status: http.statusCode)
    }
    return try JSONDecoder().decode([MediaItem].self, from: data)
}

// MARK: - Transcripts (used by the player in a later milestone)

/// One line of a lesson's timed transcript, from GET /json/{fileJsonId}.
nonisolated struct TranscriptLine: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    /// Seconds into the media.
    var start: Double
    var end: Double
    /// English sentence; often starts with "\n".
    var target: String
    /// IPA pronunciation of `target`.
    var ipa: String
    /// Vietnamese translation.
    var mine: String
    /// "question" and "answer" mark Q&A lines; a label ending in a colon (e.g. "Narrator:")
    /// names who is speaking; "" continues without a new label.
    var speaker: String
}

/// A lesson's whole transcript.
nonisolated struct MediaJSON: Codable, Sendable {
    /// The fileJsonId.
    var id: Int
    var json: [TranscriptLine]
    var createdAt: String
    var updatedAt: String
}

nonisolated func mediaJSONURL(fileJsonId: Int) -> URL {
    API.baseURL.appending(path: "json/\(fileJsonId)", directoryHint: .notDirectory)
}

/// Light shape check, enough to reject an error page or an unexpected response:
/// a JSON object whose "json" is an array.
nonisolated func isMediaJSON(_ data: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    return object["json"] is [Any]
}

/// A lesson's transcript from the server.
@concurrent
nonisolated func fetchMediaJSON(fileJsonId: Int) async throws -> MediaJSON {
    let (data, response) = try await URLSession.shared.data(from: mediaJSONURL(fileJsonId: fileJsonId))
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw HTTPStatusError(what: "transcript", status: http.statusCode)
    }
    // An unknown fileJsonId returns 200 with an empty body.
    guard isMediaJSON(data), let json = try? JSONDecoder().decode(MediaJSON.self, from: data) else {
        throw TranscriptFormatError()
    }
    return json
}

nonisolated struct TranscriptFormatError: LocalizedError {
    var errorDescription: String? { "Failed to load transcript (unexpected format)" }
}
